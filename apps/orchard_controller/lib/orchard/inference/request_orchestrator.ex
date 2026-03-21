defmodule Orchard.Inference.RequestOrchestrator do
  @moduledoc """
  Executes the shared durable request lifecycle for prepared canonical requests.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest, GenerationParams}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference
  alias Orchard.Inference.{CanonicalRequestSerializer, ChatError}
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

    with {:ok, db_request} <- persist_request(canonical, model, idempotency) do
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
           :ok <- advance_fsm(db_request.id, :scheduled),
           :ok <- advance_fsm(db_request.id, :dispatching),
           {:ok, events} <- dispatch(canonical, model, schedule, caller, event_handler) do
        finalize(db_request, canonical, model, events, success_persistence)
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

  defp dispatch(canonical, model, schedule, caller, event_handler) do
    execute_request = build_execute_request(canonical, schedule)
    model_load_request = build_model_load_request(model, schedule)

    RequestDispatcher.dispatch(
      schedule,
      execute_request,
      model_load_request,
      caller: caller,
      event_handler: event_handler
    )
  end

  defp finalize(db_request, canonical, _model, events, success_persistence) do
    case build_terminal_attrs(canonical, events, success_persistence) do
      {:ok, terminal_attrs} ->
        persist_terminal(db_request, canonical, events, terminal_attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_terminal_attrs(canonical, events, success_persistence) do
    terminal_attrs = terminal_attrs_from_events(events)

    if terminal_attrs.state == :completed and not canonical.stream? and
         is_function(success_persistence, 2) do
      success_persistence
      |> apply_success_persistence(canonical, events)
      |> merge_success_attrs(terminal_attrs)
    else
      {:ok, terminal_attrs}
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
      params: build_generation_params(canonical.sampling),
      deadline_unix_ms: deadline_ms,
      metadata_json: Jason.encode!(canonical.metadata)
    }
  end

  defp build_model_load_request(model, schedule) do
    deadline_ms =
      System.system_time(:millisecond) +
        Map.get(schedule, :model_load_timeout_ms, Inference.model_load_timeout_ms())

    %EnsureModelLoadedRequest{
      node_id: "",
      model_id: model.model_id,
      version: model.version,
      artifact_sha256: model.artifact_sha256,
      preload: false,
      deadline_unix_ms: deadline_ms,
      artifact_source_uri: model.artifact_source_uri || ""
    }
  end

  defp build_generation_params(sampling) do
    %GenerationParams{
      max_output_tokens: effective_max_output_tokens(sampling),
      temperature: sampling.temperature,
      top_p: sampling.top_p,
      stop_sequences: sampling.stop
    }
  end

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
