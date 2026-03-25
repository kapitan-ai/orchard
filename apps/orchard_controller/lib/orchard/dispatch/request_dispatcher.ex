defmodule Orchard.Dispatch.RequestDispatcher do
  @moduledoc """
  Orchestrates the dispatch of an inference request to a node-agent.

  Implements the M1 single-node dispatch flow:

    schedule → connect → ensure_model_loaded → execute_inference → stream events

  Monitors for:
  - Request timeout → sends CancelInference to the node
  - Caller process exit → sends CancelInference to the node
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

          case do_ensure_model_loaded(
                 client,
                 channel,
                 target,
                 model_load_request,
                 model_load_timeout
               ) do
            :ok ->
              do_execute_and_stream(
                client,
                channel,
                target,
                execute_request,
                request_id,
                timeout_ms,
                caller,
                event_handler
              )

            {:error, reason} ->
              {:error, {:model_load_failed, reason}}
          end
        after
          client.disconnect(channel)
        end

      {:error, {:connect_failed, _reason} = reason} ->
        mark_transport_failure(target, reason)
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
    case Ecto.UUID.cast(node_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
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
            :ok

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
         request_id,
         timeout_ms,
         caller,
         event_handler
       ) do
    caller_ref = Process.monitor(caller)
    timer_ref = start_timeout_timer(timeout_ms)

    {:ok, task_ref} = client.execute_inference(channel, request, owner: self())

    result =
      receive_loop(
        client,
        channel,
        target,
        request_id,
        task_ref,
        timer_ref,
        caller_ref,
        event_handler,
        []
      )

    cleanup(timer_ref, caller_ref)
    result
  end

  defp receive_loop(
         client,
         channel,
         target,
         request_id,
         task_ref,
         timer_ref,
         caller_ref,
         event_handler,
         events
       ) do
    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        handler_result = emit_event(event, request_id, event_handler)
        events = [event | events]

        cond do
          InferenceEvent.terminal?(event) ->
            {:ok, Enum.reverse(events)}

          cancelled_by_handler?(handler_result) ->
            _ = client.cancel_inference(channel, request_id)

            drain_until_terminal_or_done(
              task_ref,
              request_id,
              event_handler,
              events,
              :client_disconnect
            )

          true ->
            receive_loop(
              client,
              channel,
              target,
              request_id,
              task_ref,
              timer_ref,
              caller_ref,
              event_handler,
              events
            )
        end

      {:dispatch_done, ^task_ref, :ok} ->
        {:ok, Enum.reverse(events)}

      {:dispatch_done, ^task_ref, {:error, reason}} ->
        mark_transport_failure(target, reason)

        if events == [] do
          {:error, {:dispatch_failed, reason}}
        else
          has_terminal? = Enum.any?(events, &InferenceEvent.terminal?/1)

          if has_terminal? do
            {:ok, Enum.reverse(events)}
          else
            failed_event =
              InferenceEvent.failed(
                "stream_error",
                "stream ended with error: #{inspect(reason)}",
                false
              )

            emit_event(failed_event, request_id, event_handler)
            {:ok, Enum.reverse([failed_event | events])}
          end
        end

      {:dispatch_timeout, ^timer_ref} ->
        _ = client.cancel_inference(channel, request_id)
        drain_until_terminal_or_done(task_ref, request_id, event_handler, events, :timeout)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        _ = client.cancel_inference(channel, request_id)

        drain_until_terminal_or_done(
          task_ref,
          request_id,
          event_handler,
          events,
          :caller_disconnect
        )
    end
  end

  # After sending cancel (due to timeout or disconnect), drain remaining events
  # until we get a terminal event or the stream completes.
  defp drain_until_terminal_or_done(task_ref, request_id, event_handler, events, cancel_reason) do
    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        emit_event(event, request_id, event_handler)
        events = [event | events]

        if InferenceEvent.terminal?(event) do
          {:ok, Enum.reverse(events)}
        else
          drain_until_terminal_or_done(task_ref, request_id, event_handler, events, cancel_reason)
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
        {:ok, Enum.reverse([timeout_event | events])}
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
        {:ok, Enum.reverse([timeout_event | events])}
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
end
