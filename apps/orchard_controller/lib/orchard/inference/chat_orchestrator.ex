defmodule Orchard.Inference.ChatOrchestrator do
  @moduledoc """
  Orchestrates the full lifecycle of a chat completions request.

  Ties together validation, normalization, persistence, FSM state
  transitions, dispatch to the runtime, and terminal state recording.

  Used by both `ChatCompletionsController` (non-stream and stream)
  and any future programmatic callers.

  ## Flow

      validate → normalize → resolve model → tokenize → enforce context window
      → persist request row → start FSM → transition validated → schedule
      → transition scheduled → transition dispatching → dispatch → collect events
      → transition terminal → persist usage

  ## Error Handling

  Returns `{:error, {:validation, errors}}` for request validation failures,
  `{:error, {:model_not_found, model_ref}}` when the requested model doesn't
  exist or isn't active, and `{:error, reason}` for dispatch/persistence
  failures.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest, GenerationParams}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference
  alias Orchard.Inference.{ChatError, ChatRequestNormalizer, ChatRequestValidator}
  alias Orchard.InferenceEvent
  alias Orchard.Models
  alias Orchard.Models.ManifestParser
  alias Orchard.Requests
  alias Orchard.Requests.RequestServer
  alias Orchard.Scheduler.SingleNode
  alias Orchard.Tokenizer.Client, as: TokenizerClient

  # Default max output tokens when the client omits max_tokens / max_completion_tokens.
  # Applied at orchestration time for both context-window enforcement and runtime dispatch.
  # Canonical sampling keeps nil to preserve the distinction between "omitted" and "explicit".
  @default_max_output_tokens 4096

  @type orchestrate_result ::
          {:ok, CanonicalRequest.t(), [InferenceEvent.t()]}
          | {:error, term()}

  @doc """
  Prepares a chat completion request: validates, normalizes, resolves model.

  Returns `{:ok, canonical_request, model}` if all pre-dispatch checks pass.
  This step does not persist anything or start dispatch — use `execute/3` for that.

  `caller_context` is a keyword list from the request context plug:
    * `:tenant_id` — resolved tenant (default: `"default"` in M1)
    * `:principal_id` — resolved principal (nil in M1)
    * `:api_key_id` — resolved API key (nil in M1)

  Returns `{:error, {:validation, errors}}` for request validation failures,
  `{:error, {:model_not_found, model_ref}}` when the requested model doesn't
  exist or isn't active, `{:error, {:tokenization, reason}}` for prompt
  rendering/tokenizer failures, and `{:error, {:context_overflow, detail}}`
  when input tokens + max output tokens exceed the model's context window.
  """
  @spec prepare(map(), keyword()) :: {:ok, CanonicalRequest.t(), map()} | {:error, term()}
  def prepare(params, caller_context \\ []) do
    with {:ok, params} <- validate(params),
         {:ok, canonical} <- normalize(params, caller_context),
         {:ok, model} <- resolve_model(canonical),
         {:ok, canonical} <- tokenize(canonical, model),
         :ok <- enforce_context_window(canonical, model) do
      {:ok, canonical, model}
    end
  end

  @doc """
  Executes the dispatch pipeline for a prepared request.

  Persists the request row, starts the FSM, dispatches to the runtime,
  and finalizes terminal state.

  ## Options

    * `:event_handler` — optional callback `fun(request_id, event)` called
      with each `InferenceEvent` as it arrives from dispatch
    * `:caller` — optional pid to monitor for dispatch cancellation semantics
      (defaults to the current process)
  """
  @spec execute(CanonicalRequest.t(), map(), keyword()) :: orchestrate_result()
  def execute(canonical, model, opts \\ []) do
    event_handler = Keyword.get(opts, :event_handler)
    caller = Keyword.get(opts, :caller, self())
    execute_with_persistence(canonical, model, caller, event_handler)
  end

  @doc """
  Orchestrates a complete chat completion request from raw HTTP params.

  Convenience that calls `prepare/1` then `execute/3`. Suitable for
  non-streaming callers that don't need to start SSE between the two phases.

  Returns `{:ok, canonical_request, events}` on success, where `events`
  includes terminal (completed/failed/cancelled) events with usage data.

  ## Options

    * `:event_handler` — optional callback `fun(request_id, event)` for
      streaming-style event delivery
    * `:caller` — optional pid forwarded to the dispatcher for cancellation
      monitoring
  """
  @spec orchestrate(map(), keyword()) :: orchestrate_result()
  def orchestrate(params, opts \\ []) do
    caller_context = Keyword.get(opts, :caller_context, [])

    with {:ok, canonical, model} <- prepare(params, caller_context) do
      execute(canonical, model, opts)
    end
  end

  # After validation passes and model is resolved, we enter the persistence
  # boundary. From here, any failure must clean up the request row and FSM.
  defp execute_with_persistence(canonical, model, caller, event_handler) do
    with {:ok, db_request} <- persist_request(canonical, model),
         {:ok, _pid} <- start_fsm(db_request) do
      run_dispatch_pipeline(db_request, canonical, model, caller, event_handler)
    end
  end

  defp run_dispatch_pipeline(db_request, canonical, model, caller, event_handler) do
    result =
      with :ok <- advance_fsm(db_request.id, :validated),
           {:ok, schedule} <- schedule_request(canonical),
           :ok <- advance_fsm(db_request.id, :scheduled),
           :ok <- advance_fsm(db_request.id, :dispatching),
           {:ok, events} <- dispatch(canonical, model, schedule, caller, event_handler) do
        finalize(db_request, canonical, events)
      end

    case result do
      {:ok, _, _} = success ->
        success

      {:error, reason} ->
        # Pipeline failed after persistence — mark request as failed
        fail_request(db_request, reason)
        {:error, reason}
    end
  end

  # -- Steps -----------------------------------------------------------------

  defp validate(params) do
    case ChatRequestValidator.validate(params) do
      {:ok, validated} -> {:ok, validated}
      {:error, type, field} -> {:error, {:validation, {type, field}}}
      {:error, type, field, reason} -> {:error, {:validation, {type, field, reason}}}
    end
  end

  defp normalize(params, caller_context) do
    ChatRequestNormalizer.normalize(params, caller_context)
  end

  defp resolve_model(%CanonicalRequest{model_ref: model_ref}) do
    case Models.get_model_by_identity(model_ref.model_id, model_ref.version) do
      nil ->
        {:error, {:model_not_found, "#{model_ref.model_id}@#{model_ref.version}"}}

      %{state: :active} = model ->
        {:ok, model}

      %{state: state} ->
        {:error,
         {:model_not_found, "#{model_ref.model_id}@#{model_ref.version} is #{state}, not active"}}
    end
  end

  defp tokenize(canonical, model) do
    tokenizer_opts = build_tokenizer_opts(model)

    case TokenizerClient.tokenize(canonical, tokenizer_opts) do
      {:ok, %{rendered_prompt: prompt, input_token_count: count}} ->
        {:ok, CanonicalRequest.with_tokenization(canonical, prompt, count)}

      {:error, reason} ->
        {:error, {:tokenization, reason}}
    end
  end

  # In fake mode, the tokenizer doesn't need model assets.
  # In port mode, resolve the bundle root from the model's artifact_uri
  # and parse the manifest for tokenizer/chat-template asset paths.
  defp build_tokenizer_opts(model) do
    case TokenizerClient.mode() do
      :fake ->
        []

      :port ->
        bundle_root = uri_to_local_path(model.artifact_uri)

        case ManifestParser.parse_from_bundle(bundle_root) do
          {:ok, manifest} -> [manifest: manifest, bundle_root: bundle_root]
          {:error, _reason} -> []
        end

      _other ->
        []
    end
  end

  defp uri_to_local_path("file://" <> path), do: path
  defp uri_to_local_path(path), do: path

  defp enforce_context_window(canonical, model) do
    max_output = effective_max_output_tokens(canonical.sampling)
    total = canonical.input_token_count + max_output

    if total > model.max_context_tokens do
      {:error,
       {:context_overflow,
        "request requires #{total} tokens (#{canonical.input_token_count} input + #{max_output} output) but model supports at most #{model.max_context_tokens}"}}
    else
      :ok
    end
  end

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{max_output_tokens: n})
       when is_integer(n) and n > 0,
       do: n

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{}),
    do: @default_max_output_tokens

  defp persist_request(canonical, model) do
    attrs = %{
      id: canonical.internal_id,
      public_id: canonical.public_id,
      endpoint: :chat_completions,
      tenant_id: canonical.tenant_id,
      api_key_id: canonical.api_key_id,
      requested_model: "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}",
      model_id: model.id,
      state: :received,
      stream: canonical.stream?,
      payload_capture_mode: :metadata,
      canonical_request: safe_serialize_canonical_request(canonical),
      sampling_params: sampling_to_map(canonical.sampling),
      input_tokens: canonical.input_token_count
    }

    Requests.create_request(attrs)
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
    SingleNode.schedule(canonical)
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

  defp finalize(db_request, canonical, events) do
    terminal_attrs = terminal_attrs_from_events(events)

    # Advance FSM through intermediate states, then terminal.
    # Intermediate transitions are best-effort — the terminal transition
    # and DB update are what matter for durable correctness.
    advance_fsm_best_effort(db_request.id, events)
    advance_fsm_best_effort_terminal(db_request.id, terminal_attrs.state)

    case Requests.mark_terminal(db_request, terminal_attrs) do
      {:ok, _updated} -> {:ok, canonical, events}
      {:error, reason} -> {:error, {:terminal_persist_failed, reason}}
    end
  end

  defp fail_request(db_request, reason) do
    # Best-effort: move FSM to a terminal state and mark DB row terminal.
    # This runs after an orchestration error, so failures here are logged
    # but not propagated (the original error is returned to the caller).
    terminal_attrs =
      reason
      |> ChatError.from_execute_error()
      |> ChatError.terminal_attrs()

    advance_fsm_best_effort_terminal(db_request.id, terminal_attrs.state)

    case Requests.mark_terminal(db_request, terminal_attrs) do
      {:ok, _} -> :ok
      {:error, err} -> log_warn("fail_request mark_terminal error: #{inspect(err)}")
    end
  end

  defp advance_fsm_best_effort(request_id, events) do
    has_delta? = Enum.any?(events, &(InferenceEvent.kind(&1) == :output_text_delta))

    try_advance(request_id, :running)
    if has_delta?, do: try_advance(request_id, :streaming)
  end

  defp advance_fsm_best_effort_terminal(request_id, state) do
    try_advance(request_id, state)
  end

  defp try_advance(request_id, state) do
    case advance_fsm(request_id, state) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :already_terminal} -> :ok
      {:error, err} -> log_warn("FSM advance to #{state} failed: #{inspect(err)}")
    end
  end

  defp log_warn(message) do
    require Logger
    Logger.warning("[ChatOrchestrator] #{message}")
  end

  # -- Proto message builders ------------------------------------------------

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

  # -- Event analysis --------------------------------------------------------

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
    # Usage can come from UsageUpdate or Completed events
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

  # -- Helpers ---------------------------------------------------------------

  defp safe_serialize_canonical_request(canonical) do
    serialize_canonical_request(canonical)
  rescue
    e in ArgumentError ->
      log_warn("canonical_request serialization failed: #{Exception.message(e)}")
      nil
  end

  defp serialize_canonical_request(%CanonicalRequest{} = canonical) do
    %{
      "internal_id" => canonical.internal_id,
      "public_id" => canonical.public_id,
      "endpoint" => Atom.to_string(canonical.endpoint),
      "tenant_id" => canonical.tenant_id,
      "principal_id" => canonical.principal_id,
      "api_key_id" => canonical.api_key_id,
      "model_ref" => serialize_model_ref(canonical.model_ref),
      "input_items" => normalize_plain_data(canonical.input_items),
      "rendered_prompt" => canonical.rendered_prompt,
      "input_token_count" => canonical.input_token_count,
      "stream" => canonical.stream?,
      "stream_include_usage" => canonical.stream_include_usage,
      "sampling" => serialize_sampling(canonical.sampling),
      "response_format" => serialize_response_format(canonical.response_format),
      "tooling" => serialize_tooling(canonical.tooling),
      "metadata" => normalize_plain_data(canonical.metadata),
      "admission" => serialize_admission(canonical.admission),
      "resolved_policy" => serialize_resolved_policy(canonical.resolved_policy)
    }
  end

  defp serialize_model_ref(%CanonicalRequest.ModelRef{} = model_ref) do
    %{
      "model_id" => model_ref.model_id,
      "version" => model_ref.version
    }
  end

  defp serialize_sampling(%CanonicalRequest.Sampling{} = sampling) do
    %{
      "temperature" => sampling.temperature,
      "top_p" => sampling.top_p,
      "max_output_tokens" => sampling.max_output_tokens,
      "stop" => normalize_plain_data(sampling.stop),
      "seed" => sampling.seed
    }
  end

  defp serialize_response_format(%CanonicalRequest.ResponseFormat{} = response_format) do
    %{"type" => Atom.to_string(response_format.type)}
  end

  defp serialize_tooling(%CanonicalRequest.Tooling{} = tooling) do
    %{
      "tools" => normalize_plain_data(tooling.tools),
      "tool_choice" => normalize_plain_data(tooling.tool_choice)
    }
  end

  defp serialize_admission(%CanonicalRequest.Admission{} = admission) do
    %{
      "timeout_ms" => admission.timeout_ms,
      "queue_wait_ms" => admission.queue_wait_ms,
      "max_cold_start_ms" => admission.max_cold_start_ms
    }
  end

  defp serialize_resolved_policy(%CanonicalRequest.ResolvedPolicy{} = resolved_policy) do
    %{
      "quota_id" => resolved_policy.quota_id,
      "routing_policy_id" => resolved_policy.routing_policy_id,
      "allowed_pool_ids" => normalize_plain_data(resolved_policy.allowed_pool_ids),
      "residency_preference" => Atom.to_string(resolved_policy.residency_preference)
    }
  end

  defp normalize_plain_data(nil), do: nil

  defp normalize_plain_data(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp normalize_plain_data(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_plain_data(values) when is_list(values),
    do: Enum.map(values, &normalize_plain_data/1)

  defp normalize_plain_data(%{__struct__: struct_name}) do
    raise ArgumentError,
          "expected plain map data while serializing canonical request, got struct: #{inspect(struct_name)}"
  end

  defp normalize_plain_data(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_map_key(key), normalize_plain_data(value)}
    end)
  end

  defp sampling_to_map(sampling) do
    %{
      "temperature" => sampling.temperature,
      "top_p" => sampling.top_p,
      "max_output_tokens" => sampling.max_output_tokens,
      "stop" => sampling.stop,
      "seed" => sampling.seed
    }
  end

  defp normalize_map_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_map_key(key) when is_binary(key), do: key
  defp normalize_map_key(key), do: to_string(key)
end
