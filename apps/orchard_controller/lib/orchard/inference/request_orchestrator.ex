defmodule Orchard.Inference.RequestOrchestrator do
  @moduledoc """
  Executes the shared durable request lifecycle for prepared canonical requests.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest, GenerationParams}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference

  alias Orchard.Inference.{
    CanonicalRequestSerializer,
    ChatError,
    ToolExecutionSemantics,
    ToolingValidation
  }

  alias Orchard.InferenceEvent
  alias Orchard.Requests
  alias Orchard.Requests.Idempotency
  alias Orchard.Requests.RequestServer

  @type event_handler ::
          (Ecto.UUID.t(), InferenceEvent.t() -> :ok | :cancel)
  @type success_persistence ::
          (CanonicalRequest.t(), [InferenceEvent.t()] -> map())

  @type execute_result ::
          {:ok, CanonicalRequest.t(), [InferenceEvent.t()]}
          | {:replay, struct()}
          | {:error, term()}

  @spec execute(CanonicalRequest.t(), map(), keyword()) :: execute_result()
  def execute(%CanonicalRequest{} = canonical, model, opts \\ []) do
    event_handler = Keyword.get(opts, :event_handler)
    caller = Keyword.get(opts, :caller, self())
    success_persistence = Keyword.get(opts, :success_persistence)
    idempotency = Keyword.get(opts, :idempotency)

    with :ok <- validate_resolved_tooling(canonical),
         {:ok, db_request} <- persist_request(canonical, model, idempotency) do
      case start_fsm(db_request) do
        {:ok, _pid} ->
          run_dispatch_pipeline(
            db_request,
            canonical,
            model,
            caller,
            event_handler,
            success_persistence
          )

        {:error, reason} ->
          fail_request(db_request, {:request_server_start_failed, reason})
          {:error, {:request_server_start_failed, reason}}
      end
    end
  end

  defp run_dispatch_pipeline(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence
       ) do
    result =
      with :ok <- advance_fsm(db_request.id, :validated),
           {:ok, schedule} <- schedule_request(canonical),
           {:ok, _} <- Requests.record_schedule(db_request, schedule),
           :ok <- advance_fsm(db_request.id, :scheduled),
           :ok <- advance_fsm(db_request.id, :dispatching),
           {:ok, events, first_token_at} <-
             dispatch(db_request, canonical, model, schedule, caller, event_handler) do
        finalize(db_request, canonical, model, events, first_token_at, success_persistence)
      end

    case result do
      {:ok, _, _} = success ->
        success

      {:error, reason} ->
        fail_request(db_request, reason)
        {:error, reason}
    end
  end

  defp persist_request(canonical, model, idempotency) do
    with {:ok, serialized_canonical} <- serialize_canonical_request(canonical) do
      canonical
      |> request_attrs(model, serialized_canonical)
      |> put_idempotency_attrs(idempotency)
      |> Requests.create_request()
      |> handle_create_request_result(idempotency)
    end
  end

  defp request_attrs(canonical, model, serialized_canonical) do
    %{
      id: canonical.internal_id,
      public_id: canonical.public_id,
      endpoint: canonical.endpoint,
      tenant_id: canonical.tenant_id,
      api_key_id: canonical.api_key_id,
      requested_model: "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}",
      model_id: model.id,
      state: :received,
      stream: canonical.stream?,
      payload_capture_mode: :metadata,
      canonical_request: serialized_canonical,
      sampling_params: CanonicalRequestSerializer.sampling_params(canonical.sampling),
      input_tokens: canonical.input_token_count
    }
  end

  defp put_idempotency_attrs(attrs, %Idempotency.Context{} = idempotency) do
    Map.merge(attrs, %{
      idempotency_key: idempotency.key,
      body_hash: idempotency.body_hash
    })
  end

  defp put_idempotency_attrs(attrs, nil), do: attrs

  defp handle_create_request_result({:ok, request}, _idempotency), do: {:ok, request}

  defp handle_create_request_result({:error, changeset}, %Idempotency.Context{} = idempotency) do
    if idempotency_constraint?(changeset) do
      resolve_duplicate_request(idempotency)
    else
      {:error, changeset}
    end
  end

  defp handle_create_request_result({:error, changeset}, nil), do: {:error, changeset}

  defp idempotency_constraint?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:idempotency_key, {_message, metadata}} ->
        to_string(Keyword.get(metadata, :constraint_name)) == "idx_requests_tenant_idempotency"

      _other ->
        false
    end)
  end

  defp resolve_duplicate_request(idempotency) do
    case Idempotency.resolve(idempotency) do
      {:replay, request} ->
        {:replay, request}

      {:conflict, reason, _request} ->
        {:error, {:idempotency_conflict, reason}}

      :proceed ->
        {:error, {:idempotency_resolution_failed, :missing_request}}
    end
  end

  defp start_fsm(db_request) do
    RequestServer.start(
      request_id: db_request.id,
      public_id: db_request.public_id,
      initial_state: :received
    )
  end

  defp advance_fsm(request_id, state) do
    RequestServer.transition(request_id, state)
  end

  defp schedule_request(canonical) do
    Inference.scheduler().schedule(canonical)
  end

  defp dispatch(db_request, canonical, model, schedule, caller, event_handler) do
    execute_request = build_execute_request(canonical, schedule)
    model_load_request = build_model_load_request(model, schedule)
    capture_key = make_ref()

    try do
      Process.put(capture_key, nil)

      wrapped_handler = wrap_event_handler_for_first_token(event_handler, capture_key)

      result =
        RequestDispatcher.dispatch(
          schedule,
          execute_request,
          model_load_request,
          caller: caller,
          event_handler: wrapped_handler,
          on_node_resolved: build_node_resolved_callback(db_request.id)
        )

      first_token_at = Process.get(capture_key)

      case result do
        {:ok, events} -> {:ok, events, first_token_at}
        {:error, _} = error -> error
      end
    after
      Process.delete(capture_key)
    end
  end

  defp wrap_event_handler_for_first_token(downstream_handler, capture_key) do
    fn request_id, event ->
      maybe_capture_first_token(event, capture_key)

      if downstream_handler do
        downstream_handler.(request_id, event)
      else
        :ok
      end
    end
  end

  defp maybe_capture_first_token(
         %InferenceEvent{event: %InferenceEvent.OutputTextDelta{delta: delta}},
         capture_key
       )
       when delta != "" do
    if Process.get(capture_key) == nil do
      Process.put(capture_key, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    end

    :ok
  end

  defp maybe_capture_first_token(_event, _capture_key), do: :ok

  defp build_node_resolved_callback(request_id) do
    fn node_id ->
      case Requests.assign_node(request_id, node_id) do
        {:ok, _} -> :ok
        {:error, reason} -> log_warn("assign_node failed: #{inspect(reason)}")
      end
    end
  end

  defp finalize(db_request, canonical, _model, events, first_token_at, success_persistence) do
    case build_terminal_attrs(canonical, events, first_token_at, success_persistence) do
      {:ok, terminal_attrs} ->
        persist_terminal(db_request, canonical, events, terminal_attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_terminal_attrs(canonical, events, first_token_at, success_persistence) do
    terminal_attrs = terminal_attrs_from_events(events)

    result =
      if terminal_attrs.state == :completed and not canonical.stream? and
           is_function(success_persistence, 2) do
        success_persistence
        |> apply_success_persistence(canonical, events)
        |> merge_success_attrs(terminal_attrs)
      else
        {:ok, terminal_attrs}
      end

    case result do
      {:ok, attrs} -> {:ok, maybe_put_first_token_at(attrs, first_token_at)}
      error -> error
    end
  end

  defp apply_success_persistence(success_persistence, canonical, events) do
    case success_persistence.(canonical, events) do
      attrs when is_map(attrs) -> {:ok, attrs}
      other -> {:error, {:invalid_success_persistence, other}}
    end
  rescue
    error -> {:error, {:success_persistence_failed, error}}
  end

  defp merge_success_attrs({:ok, success_attrs}, terminal_attrs),
    do: {:ok, Map.merge(terminal_attrs, success_attrs)}

  defp merge_success_attrs({:error, reason}, _terminal_attrs),
    do: {:error, {:terminal_persist_failed, reason}}

  defp persist_terminal(db_request, canonical, events, terminal_attrs) do
    advance_fsm_best_effort(db_request.id, events)
    advance_fsm_best_effort_terminal(db_request.id, terminal_attrs.state)

    case Requests.mark_terminal(db_request, terminal_attrs) do
      {:ok, _updated} -> {:ok, canonical, events}
      {:error, reason} -> {:error, {:terminal_persist_failed, reason}}
    end
  end

  defp fail_request(db_request, reason) do
    terminal_attrs =
      reason
      |> ChatError.from_execute_error()
      |> ChatError.terminal_attrs()

    advance_fsm_best_effort_terminal(db_request.id, terminal_attrs.state)

    case Requests.mark_terminal(db_request, terminal_attrs) do
      {:ok, _request} -> :ok
      {:error, error} -> log_warn("fail_request mark_terminal error: #{inspect(error)}")
    end
  end

  defp advance_fsm_best_effort(request_id, events) do
    has_delta? = Enum.any?(events, &(InferenceEvent.kind(&1) == :output_text_delta))

    try_advance(request_id, :running)

    if has_delta? do
      try_advance(request_id, :streaming)
    end
  end

  defp advance_fsm_best_effort_terminal(request_id, state) do
    try_advance(request_id, state)
  end

  defp try_advance(request_id, state) do
    case advance_fsm(request_id, state) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :already_terminal} -> :ok
      {:error, error} -> log_warn("FSM advance to #{state} failed: #{inspect(error)}")
    end
  end

  defp terminal_attrs_from_events(events) do
    usage = extract_usage(events)

    base_attrs =
      case Enum.find(events, &InferenceEvent.terminal?/1) do
        nil ->
          %{state: :completed, http_status: 200}

        %{event: %InferenceEvent.Completed{}} ->
          %{state: :completed, http_status: 200}

        %{event: %InferenceEvent.Failed{}} = event ->
          event
          |> ChatError.from_failed_event()
          |> ChatError.terminal_attrs()
      end

    Map.merge(base_attrs, usage)
  end

  defp maybe_put_first_token_at(attrs, nil), do: attrs
  defp maybe_put_first_token_at(attrs, %DateTime{} = ts), do: Map.put(attrs, :first_token_at, ts)

  defp extract_usage(events) do
    usage_event = Enum.find(events, &(InferenceEvent.kind(&1) == :usage))
    completed_event = Enum.find(events, &(InferenceEvent.kind(&1) == :completed))

    cond do
      usage_event != nil ->
        usage = usage_event.event.usage
        %{input_tokens: usage.input_tokens, output_tokens: usage.output_tokens}

      completed_event != nil && completed_event.event.usage != nil ->
        usage = completed_event.event.usage
        %{input_tokens: usage.input_tokens, output_tokens: usage.output_tokens}

      true ->
        %{input_tokens: 0, output_tokens: 0}
    end
  end

  defp build_execute_request(canonical, schedule) do
    deadline_ms =
      System.system_time(:millisecond) +
        Map.get(schedule, :request_timeout_ms, Inference.request_timeout_ms())

    %ExecuteInferenceRequest{
      request_id: canonical.public_id,
      controller_session_id: canonical.internal_id,
      model_id: canonical.model_ref.model_id,
      version: canonical.model_ref.version,
      rendered_prompt_utf8: canonical.rendered_prompt,
      input_tokens: canonical.input_token_count,
      params: build_generation_params(canonical),
      deadline_unix_ms: deadline_ms,
      metadata_json: Jason.encode!(canonical.metadata)
    }
  end

  defp build_model_load_request(model, schedule) do
    deadline_ms =
      System.system_time(:millisecond) +
        Map.get(schedule, :model_load_timeout_ms, Inference.model_load_timeout_ms())

    node_id =
      case Map.get(schedule, :node_id) do
        uuid when is_binary(uuid) -> uuid
        _ -> ""
      end

    %EnsureModelLoadedRequest{
      node_id: node_id,
      model_id: model.model_id,
      version: model.version,
      artifact_sha256: model.artifact_sha256,
      preload: false,
      deadline_unix_ms: deadline_ms,
      artifact_source_uri: model.artifact_source_uri || ""
    }
  end

  defp build_generation_params(%CanonicalRequest{sampling: sampling, tooling: tooling}) do
    {tools_json, tool_choice_json} = serialize_tooling(tooling)

    %GenerationParams{
      max_output_tokens: effective_max_output_tokens(sampling),
      temperature: sampling.temperature,
      top_p: sampling.top_p,
      stop_sequences: sampling.stop,
      tools_json: tools_json,
      tool_choice_json: tool_choice_json
    }
  end

  defp validate_resolved_tooling(%CanonicalRequest{tooling: tooling}) do
    case unresolved_tooling_reason(tooling) do
      nil -> :ok
      reason -> {:error, {:invalid_canonical_tooling, reason}}
    end
  end

  defp unresolved_tooling_reason(%CanonicalRequest.Tooling{} = tooling) do
    cond do
      unresolved_runtime_tools?(tooling.tools) ->
        "tooling.tools must contain resolved function definitions only"

      unresolved_requested_refs?(tooling.requested_tools) and
          unresolved_registry_snapshot?(tooling.requested_tools, tooling.registry_snapshot) ->
        "tool registry refs must be resolved before execute/3"

      requested_tools_present?(tooling.requested_tools) and
          not requested_tooling_aligned?(tooling) ->
        "requested_tools, registry_snapshot, and tooling.tools must stay aligned"

      not execution_snapshot_aligned?(tooling) ->
        "execution_snapshot must stay aligned with requested_tools, registry_snapshot, and tooling.tools"

      true ->
        nil
    end
  end

  defp unresolved_runtime_tools?(tools) when is_list(tools) do
    Enum.any?(tools, &ref_tool?/1)
  end

  defp unresolved_runtime_tools?(_tools), do: false

  defp unresolved_requested_refs?(requested_tools) when is_list(requested_tools) do
    requested_tool_refs(requested_tools) != []
  end

  defp unresolved_requested_refs?(_requested_tools), do: false

  defp requested_tools_present?(requested_tools) when is_list(requested_tools),
    do: requested_tools != []

  defp requested_tools_present?(_requested_tools), do: false

  defp unresolved_registry_snapshot?(requested_tools, registry_snapshot) do
    requested_refs = requested_tool_refs(requested_tools)

    case registry_snapshot_refs(registry_snapshot) do
      {:ok, snapshot_refs} -> snapshot_refs != requested_refs
      :error -> true
    end
  end

  defp requested_tooling_aligned?(%CanonicalRequest.Tooling{} = tooling) do
    requested_tools = tooling.requested_tools
    runtime_tools = tooling.tools

    is_list(runtime_tools) and
      length(requested_tools) == length(runtime_tools) and
      requested_tools_match_runtime?(requested_tools, runtime_tools) and
      requested_refs_match_snapshot_and_runtime?(
        requested_tools,
        runtime_tools,
        tooling.registry_snapshot
      )
  end

  defp requested_tools_match_runtime?(requested_tools, runtime_tools) do
    requested_tools
    |> Enum.zip(runtime_tools)
    |> Enum.all?(fn {requested_tool, runtime_tool} ->
      case requested_tool_identity(requested_tool) do
        {:inline, requested_name} -> requested_name == runtime_tool_name(runtime_tool)
        {:ref, _requested_ref} -> is_binary(runtime_tool_name(runtime_tool))
        :error -> false
      end
    end)
  end

  defp requested_refs_match_snapshot_and_runtime?(
         requested_tools,
         runtime_tools,
         registry_snapshot
       ) do
    case requested_tool_refs(requested_tools) do
      [] ->
        inline_requested_tools_match_snapshot?(registry_snapshot)

      _requested_refs ->
        requested_refs_match_snapshot_entries?(requested_tools, runtime_tools, registry_snapshot)
    end
  end

  defp inline_requested_tools_match_snapshot?(registry_snapshot) do
    match?({:ok, []}, registry_snapshot_entries(registry_snapshot))
  end

  defp requested_refs_match_snapshot_entries?(requested_tools, runtime_tools, registry_snapshot) do
    with {:ok, registry_entries} <- registry_snapshot_entries(registry_snapshot),
         {:ok, []} <- consume_registry_entries(requested_tools, runtime_tools, registry_entries) do
      true
    else
      _other -> false
    end
  end

  defp consume_registry_entries(requested_tools, runtime_tools, registry_entries) do
    requested_tools
    |> Enum.zip(runtime_tools)
    |> Enum.reduce_while({:ok, registry_entries}, &consume_registry_entry/2)
  end

  defp consume_registry_entry({requested_tool, runtime_tool}, {:ok, entries}) do
    case requested_tool_identity(requested_tool) do
      {:inline, _requested_name} -> {:cont, {:ok, entries}}
      {:ref, requested_ref} -> consume_ref_registry_entry(entries, requested_ref, runtime_tool)
      :error -> {:halt, :error}
    end
  end

  defp consume_ref_registry_entry([entry | rest], requested_ref, runtime_tool) do
    if registry_entry_matches_runtime?(entry, requested_ref, runtime_tool) do
      {:cont, {:ok, rest}}
    else
      {:halt, :error}
    end
  end

  defp consume_ref_registry_entry([], _requested_ref, _runtime_tool), do: {:halt, :error}

  defp registry_entry_matches_runtime?(entry, requested_ref, runtime_tool) do
    runtime_name = runtime_tool_name(runtime_tool)

    map_value(entry, :ref) == requested_ref and map_value(entry, :name) == runtime_name and
      is_binary(runtime_name)
  end

  defp requested_tool_refs(requested_tools) when is_list(requested_tools) do
    Enum.flat_map(requested_tools, fn tool ->
      case map_value(tool, :ref) do
        ref when is_binary(ref) -> [ref]
        _other -> []
      end
    end)
  end

  defp requested_tool_refs(_requested_tools), do: []

  defp requested_tool_identity(tool) when is_map(tool) do
    ref = map_value(tool, :ref)
    name = tool |> map_value(:function) |> function_name()
    has_ref? = map_has_key?(tool, :ref)
    has_function? = map_has_key?(tool, :function)

    cond do
      has_ref? and has_function? -> :error
      has_ref? and is_binary(ref) -> {:ref, ref}
      has_function? and is_binary(name) -> {:inline, name}
      true -> :error
    end
  end

  defp requested_tool_identity(_tool), do: :error

  defp runtime_tool_name(tool) when is_map(tool) do
    if is_nil(map_value(tool, :ref)) do
      tool |> map_value(:function) |> function_name()
    else
      nil
    end
  end

  defp runtime_tool_name(_tool), do: nil

  defp function_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp function_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp function_name(_function), do: nil

  defp registry_snapshot_entries(%{entries: entries}) when is_list(entries), do: {:ok, entries}

  defp registry_snapshot_entries(%{"entries" => entries}) when is_list(entries),
    do: {:ok, entries}

  defp registry_snapshot_entries(_registry_snapshot), do: :error

  defp registry_snapshot_refs(%{entries: entries}), do: registry_snapshot_refs(entries)
  defp registry_snapshot_refs(%{"entries" => entries}), do: registry_snapshot_refs(entries)

  defp registry_snapshot_refs(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, refs} ->
      case map_value(entry, :ref) do
        ref when is_binary(ref) -> {:cont, {:ok, [ref | refs]}}
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      :error -> :error
    end
  end

  defp registry_snapshot_refs(_registry_snapshot), do: :error

  defp execution_snapshot_aligned?(%CanonicalRequest.Tooling{} = tooling) do
    case ToolExecutionSemantics.build(tooling) do
      {:ok, expected_snapshot} -> snapshots_match?(tooling.execution_snapshot, expected_snapshot)
      {:error, _reason} -> false
    end
  end

  defp snapshots_match?(%{entries: actual_entries}, %{entries: expected_entries})
       when is_list(actual_entries) and is_list(expected_entries) do
    length(actual_entries) == length(expected_entries) and
      Enum.zip(actual_entries, expected_entries)
      |> Enum.all?(fn {actual_entry, expected_entry} ->
        snapshot_entry_matches?(actual_entry, expected_entry)
      end)
  end

  defp snapshot_entry_matches?(actual_entry, expected_entry) when is_map(actual_entry) do
    Enum.all?([:name, :provenance, :disposition, :execution_mode], fn key ->
      normalized_snapshot_value(actual_entry, key) ==
        normalized_snapshot_value(expected_entry, key)
    end)
  end

  defp snapshot_entry_matches?(_actual_entry, _expected_entry), do: false

  defp normalized_snapshot_value(entry, key) do
    case map_value(entry, key) do
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp ref_tool?(tool) when is_map(tool) do
    match?(value when is_binary(value), map_value(tool, :ref))
  end

  defp ref_tool?(_tool), do: false

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_has_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp serialize_tooling(%CanonicalRequest.Tooling{tools: tools, tool_choice: tool_choice}) do
    if ToolingValidation.effective_tool_calling?(tools, tool_choice) do
      {Jason.encode!(tools), serialize_tool_choice(tool_choice)}
    else
      {"", ""}
    end
  end

  defp serialize_tool_choice(nil), do: ""
  defp serialize_tool_choice(tool_choice), do: Jason.encode!(tool_choice)

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{max_output_tokens: value})
       when is_integer(value) and value > 0,
       do: value

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{}), do: 4096

  defp serialize_canonical_request(canonical) do
    {:ok, CanonicalRequestSerializer.serialize(canonical)}
  rescue
    error in ArgumentError ->
      log_warn("canonical_request serialization failed: #{Exception.message(error)}")
      {:error, {:canonical_request_serialization_failed, Exception.message(error)}}
  end

  defp log_warn(message) do
    require Logger
    Logger.warning("[RequestOrchestrator] #{message}")
  end
end
