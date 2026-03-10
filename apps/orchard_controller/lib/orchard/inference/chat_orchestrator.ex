defmodule Orchard.Inference.ChatOrchestrator do
  @moduledoc """
  Orchestrates the full lifecycle of a chat completions request.

  Ties together validation, normalization, persistence, FSM state
  transitions, dispatch to the runtime, and terminal state recording.

  Used by both `ChatCompletionsController` (non-stream and stream)
  and any future programmatic callers.

  ## Flow

      validate → normalize → resolve model → persist request row
      → start FSM → transition validated → schedule → transition scheduled
      → transition dispatching → dispatch → collect events
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
  alias Orchard.Inference.{ChatRequestNormalizer, ChatRequestValidator}
  alias Orchard.InferenceEvent
  alias Orchard.Models
  alias Orchard.Requests
  alias Orchard.Requests.RequestServer
  alias Orchard.Scheduler.SingleNode

  @type orchestrate_result ::
          {:ok, CanonicalRequest.t(), [InferenceEvent.t()]}
          | {:error, term()}

  @doc """
  Orchestrates a non-streaming chat completion request from raw HTTP params.

  Returns `{:ok, canonical_request, events}` on success, where `events`
  includes terminal (completed/failed/cancelled) events with usage data.

  ## Options

    * `:event_handler` — optional callback `fun(request_id, event)` for
      streaming-style event delivery (used by A5)
  """
  @spec orchestrate(map(), keyword()) :: orchestrate_result()
  def orchestrate(params, opts \\ []) do
    event_handler = Keyword.get(opts, :event_handler)

    with {:ok, params} <- validate(params),
         {:ok, canonical} <- normalize(params),
         {:ok, model} <- resolve_model(canonical) do
      execute_with_persistence(canonical, model, event_handler)
    end
  end

  # After validation passes and model is resolved, we enter the persistence
  # boundary. From here, any failure must clean up the request row and FSM.
  defp execute_with_persistence(canonical, model, event_handler) do
    with {:ok, db_request} <- persist_request(canonical, model),
         {:ok, _pid} <- start_fsm(db_request) do
      run_dispatch_pipeline(db_request, canonical, model, event_handler)
    end
  end

  defp run_dispatch_pipeline(db_request, canonical, model, event_handler) do
    result =
      with :ok <- advance_fsm(db_request.id, :validated),
           {:ok, schedule} <- schedule_request(canonical),
           :ok <- advance_fsm(db_request.id, :scheduled),
           :ok <- advance_fsm(db_request.id, :dispatching),
           {:ok, events} <- dispatch(canonical, model, schedule, event_handler) do
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

  defp normalize(params) do
    ChatRequestNormalizer.normalize(params)
  end

  defp resolve_model(%CanonicalRequest{model_ref: model_ref}) do
    case Models.get_model_by_identity(model_ref.model_id, model_ref.version) do
      nil ->
        {:error, {:model_not_found, "#{model_ref.model_id}@#{model_ref.version}"}}

      %{state: :active} = model ->
        {:ok, model}

      %{state: state} ->
        {:error,
         {:model_not_found,
          "#{model_ref.model_id}@#{model_ref.version} is #{state}, not active"}}
    end
  end

  defp persist_request(canonical, model) do
    attrs = %{
      id: canonical.internal_id,
      public_id: canonical.public_id,
      endpoint: :chat_completions,
      tenant_id: canonical.tenant_id,
      requested_model: "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}",
      model_id: model.id,
      state: :received,
      stream: canonical.stream?,
      payload_capture_mode: :metadata,
      sampling_params: sampling_to_map(canonical.sampling),
      input_tokens: 0
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

  defp dispatch(canonical, model, schedule, event_handler) do
    execute_request = build_execute_request(canonical, schedule)
    model_load_request = build_model_load_request(model, schedule)

    RequestDispatcher.dispatch(
      schedule,
      execute_request,
      model_load_request,
      event_handler: event_handler
    )
  end

  defp finalize(db_request, canonical, events) do
    {fsm_state, usage} = extract_terminal_info(events)

    # Advance FSM through intermediate states, then terminal.
    # Intermediate transitions are best-effort — the terminal transition
    # and DB update are what matter for durable correctness.
    advance_fsm_best_effort(db_request.id, events)
    advance_fsm_best_effort_terminal(db_request.id, fsm_state)

    # Persist terminal state and usage on the request row
    terminal_attrs = %{
      state: fsm_state,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      http_status: if(fsm_state == :completed, do: 200, else: 500)
    }

    case Requests.mark_terminal(db_request, terminal_attrs) do
      {:ok, _updated} -> {:ok, canonical, events}
      {:error, reason} -> {:error, {:terminal_persist_failed, reason}}
    end
  end

  defp fail_request(db_request, reason) do
    # Best-effort: move FSM to :failed and mark DB row terminal.
    # This runs after an orchestration error, so failures here are logged
    # but not propagated (the original error is returned to the caller).
    advance_fsm_best_effort_terminal(db_request.id, :failed)

    terminal_attrs = %{
      state: :failed,
      http_status: 500,
      error_code: "orchestration_error",
      error_message: inspect(reason)
    }

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
      rendered_prompt_utf8: canonical.rendered_prompt || "",
      input_tokens: canonical.input_token_count,
      params: build_generation_params(canonical.sampling),
      deadline_unix_ms: deadline_ms,
      metadata_json: Jason.encode!(canonical.metadata)
    }
  end

  defp build_model_load_request(model, schedule) do
    deadline_ms =
      System.system_time(:millisecond) +
        Map.get(schedule, :request_timeout_ms, Inference.request_timeout_ms())

    %EnsureModelLoadedRequest{
      node_id: "",
      model_id: model.model_id,
      version: model.version,
      artifact_sha256: model.artifact_sha256,
      preload: false,
      deadline_unix_ms: deadline_ms
    }
  end

  defp build_generation_params(sampling) do
    %GenerationParams{
      max_output_tokens: sampling.max_output_tokens || 0,
      temperature: sampling.temperature,
      top_p: sampling.top_p,
      stop_sequences: sampling.stop
    }
  end

  # -- Event analysis --------------------------------------------------------

  defp extract_terminal_info(events) do
    terminal = Enum.find(events, &InferenceEvent.terminal?/1)
    usage = extract_usage(events)

    state =
      case terminal do
        nil -> :completed
        event -> map_terminal_state(event)
      end

    {state, usage}
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

  defp map_terminal_state(event) do
    case InferenceEvent.kind(event) do
      :completed -> :completed
      :failed -> :failed
      _ -> :completed
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp sampling_to_map(sampling) do
    %{
      "temperature" => sampling.temperature,
      "top_p" => sampling.top_p,
      "max_output_tokens" => sampling.max_output_tokens,
      "stop" => sampling.stop
    }
  end
end
