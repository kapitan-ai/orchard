defmodule Orchard.Dispatch.RequestDispatcher do
  @moduledoc """
  Orchestrates the dispatch of an inference request to a node-agent.

  Implements the M1 single-node dispatch flow:

    schedule → connect → ensure_model_loaded → execute_inference → stream events

  Monitors for:
  - Request timeout → sends CancelInference to the node
  - Caller process exit → sends CancelInference to the node

  Timing instrumentation logs one 'dispatch_timing' line per dispatch attempt,
  capturing cold/warm classification, stream timing, and outcome.
  """

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest
  }

  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: DefaultClient
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.InferenceEvent

  require Logger

  # Metrics structure for timing instrumentation
  defmodule Metrics do
    @moduledoc false

    defstruct request_id: nil,
              model_id: "unknown",
              version: "unknown",
              input_tokens: 0,
              model_already_loaded: :unknown,
              ensure_model_loaded_ms: :na,
              accepted_monotonic_ms: nil,
              first_delta_monotonic_ms: nil,
              terminal_monotonic_ms: nil,
              accepted_to_first_delta_ms: :na,
              accepted_to_terminal_ms: :na,
              outcome: :ok,
              terminal_kind: :none,
              terminal_source: :none,
              terminal_detail: :na,
              event_count: 0,
              anomaly: :none

    @type t :: %__MODULE__{
            request_id: String.t(),
            model_id: String.t(),
            version: String.t(),
            input_tokens: non_neg_integer(),
            model_already_loaded: boolean() | :unknown,
            ensure_model_loaded_ms: non_neg_integer() | :na,
            accepted_monotonic_ms: integer() | nil,
            first_delta_monotonic_ms: integer() | nil,
            terminal_monotonic_ms: integer() | nil,
            accepted_to_first_delta_ms: non_neg_integer() | :na,
            accepted_to_terminal_ms: non_neg_integer() | :na,
            outcome: :ok | :model_load_failed | :dispatch_failed,
            terminal_kind: :completed | :failed | :none,
            terminal_source: :stream | :synthesized | :none,
            terminal_detail: String.t() | :na,
            event_count: non_neg_integer(),
            anomaly: :none | :delta_before_accepted | :terminal_before_accepted
          }

    @spec new(keyword()) :: t()
    def new(opts) do
      %__MODULE__{
        request_id: Keyword.fetch!(opts, :request_id),
        model_id: Keyword.get(opts, :model_id, "unknown"),
        version: Keyword.get(opts, :version, "unknown"),
        input_tokens: Keyword.get(opts, :input_tokens, 0),
        model_already_loaded: :unknown,
        ensure_model_loaded_ms: :na,
        accepted_monotonic_ms: nil,
        first_delta_monotonic_ms: nil,
        terminal_monotonic_ms: nil,
        accepted_to_first_delta_ms: :na,
        accepted_to_terminal_ms: :na,
        outcome: :ok,
        terminal_kind: :none,
        terminal_source: :none,
        terminal_detail: :na,
        event_count: 0,
        anomaly: :none
      }
    end
  end

  @status_probe_timeout_ms 1_000

  @type dispatch_result ::
          {:ok, [InferenceEvent.t()]}
          | {:error,
             {:model_load_failed, ModelLoadFailure.t()} | {:dispatch_failed, term()} | term()}

  @doc """
  Dispatch an inference request to a node and stream events back to the caller.

  `schedule` is the map returned by `SingleNode.schedule/1` containing:
  - `:runtime_client_target` — `[host: ..., port: ...]` for the node-agent
  - `:request_id` — the canonical request ID
  - `:request_timeout_ms` — maximum wall-clock time for the entire dispatch

  `execute_request` is the protobuf `ExecuteInferenceRequest` to send.

  `model_load_request` is the protobuf `EnsureModelLoadedRequest` to send.

  Options:
  - `:caller` — PID to monitor for disconnect (default: `self()`)
  - `:event_handler` — function called with each `InferenceEvent`.
                        Return `:cancel` to abort dispatch (e.g. on SSE client disconnect).
                        (default: sends `{:inference_event, request_id, event}` to caller)
  - `:on_node_resolved` — optional callback `(node_id :: String.t() -> any())`.
                           Called when the pre-dispatch status probe discovers a
                           valid node UUID. Synchronous, lightweight, observational only.
                           Exceptions are rescued; return value is ignored.
  - `:client_impl` — gRPC client module (default: `GrpcNodeRuntimeClient`)

  Returns `{:ok, events}` with the list of all events received (including terminal),
  or `{:error, reason}` if dispatch fails before streaming begins.
  """
  @spec dispatch(
          schedule :: map(),
          execute_request :: ExecuteInferenceRequest.t(),
          model_load_request :: EnsureModelLoadedRequest.t(),
          opts :: keyword()
        ) :: dispatch_result()
  def dispatch(
        schedule,
        %ExecuteInferenceRequest{} = execute_request,
        %EnsureModelLoadedRequest{} = model_load_request,
        opts \\ []
      ) do
    target = Map.fetch!(schedule, :runtime_client_target)
    request_id = Map.fetch!(schedule, :request_id)
    timeout_ms = Map.fetch!(schedule, :request_timeout_ms)
    model_load_timeout = Map.get(schedule, :model_load_timeout_ms, 120_000)
    caller = Keyword.get(opts, :caller, self())
    event_handler = Keyword.get(opts, :event_handler)
    on_node_resolved = Keyword.get(opts, :on_node_resolved)
    client = Keyword.get(opts, :client_impl, DefaultClient)

    # Initialize timing metrics
    metrics =
      Metrics.new(
        request_id: request_id,
        model_id: model_load_request.model_id,
        version: model_load_request.version,
        input_tokens: execute_request.input_tokens
      )

    case client.connect(target) do
      {:ok, channel} ->
        try do
          # Pre-dispatch status probe: resolve node identity, persist observation,
          # and patch the model load request with the discovered node_id.
          model_load_request =
            probe_and_resolve_node(
              client,
              channel,
              target,
              model_load_request,
              on_node_resolved
            )

          # Measure ensure_model_loaded duration
          ensure_start = System.monotonic_time(:millisecond)

          case do_ensure_model_loaded(
                 client,
                 channel,
                 target,
                 model_load_request,
                 model_load_timeout
               ) do
            {:ok, ensure_load_meta} ->
              ensure_end = System.monotonic_time(:millisecond)

              metrics = %{
                metrics
                | ensure_model_loaded_ms: ensure_end - ensure_start,
                  model_already_loaded: ensure_load_meta.already_loaded
              }

              result =
                do_execute_and_stream(
                  client,
                  channel,
                  target,
                  execute_request,
                  metrics,
                  timeout_ms,
                  caller,
                  event_handler
                )

              # Public API returns {:ok, events} - discard metrics from return value
              case result do
                {:ok, events, final_metrics} ->
                  emit_timing_log(final_metrics, :ok)
                  {:ok, events}

                {:error, reason} ->
                  emit_timing_log(metrics, {:error, reason})
                  {:error, reason}
              end

            {:error, reason} ->
              ensure_end = System.monotonic_time(:millisecond)

              metrics = %{
                metrics
                | ensure_model_loaded_ms: ensure_end - ensure_start,
                  model_already_loaded: false
              }

              emit_timing_log(metrics, {:error, {:model_load_failed, reason}})
              {:error, {:model_load_failed, reason}}
          end
        after
          client.disconnect(channel)
        end

      {:error, {:connect_failed, _reason} = reason} ->
        mark_transport_failure(target, reason)
        emit_timing_log(metrics, {:error, {:model_load_failed, :node_unavailable}})
        {:error, {:model_load_failed, ModelLoadFailure.from_transport_reason(:node_unavailable)}}
    end
  end

  # -- Private ---------------------------------------------------------------

  # Pre-dispatch status probe: best-effort node identity resolution.
  # Never aborts dispatch on failure.
  defp probe_and_resolve_node(client, channel, target, model_load_request, on_node_resolved) do
    case client.status(channel, timeout: @status_probe_timeout_ms) do
      {:ok, response} ->
        # Best-effort persistence
        observed_at = DateTime.utc_now()

        try do
          Orchard.Nodes.observe_status(target, response, observed_at)
        rescue
          error ->
            Logger.warning("Node observation failed during dispatch probe: #{inspect(error)}")
        end

        # Extract and validate node_id from metadata
        case extract_node_id(response) do
          {:ok, node_id} ->
            invoke_callback_safe(on_node_resolved, node_id)
            %{model_load_request | node_id: node_id}

          :error ->
            model_load_request
        end

      {:error, reason} ->
        # Probe failure is non-fatal, but we still record transport reachability
        # best-effort for node health.
        mark_transport_failure(target, reason)
        model_load_request
    end
  rescue
    error ->
      Logger.warning("Status probe failed unexpectedly: #{inspect(error)}")
      model_load_request
  end

  defp extract_node_id(%{node_metadata: %{node_id: node_id}}) when is_binary(node_id) do
    Ecto.UUID.cast(node_id)
  end

  defp extract_node_id(_), do: :error

  defp invoke_callback_safe(nil, _node_id), do: :ok

  defp invoke_callback_safe(callback, node_id) when is_function(callback, 1) do
    callback.(node_id)
  rescue
    error ->
      Logger.warning("on_node_resolved callback failed: #{inspect(error)}")
  end

  defp do_ensure_model_loaded(client, channel, target, request, timeout_ms) do
    case client.ensure_model_loaded(channel, request, timeout: timeout_ms) do
      {:ok, %EnsureModelLoadedResponse{} = response} ->
        case normalize_placement_state(response.placement_state) do
          :loaded ->
            {:ok, %{already_loaded: response.already_loaded}}

          :failed ->
            {:error, ModelLoadFailure.from_response(response)}

          {:unexpected, placement_state} ->
            {:error,
             ModelLoadFailure.from_transport_reason(
               {:unexpected_placement_state, placement_state}
             )}
        end

      {:error, reason} ->
        mark_transport_failure(target, reason)
        {:error, ModelLoadFailure.from_transport_reason(reason)}
    end
  end

  defp normalize_placement_state(:PLACEMENT_STATE_LOADED), do: :loaded
  defp normalize_placement_state(7), do: :loaded
  defp normalize_placement_state(:PLACEMENT_STATE_FAILED), do: :failed
  defp normalize_placement_state(10), do: :failed
  defp normalize_placement_state(other), do: {:unexpected, other}

  defp do_execute_and_stream(
         client,
         channel,
         target,
         request,
         metrics,
         timeout_ms,
         caller,
         event_handler
       ) do
    caller_ref = Process.monitor(caller)
    timer_ref = start_timeout_timer(timeout_ms)

    {:ok, task_ref} = client.execute_inference(channel, request, owner: self())

    loop_ctx = %{
      caller_ref: caller_ref,
      channel: channel,
      client: client,
      event_handler: event_handler,
      metrics: metrics,
      target: target,
      task_ref: task_ref,
      timer_ref: timer_ref
    }

    result = receive_loop(loop_ctx, [])

    cleanup(timer_ref, caller_ref)
    result
  end

  defp receive_loop(%{} = loop_ctx, events) do
    %{
      client: client,
      channel: channel,
      target: target,
      metrics: metrics,
      task_ref: task_ref,
      timer_ref: timer_ref,
      caller_ref: caller_ref,
      event_handler: event_handler
    } = loop_ctx

    request_id = metrics.request_id

    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        handler_result = emit_event(event, request_id, event_handler)
        events = [event | events]
        metrics = update_metrics_for_event(metrics, event)

        cond do
          InferenceEvent.terminal?(event) ->
            {:ok, Enum.reverse(events), metrics}

          cancelled_by_handler?(handler_result) ->
            _ = client.cancel_inference(channel, request_id)

            drain_until_terminal_or_done(
              %{loop_ctx | metrics: metrics},
              events,
              :client_disconnect
            )

          true ->
            receive_loop(%{loop_ctx | metrics: metrics}, events)
        end

      {:dispatch_done, ^task_ref, :ok} ->
        {:ok, Enum.reverse(events), metrics}

      {:dispatch_done, ^task_ref, {:error, reason}} ->
        mark_transport_failure(target, reason)

        if events == [] do
          {:error, {:dispatch_failed, reason}}
        else
          has_terminal? = Enum.any?(events, &InferenceEvent.terminal?/1)

          if has_terminal? do
            {:ok, Enum.reverse(events), metrics}
          else
            failed_event =
              InferenceEvent.failed(
                "stream_error",
                "stream ended with error: #{inspect(reason)}",
                false
              )

            emit_event(failed_event, request_id, event_handler)
            metrics = update_metrics_for_terminal(metrics, failed_event, :stream)
            {:ok, Enum.reverse([failed_event | events]), metrics}
          end
        end

      {:dispatch_timeout, ^timer_ref} ->
        _ = client.cancel_inference(channel, request_id)
        drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, :timeout)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        _ = client.cancel_inference(channel, request_id)
        drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, :caller_disconnect)
    end
  end

  # After sending cancel (due to timeout or disconnect), drain remaining events
  # until we get a terminal event or the stream completes.
  defp drain_until_terminal_or_done(%{} = loop_ctx, events, cancel_reason) do
    %{task_ref: task_ref, metrics: metrics, event_handler: event_handler} = loop_ctx
    request_id = metrics.request_id

    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        emit_event(event, request_id, event_handler)
        events = [event | events]
        metrics = update_metrics_for_event(metrics, event)

        if InferenceEvent.terminal?(event) do
          {:ok, Enum.reverse(events), metrics}
        else
          drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, cancel_reason)
        end

      {:dispatch_done, ^task_ref, _result} ->
        # Stream ended without a terminal event after cancel.
        # Synthesize a terminal event so the caller always gets one.
        timeout_event =
          InferenceEvent.failed(
            "request_#{cancel_reason}",
            "request #{cancel_reason}",
            false
          )

        emit_event(timeout_event, request_id, event_handler)

        metrics =
          metrics
          |> increment_event_count()
          |> update_metrics_for_terminal(timeout_event, :synthesized)

        {:ok, Enum.reverse([timeout_event | events]), metrics}
    after
      5_000 ->
        # Safety valve: if neither terminal event nor stream completion
        # arrives within 5s after cancel, synthesize and return.
        timeout_event =
          InferenceEvent.failed(
            "request_#{cancel_reason}",
            "request #{cancel_reason} (drain timeout)",
            false
          )

        emit_event(timeout_event, request_id, event_handler)

        metrics =
          metrics
          |> increment_event_count()
          |> update_metrics_for_terminal(timeout_event, :synthesized)

        {:ok, Enum.reverse([timeout_event | events]), metrics}
    end
  end

  defp mark_transport_failure(target, reason) do
    Orchard.Nodes.record_transport_failure(target, reason, DateTime.utc_now())
  rescue
    error ->
      Logger.warning(
        "Failed to mark target transport failure for #{inspect(target)}: #{inspect(error)}"
      )
  end

  defp emit_event(_event, _request_id, nil), do: :ok

  defp emit_event(event, request_id, handler) when is_function(handler, 2) do
    handler.(request_id, event)
  end

  defp cancelled_by_handler?(handler_result), do: handler_result == :cancel

  defp start_timeout_timer(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    ref = make_ref()
    Process.send_after(self(), {:dispatch_timeout, ref}, timeout_ms)
    ref
  end

  defp cleanup(timer_ref, caller_ref) do
    # Cancel the timeout timer and flush if it already fired
    Process.cancel_timer(timer_ref)

    receive do
      {:dispatch_timeout, ^timer_ref} -> :ok
    after
      0 -> :ok
    end

    Process.demonitor(caller_ref, [:flush])
  end

  # -- Metrics tracking -----------------------------------------------------

  # Update metrics based on the event type.
  # Tracks first Accepted timestamp, first delta timestamp, and terminal events.
  defp update_metrics_for_event(%Metrics{} = metrics, %InferenceEvent{} = event) do
    metrics
    |> increment_event_count()
    |> track_accepted_event(event)
    |> track_first_delta(event)
    |> track_terminal_event(event)
  end

  defp increment_event_count(%Metrics{event_count: count} = metrics) do
    %{metrics | event_count: count + 1}
  end

  # Track first Accepted event (cold start measurement starts from this)
  defp track_accepted_event(
         %Metrics{accepted_monotonic_ms: nil} = metrics,
         %InferenceEvent{event: %InferenceEvent.Accepted{}} = _event
       ) do
    %{metrics | accepted_monotonic_ms: System.monotonic_time(:millisecond)}
  end

  defp track_accepted_event(metrics, _event), do: metrics

  # Track first OutputTextDelta (measures time from accepted to first output)
  defp track_first_delta(
         %Metrics{first_delta_monotonic_ms: nil} = metrics,
         %InferenceEvent{event: %InferenceEvent.OutputTextDelta{}} = _event
       ) do
    now_ms = System.monotonic_time(:millisecond)
    metrics = %{metrics | first_delta_monotonic_ms: now_ms}

    # Compute accepted_to_first_delta_ms if we have accepted timestamp
    case metrics.accepted_monotonic_ms do
      nil ->
        if metrics.anomaly == :none,
          do: %{metrics | anomaly: :delta_before_accepted},
          else: metrics

      accepted_ms ->
        %{metrics | accepted_to_first_delta_ms: now_ms - accepted_ms}
    end
  end

  defp track_first_delta(metrics, _event), do: metrics

  # Track terminal events (Completed or Failed)
  defp track_terminal_event(%Metrics{} = metrics, %InferenceEvent{} = event) do
    if InferenceEvent.terminal?(event) do
      update_metrics_for_terminal(metrics, event, :stream)
    else
      metrics
    end
  end

  # Update metrics for a terminal event (from stream or synthesized)
  defp update_metrics_for_terminal(%Metrics{} = metrics, %InferenceEvent{} = event, source) do
    now_ms = System.monotonic_time(:millisecond)
    metrics = %{metrics | terminal_monotonic_ms: now_ms, terminal_source: source}

    # Set terminal_kind based on event type
    metrics =
      case event.event do
        %InferenceEvent.Completed{} ->
          %{metrics | terminal_kind: :completed}

        %InferenceEvent.Failed{code: code, message: message} ->
          %{metrics | terminal_kind: :failed, terminal_detail: "#{code}: #{message}"}

        _ ->
          metrics
      end

    # Compute accepted_to_terminal_ms if we have accepted timestamp
    case metrics.accepted_monotonic_ms do
      nil ->
        if metrics.anomaly == :none,
          do: %{metrics | anomaly: :terminal_before_accepted},
          else: metrics

      accepted_ms ->
        %{metrics | accepted_to_terminal_ms: now_ms - accepted_ms}
    end
  end

  defp emit_timing_log(%Metrics{} = metrics, result) do
    # Finalize metrics based on result
    metrics = finalize_metrics(metrics, result)

    Logger.info(
      "dispatch_timing " <>
        "request_id=#{metrics.request_id} " <>
        "model_id=#{metrics.model_id} " <>
        "version=#{metrics.version} " <>
        "input_tokens=#{metrics.input_tokens} " <>
        "model_already_loaded=#{serialize_bool(metrics.model_already_loaded)} " <>
        "ensure_model_loaded_ms=#{serialize_na(metrics.ensure_model_loaded_ms)} " <>
        "accepted_to_first_delta_ms=#{serialize_na(metrics.accepted_to_first_delta_ms)} " <>
        "accepted_to_terminal_ms=#{serialize_na(metrics.accepted_to_terminal_ms)} " <>
        "terminal_kind=#{metrics.terminal_kind} " <>
        "terminal_source=#{metrics.terminal_source} " <>
        "terminal_detail=#{serialize_na(metrics.terminal_detail)} " <>
        "outcome=#{metrics.outcome} " <>
        "event_count=#{metrics.event_count} " <>
        "anomaly=#{metrics.anomaly}"
    )
  end

  # For successful streams, finalize_metrics is not used - result already has final_metrics
  defp finalize_metrics(%Metrics{} = metrics, :ok) do
    %{metrics | outcome: :ok}
  end

  defp finalize_metrics(%Metrics{} = metrics, {:error, {:model_load_failed, _reason}}) do
    %{metrics | outcome: :model_load_failed, terminal_kind: :none, terminal_source: :none}
  end

  defp finalize_metrics(%Metrics{} = metrics, {:error, {:dispatch_failed, _reason}}) do
    %{metrics | outcome: :dispatch_failed, terminal_kind: :none, terminal_source: :none}
  end

  defp finalize_metrics(%Metrics{} = metrics, {:error, _}) do
    %{metrics | outcome: :dispatch_failed, terminal_kind: :none, terminal_source: :none}
  end

  defp serialize_bool(true), do: "true"
  defp serialize_bool(false), do: "false"
  defp serialize_bool(:unknown), do: "unknown"

  defp serialize_na(:na), do: "na"
  defp serialize_na(value) when is_integer(value), do: Integer.to_string(value)
  defp serialize_na(value), do: inspect(value)
end
