defmodule Orchard.Dispatch.RequestDispatcher do
  @moduledoc """
  Orchestrates the dispatch of an inference request to a node-agent.

  Implements the M1 single-node dispatch flow:

    schedule → connect → ensure_model_loaded → execute_inference → stream events

  Monitors for:
  - Request timeout → sends CancelInference to the node
  - Caller process exit → sends CancelInference to the node
  """

  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: Client
  alias Orchard.InferenceEvent

  @type dispatch_result ::
          {:ok, [InferenceEvent.t()]}
          | {:error, :connect_failed | :model_load_failed | :dispatch_failed | term()}

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
  - `:event_handler` — function called with each `InferenceEvent`
                        (default: sends `{:inference_event, request_id, event}` to caller)

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

    case Client.connect(target) do
      {:ok, channel} ->
        try do
          case do_ensure_model_loaded(channel, model_load_request, model_load_timeout) do
            :ok ->
              do_execute_and_stream(
                channel,
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
          Client.disconnect(channel)
        end

      {:error, {:connect_failed, _} = reason} ->
        {:error, reason}
    end
  end

  # -- Private ---------------------------------------------------------------

  defp do_ensure_model_loaded(channel, request, timeout_ms) do
    case Client.ensure_model_loaded(channel, request, timeout: timeout_ms) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_execute_and_stream(
         channel,
         request,
         request_id,
         timeout_ms,
         caller,
         event_handler
       ) do
    caller_ref = Process.monitor(caller)
    timer_ref = start_timeout_timer(timeout_ms)

    {:ok, task_ref} = Client.execute_inference(channel, request, owner: self())

    result =
      receive_loop(
        channel,
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
         channel,
         request_id,
         task_ref,
         timer_ref,
         caller_ref,
         event_handler,
         events
       ) do
    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        emit_event(event, request_id, event_handler)
        events = [event | events]

        if InferenceEvent.terminal?(event) do
          {:ok, Enum.reverse(events)}
        else
          receive_loop(
            channel,
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
        if events == [] do
          {:error, {:dispatch_failed, reason}}
        else
          # Stream had prior events but ended with an error and no terminal
          # event. Synthesize a :failed event so callers always see a
          # terminal outcome rather than treating a truncated stream as
          # completed.
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
        _ = Client.cancel_inference(channel, request_id)
        drain_until_terminal_or_done(task_ref, request_id, event_handler, events, :timeout)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        _ = Client.cancel_inference(channel, request_id)

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

  defp emit_event(_event, _request_id, nil), do: :ok

  defp emit_event(event, request_id, handler) when is_function(handler, 2) do
    handler.(request_id, event)
  end

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
