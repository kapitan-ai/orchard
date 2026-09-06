defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.Client do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation
  alias Orchard.TestSupport.DispatchCapacityFixtures

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)
  def clear, do: :persistent_term.erase({__MODULE__, :test_pid})

  def connect(_target), do: {:ok, :capacity_test_channel}
  def disconnect(_channel), do: :ok
  def status(_channel, _opts \\ []), do: {:ok, DispatchCapacityFixtures.probe_status_response()}

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts \\ []) do
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    send(test_pid, {:model_load_started, self()})

    receive do
      :continue_model_load ->
        {:ok,
         %Operation.EnsureModelLoadedResult{
           already_loaded: false,
           placement_state: :loaded,
           worker_supports_prompt_token_ids: true
         }}
    end
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
        )

        send(test_pid, {:node_accepted, self()})

        receive do
          :finish ->
            send(
              owner,
              {:runtime_endpoint_event, task_ref, request.request_id,
               InferenceEvent.completed(:finish_reason_stop, nil)}
            )

            send(owner, {:runtime_endpoint_done, task_ref, :ok})
        end
      end)

    send(test_pid, {:stream_emitter, emitter})
    {:ok, task_ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation
  alias Orchard.TestSupport.DispatchCapacityFixtures

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)
  def clear, do: :persistent_term.erase({__MODULE__, :test_pid})

  def connect(_target), do: {:ok, :capacity_gate_channel}
  def disconnect(_channel), do: :ok
  def status(_channel, _opts \\ []), do: {:ok, DispatchCapacityFixtures.probe_status_response()}

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts \\ []) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :model_loaded)

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()
    send(test_pid, :execute_called)

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
    )

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id,
       InferenceEvent.completed(:finish_reason_stop, nil)}
    )

    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.SlowLoadClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.RuntimeEndpoint.Operation

  @load_duration_ms 200

  def load_duration_ms, do: @load_duration_ms

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate execute_inference(channel, request, opts), to: GateClient
  defdelegate cancel_inference(channel, request, opts), to: GateClient

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts) do
    Process.sleep(@load_duration_ms)

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.TimedOutLoadClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.RuntimeEndpoint.Operation

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate execute_inference(channel, request, opts), to: GateClient
  defdelegate cancel_inference(channel, request, opts), to: GateClient

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, opts) do
    Process.sleep(Keyword.fetch!(opts, :timeout))
    {:error, :timeout}
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.ExecuteErrorClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, _request, _opts), do: {:error, :execution_refused}
  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.DoneBeforeAcceptedClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, _request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()
    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.TerminalBeforeAcceptedClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  def configure(event), do: :persistent_term.put({__MODULE__, :event}, event)
  def clear, do: :persistent_term.erase({__MODULE__, :event})

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()
    event = :persistent_term.get({__MODULE__, :event})
    send(owner, {:runtime_endpoint_event, task_ref, request.request_id, event})
    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.NonterminalThenErrorClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id,
       InferenceEvent.output_text_delta("before acceptance")}
    )

    send(owner, {:runtime_endpoint_done, task_ref, {:error, :stream_failed}})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.TerminalDefectClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()

    request.request_id
    |> events_for()
    |> Enum.each(fn event ->
      send(owner, {:runtime_endpoint_event, task_ref, request.request_id, event})
    end)

    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient

  defp events_for("request-terminal-defect-missing"), do: [InferenceEvent.accepted(0)]

  defp events_for("request-terminal-defect-duplicate") do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.completed(:finish_reason_stop, nil),
      InferenceEvent.failed("late_terminal", "late terminal", false)
    ]
  end

  defp events_for("request-terminal-defect-post") do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.completed(:finish_reason_stop, nil),
      InferenceEvent.output_text_delta("late")
    ]
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.CancellableStreamClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)

  def clear do
    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :emitter})
  end

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
        )

        if request.request_id == "request-accepted-handler-cancel" do
          send(
            owner,
            {:runtime_endpoint_event, task_ref, request.request_id,
             InferenceEvent.output_text_delta("")}
          )

          send(
            owner,
            {:runtime_endpoint_event, task_ref, request.request_id,
             InferenceEvent.tool_call_delta("call-before-text", "{}")}
          )

          send(test_pid, {:pre_text_events_sent, self()})
          receive do: (:emit_first_text -> :ok)
        end

        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id,
           InferenceEvent.output_text_delta("streaming")}
        )

        receive do
          :cancel ->
            send(test_pid, {:cancel_received, self()})

            receive do
              :finish_cancel ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                if request.request_id in [
                     "request-cancel-post-terminal",
                     "request-cancel-post-terminal-timeout",
                     "request-handler-failure-post-terminal"
                   ] do
                  send(
                    owner,
                    {:runtime_endpoint_event, task_ref, request.request_id,
                     InferenceEvent.output_text_delta("late after cancellation terminal")}
                  )
                end

                unless request.request_id == "request-cancel-post-terminal-timeout" do
                  send(owner, {:runtime_endpoint_done, task_ref, :ok})
                end
            end
        end
      end)

    :persistent_term.put({__MODULE__, :emitter}, emitter)
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts) do
    send(:persistent_term.get({__MODULE__, :emitter}), :cancel)
    :ok
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.UnprobeableClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient
  defdelegate execute_inference(channel, request, opts), to: GateClient
  defdelegate cancel_inference(channel, request, opts), to: GateClient

  def status(_channel, _opts \\ []), do: {:error, :node_timeout}
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.PreAcceptanceCancelClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  def configure(test_pid, opts \\ []) do
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)
    :persistent_term.put({__MODULE__, :cancel_failure}, Keyword.get(opts, :cancel_failure))

    :persistent_term.put(
      {__MODULE__, :disconnect_failure},
      Keyword.get(opts, :disconnect_failure)
    )

    :persistent_term.put({__MODULE__, :probe_ready?}, Keyword.get(opts, :probe_ready?, true))

    :persistent_term.put(
      {__MODULE__, :disconnect_results},
      Keyword.get(opts, :disconnect_results, [])
    )
  end

  def clear do
    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :emitter})
    :persistent_term.erase({__MODULE__, :cancel_failure})
    :persistent_term.erase({__MODULE__, :disconnect_failure})
    :persistent_term.erase({__MODULE__, :probe_ready?})
    :persistent_term.erase({__MODULE__, :disconnect_results})
  end

  defdelegate connect(target), to: GateClient

  def disconnect(channel) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :pre_acceptance_disconnected)

    case :persistent_term.get({__MODULE__, :disconnect_results}, []) do
      [result | remaining] ->
        :persistent_term.put({__MODULE__, :disconnect_results}, remaining)
        result

      [] ->
        case :persistent_term.get({__MODULE__, :disconnect_failure}, nil) do
          nil -> GateClient.disconnect(channel)
          failure -> {:error, failure}
        end
    end
  end

  def status(channel, opts) do
    {:ok, response} = GateClient.status(channel, opts)
    ready? = :persistent_term.get({__MODULE__, :probe_ready?}, true)
    {:ok, %{response | runtime_health: %{ready: ready?}}}
  end

  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id,
           InferenceEvent.output_text_delta("before acceptance")}
        )

        send(test_pid, :pre_acceptance_stream_started)

        receive do
          :cancel ->
            send(test_pid, {:pre_acceptance_cancel_received, self()})

            receive do
              :finish_cancel ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                send(owner, {:runtime_endpoint_done, task_ref, :ok})

              :finish_cancel_after_acceptance ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.accepted(0)}
                )

                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                send(owner, {:runtime_endpoint_done, task_ref, :ok})

              :finish_cancel_with_output ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.output_text_delta("drained output")}
                )

                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                send(owner, {:runtime_endpoint_done, task_ref, :ok})
            end
        end
      end)

    :persistent_term.put({__MODULE__, :emitter}, emitter)
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts) do
    send(:persistent_term.get({__MODULE__, :emitter}), :cancel)

    case :persistent_term.get({__MODULE__, :cancel_failure}) do
      nil -> :ok
      :raise -> raise "cancel failed"
      :exit -> exit(:cancel_failed)
    end
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.NoisyCancelClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)

  def clear do
    case :persistent_term.get({__MODULE__, :emitter}, nil) do
      emitter when is_pid(emitter) -> send(emitter, :disconnect)
      _missing -> :ok
    end

    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :emitter})
  end

  defdelegate connect(target), to: GateClient

  def disconnect(channel) do
    case :persistent_term.get({__MODULE__, :emitter}, nil) do
      emitter when is_pid(emitter) -> send(emitter, :disconnect)
      _missing -> :ok
    end

    send(:persistent_term.get({__MODULE__, :test_pid}), :noisy_cancel_disconnected)
    GateClient.disconnect(channel)
  end

  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id,
           InferenceEvent.output_text_delta("before acceptance")}
        )

        receive do
          :cancel ->
            send(test_pid, :noisy_cancel_received)
            emit_until_disconnected(owner, task_ref, request.request_id)
        end
      end)

    :persistent_term.put({__MODULE__, :emitter}, emitter)
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts) do
    send(:persistent_term.get({__MODULE__, :emitter}), :cancel)
    :ok
  end

  defp emit_until_disconnected(owner, task_ref, request_id) do
    receive do
      :disconnect ->
        :ok
    after
      1 ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request_id,
           InferenceEvent.output_text_delta("still cancelling")}
        )

        emit_until_disconnected(owner, task_ref, request_id)
    end
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.ProductionFreshStatusClient do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  def configure(test_pid, initial_status, post_load_status) do
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)
    :persistent_term.put({__MODULE__, :status}, initial_status)
    :persistent_term.put({__MODULE__, :post_load_status}, post_load_status)
  end

  def clear do
    for key <- [:test_pid, :status, :post_load_status] do
      :persistent_term.erase({__MODULE__, key})
    end
  end

  def connect(target), do: {:ok, target}
  def disconnect(_channel), do: :ok

  def status(target, _opts) do
    status = :persistent_term.get({__MODULE__, :status})
    metadata = Map.fetch!(status, :node_metadata)
    observed_at = DateTime.utc_now()

    {:ok, _evidence} =
      Orchard.DispatchCapacity.record_capacity_evidence(metadata.node_id, %{
        active_request_count: Map.fetch!(status, :active_request_count),
        observed_at: observed_at,
        runtime_concurrency_limit: Map.fetch!(status, :max_concurrency),
        validity: :valid
      })

    {:ok, _node} = Orchard.Nodes.observe_status(target, status, observed_at)

    {:ok, status}
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts) do
    :persistent_term.put(
      {__MODULE__, :status},
      :persistent_term.get({__MODULE__, :post_load_status})
    )

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, request, opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :production_execute_called)
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()

    send(owner, {
      :runtime_endpoint_event,
      task_ref,
      request.request_id,
      InferenceEvent.accepted(0)
    })

    send(owner, {
      :runtime_endpoint_event,
      task_ref,
      request.request_id,
      InferenceEvent.completed(:finish_reason_stop, nil)
    })

    send(owner, {:runtime_endpoint_done, task_ref, :ok})

    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.MonitorSnapshotClient do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)
  def clear, do: :persistent_term.erase({__MODULE__, :test_pid})

  def connect(target), do: {:ok, target}
  def disconnect(_channel), do: :ok

  def status(_channel, _opts \\ []) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :monitor_snapshot_status_called)
    raise "monitor-snapshot dispatch must not call status"
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts \\ []) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :monitor_snapshot_model_loaded)

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, request, opts) do
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    send(test_pid, :monitor_snapshot_execute_called)
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
    )

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id,
       InferenceEvent.completed(:finish_reason_stop, nil)}
    )

    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.CompatibilitySingleWaveClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.RuntimeEndpoint.Operation

  def configure(test_pid, response, load_result) do
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)
    :persistent_term.put({__MODULE__, :response}, response)
    :persistent_term.put({__MODULE__, :load_result}, load_result)
  end

  def clear do
    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :response})
    :persistent_term.erase({__MODULE__, :load_result})
  end

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient

  def status(_channel, _opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :compatibility_status_called)
    {:ok, :persistent_term.get({__MODULE__, :response})}
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :model_loaded)
    {:ok, :persistent_term.get({__MODULE__, :load_result})}
  end

  defdelegate execute_inference(channel, request, opts), to: GateClient
  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.RaisingAfterConnectClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.RuntimeEndpoint.Operation

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)

  def configure_handler(handler),
    do: :persistent_term.put({__MODULE__, :raising_handler}, handler)

  def clear do
    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :raising_handler})
  end

  defdelegate connect(target), to: GateClient
  defdelegate status(channel, opts), to: GateClient

  def disconnect(_channel) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :raising_path_disconnected)
    {:ok, :disconnected}
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts) do
    handler = :persistent_term.get({__MODULE__, :raising_handler})
    handler.("request-raising-handler-cleanup", Orchard.InferenceEvent.accepted(0))
  end

  defdelegate execute_inference(channel, request, opts), to: GateClient
  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.CircuitBreakers
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.{AttemptOutcome, RequestDispatcher}
  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Inference
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent
  alias Orchard.Models.Model
  alias Orchard.NodeHeartbeats.CandidateSnapshot
  alias Orchard.NodeHeartbeats.CandidateSnapshot.Candidate
  alias Orchard.Nodes.{AdmissionDecision, Node}
  alias Orchard.RuntimeEndpoint.{Operation, Placement, PlacementCapacity, Target}
  alias Orchard.Scheduler.{MultiNode, SingleNode}
  alias Orchard.TestSupport.DispatchCapacityFixtures

  alias __MODULE__.{
    CancellableStreamClient,
    Client,
    CompatibilitySingleWaveClient,
    DoneBeforeAcceptedClient,
    ExecuteErrorClient,
    GateClient,
    MonitorSnapshotClient,
    NoisyCancelClient,
    NonterminalThenErrorClient,
    PreAcceptanceCancelClient,
    RaisingAfterConnectClient,
    ProductionFreshStatusClient,
    SlowLoadClient,
    TimedOutLoadClient,
    TerminalDefectClient,
    TerminalBeforeAcceptedClient,
    UnprobeableClient
  }

  @client Client
  @compatibility_single_wave_client CompatibilitySingleWaveClient
  @gate_client GateClient
  @execute_error_client ExecuteErrorClient
  @done_before_accepted_client DoneBeforeAcceptedClient
  @terminal_before_accepted_client TerminalBeforeAcceptedClient
  @nonterminal_then_error_client NonterminalThenErrorClient
  @cancellable_stream_client CancellableStreamClient
  @raising_after_connect_client RaisingAfterConnectClient
  @monitor_snapshot_client MonitorSnapshotClient
  @noisy_cancel_client NoisyCancelClient
  @pre_acceptance_cancel_client PreAcceptanceCancelClient
  @unprobeable_client UnprobeableClient
  @production_fresh_status_client ProductionFreshStatusClient
  @slow_load_client SlowLoadClient
  @timed_out_load_client TimedOutLoadClient
  @terminal_defect_client TerminalDefectClient

  # The request timeout now bounds connect, probe, and acceptance-gate waiting
  # as well as streaming, so it must outlast dispatch setup or the request
  # expires as `:dispatch_timeout` before the stream-phase cancellation path
  # under test can run.
  @expiring_request_timeout_ms 250

  setup do
    insert_canonical_model!()

    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    @client.configure(self())
    @gate_client.configure(self())
    @cancellable_stream_client.configure(self())
    @monitor_snapshot_client.configure(self())
    @noisy_cancel_client.configure(self())
    @pre_acceptance_cancel_client.configure(self())
    @raising_after_connect_client.configure(self())

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      @client.clear()
      @compatibility_single_wave_client.clear()
      @gate_client.clear()
      @terminal_before_accepted_client.clear()
      @cancellable_stream_client.clear()
      @monitor_snapshot_client.clear()
      @noisy_cancel_client.clear()
      @pre_acceptance_cancel_client.clear()
      @raising_after_connect_client.clear()
      @production_fresh_status_client.clear()
      DispatchCapacityFixtures.clear_probe_node_id()
    end)

    :ok
  end

  test "SPEC 5.9 dispatch retains one claim through loading, acceptance, and completion" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    input = enforcing_input()
    request_id = "request-claim-lifetime"

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      timeout_at: DateTime.add(DateTime.utc_now(), 5_000, :millisecond),
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end,
      dispatch_capacity_authority: authority
    }

    dispatch_task =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @client
        )
      end)

    assert_receive {:model_load_started, dispatcher_pid}
    assert AllocationAuthority.claim_count(authority, node_id) == 1

    assert {:error, :dispatch_capacity_unavailable, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "competitor-during-load",
               input,
               authority: authority
             )

    send(dispatcher_pid, :continue_model_load)
    assert_receive {:stream_emitter, emitter}
    assert_receive {:node_accepted, ^emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1

    send(emitter, :finish)
    assert %AttemptOutcome{} = outcome = Task.await(dispatch_task)
    assert outcome.attempt_outcome == :completed
    assert outcome.node_id == node_id
    assert outcome.accepted
    assert Enum.map(outcome.events, &InferenceEvent.kind/1) == [:accepted, :completed]
    assert outcome.failure == nil
    assert outcome.execution_resolution == :terminated
    assert outcome.capacity_release_outcome == :released
    assert DateTime.compare(outcome.ended_at, outcome.started_at) in [:eq, :gt]
    assert outcome.first_token_at == nil
    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, final_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-completion",
               input,
               authority: authority
             )

    assert :released = QueueManager.release_dispatch_capacity(final_claim, authority: authority)
  end

  test "SPEC 4.6.2 same-Request held claim fails closed without releasing the owner" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-held-claim"

    assert {:ok, held_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               request_id,
               enforcing_input(),
               authority: authority
             )

    assert %AttemptOutcome{
             attempt_outcome: :failed,
             node_id: ^node_id,
             accepted: false,
             execution_resolution: :not_started,
             capacity_release_outcome: :not_applicable,
             failure: %{"failure_class" => "occupancy_unresolved"}
           } =
             dispatch_with_deadline(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @client
             )

    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert :released = QueueManager.release_dispatch_capacity(held_claim, authority: authority)
  end

  test "SPEC 4.6.2 authority loss while a claim is held is unresolved" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-authority-loss"

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @client
        )
      end)

    assert_receive {:model_load_started, dispatcher_pid}
    Process.unlink(authority)
    Process.exit(authority, :kill)
    send(dispatcher_pid, :continue_model_load)

    assert %AttemptOutcome{
             attempt_outcome: :failed,
             node_id: ^node_id,
             capacity_release_outcome: :unresolved
           } = Task.await(dispatch)
  end

  test "SPEC 4.6.2 dispatch owner death releases its claim exactly once" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-owner-death"
    input = enforcing_input()

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      timeout_at: DateTime.add(DateTime.utc_now(), 5_000, :millisecond),
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end,
      dispatch_capacity_authority: authority
    }

    {dispatcher_pid, monitor_ref} =
      spawn_monitor(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @client
        )
      end)

    assert_receive {:model_load_started, ^dispatcher_pid}
    assert AllocationAuthority.claim_count(authority, node_id) == 1

    Process.exit(dispatcher_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^dispatcher_pid, :killed}
    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-owner-death",
               enforcing_input(),
               authority: authority
             )

    assert :released = QueueManager.release_dispatch_capacity(claim, authority: authority)
    assert :already_released = QueueManager.release_dispatch_capacity(claim, authority: authority)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 policy mutation linearizes before final dispatch revalidation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-final-revalidation"
    parent = self()
    input_state = start_supervised!({Agent, fn -> enforcing_input() end})

    mutation =
      Task.async(fn ->
        Orchard.DispatchCapacity.with_policy_mutation_gate(
          node_id,
          fn ->
            send(parent, {:mutation_gate_held, self()})

            receive do
              :commit_mutation ->
                Agent.update(input_state, fn input ->
                  %{input | controller_dispatch_ceiling: {:valid, 0}}
                end)
            end
          end,
          authority: authority
        )
      end)

    assert_receive {:mutation_gate_held, mutation_pid}

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      timeout_at: DateTime.add(DateTime.utc_now(), 5_000, :millisecond),
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: enforcing_input(),
      dispatch_capacity_acquisition_input_provider: fn -> Agent.get(input_state, & &1) end,
      dispatch_capacity_input_provider: fn -> Agent.get(input_state, & &1) end,
      dispatch_capacity_authority: authority
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @gate_client
        )
      end)

    assert_receive :model_loaded
    send(mutation_pid, :commit_mutation)
    assert :ok = Task.await(mutation)

    assert_dispatch_failure(Task.await(dispatch), :dispatch_capacity_revalidation_failed)

    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "disconnect cleanup runs when dispatch raises with a raising event handler configured" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-raising-handler-cleanup"

    raising_handler = fn _request_id, _event -> raise "handler failed" end
    @raising_after_connect_client.configure_handler(raising_handler)

    assert_raise RuntimeError, "handler failed", fn ->
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @raising_after_connect_client,
        event_handler: raising_handler
      )
    end

    assert_receive :raising_path_disconnected
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 synchronous execute failure releases the claim for retry" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-execute-error"

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @execute_error_client
      ),
      :execution_refused
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-retry",
               enforcing_input(),
               authority: authority
             )

    assert :released = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end

  test "SPEC 4.6 runtime completion before Accepted is a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-missing-acceptance"

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @done_before_accepted_client
      ),
      :node_acceptance_missing
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 7.5.5 terminal defects release claim and acceptance gate resources" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    for defect <- ["missing", "duplicate", "post"] do
      node_id = claim_node_id()
      request_id = "request-terminal-defect-#{defect}"

      outcome =
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @terminal_defect_client
        )

      events = assert_dispatch_success(outcome)

      assert [%InferenceEvent{event: %InferenceEvent.Failed{}}] =
               Enum.filter(events, &InferenceEvent.terminal?/1)

      assert outcome.failure["failure_class"] == "terminal_conformance"
      assert outcome.failure["failure_code"] == "orchestration_error"

      assert AllocationAuthority.claim_count(authority, node_id) == 0
      assert {:ok, lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)
      assert :ok = QueueManager.release_acceptance_gate(lease, authority: authority)
    end
  end

  test "SPEC 5.9 managed dispatch rejects cached capacity without fresh providers" do
    node_id = claim_node_id()
    request_id = "request-cached-capacity-authorization"

    schedule =
      capacity_schedule(
        start_supervised!({AllocationAuthority, name: nil}),
        node_id,
        request_id
      )
      |> Map.drop([
        :dispatch_capacity_acquisition_input_provider,
        :dispatch_capacity_input_provider
      ])

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :dispatch_capacity_facts_unavailable
    )

    refute_receive :execute_called
  end

  test "SPEC 5.9 initial claim acquisition reloads current capacity facts" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-fresh-acquisition-capacity"

    unavailable_input = %{
      enforcing_input()
      | controller_dispatch_ceiling: {:valid, 0}
    }

    schedule =
      authority
      |> capacity_schedule(node_id, request_id)
      |> Map.put(:dispatch_capacity_acquisition_input_provider, fn -> unavailable_input end)

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :dispatch_capacity_unavailable
    )

    refute_receive :model_loaded
    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 unmanaged dispatch revalidates fresh post-load placement capacity" do
    request_id = "request-unmanaged-post-load-revalidation"
    input = unmanaged_input()
    unavailable_input = %{input | placement_capacity: :unknown}

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> unavailable_input end,
      dispatch_capacity_evaluation: Evaluator.evaluate(input)
    }

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(Ecto.UUID.generate()),
        client_impl: @gate_client
      ),
      :dispatch_capacity_revalidation_failed
    )

    assert_receive :model_loaded
    refute_receive :execute_called
  end

  test "SPEC.md §12.4 logical deadline wins when model loading times out at the Request boundary" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-model-load-deadline"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: 50,
        timeout_at: DateTime.add(DateTime.utc_now(), 50, :millisecond),
        model_load_timeout_ms: 5_000
    }

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @timed_out_load_client
      ),
      :request_timeout
    )

    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC.md §12.4 expiry during capacity revalidation prevents ExecuteInference" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-post-load-revalidation-deadline"
    input = enforcing_input()

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: 50,
        timeout_at: DateTime.add(DateTime.utc_now(), 50, :millisecond),
        dispatch_capacity_input_provider: fn ->
          Process.sleep(75)
          input
        end
    }

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :request_timeout
    )

    assert_receive :model_loaded
    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC.md §12.4 a cold model load consumes the original Request budget" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cold-load-budget"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: div(@slow_load_client.load_duration_ms(), 2),
        timeout_at:
          DateTime.add(
            DateTime.utc_now(),
            div(@slow_load_client.load_duration_ms(), 2),
            :millisecond
          ),
        model_load_timeout_ms: 5_000
    }

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @slow_load_client
      ),
      :request_timeout
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 Completed before Accepted is a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-completed-before-accepted"

    @terminal_before_accepted_client.configure(
      Orchard.InferenceEvent.completed(:finish_reason_stop, nil)
    )

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @terminal_before_accepted_client
      ),
      :node_acceptance_missing
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 Failed before Accepted is a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-failed-before-accepted"

    @terminal_before_accepted_client.configure(
      Orchard.InferenceEvent.failed("runtime_failed", "runtime failed before acceptance", false)
    )

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @terminal_before_accepted_client
      ),
      :node_acceptance_missing
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 stream error after a pre-Accepted delta fails with the transport reason" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-delta-before-acceptance-error"

    test_pid = self()

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @nonterminal_then_error_client,
        event_handler: fn _request_id, event ->
          send(test_pid, {:pre_accepted_public_event, event})
          :ok
        end
      ),
      :stream_failed
    )

    refute_receive {:pre_accepted_public_event, _event}
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 Accepted handler exception retains the claim through cancellation terminal" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-accepted-handler-exception"

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.Accepted{}} ->
              raise "accepted handler failed"

            _request_id, _event ->
              :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    assert_dispatch_failure(Task.await(dispatch), :orchestration_error)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 delta handler exception retains the claim through cancellation terminal" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-delta-handler-exception"

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.OutputTextDelta{}} ->
              raise "delta handler failed"

            _request_id, _event ->
              :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    assert_dispatch_failure(Task.await(dispatch), :orchestration_error)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 accepted handler cancellation records explicit cancellation evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-accepted-handler-cancel"

    test_pid = self()

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.OutputTextDelta{delta: delta}}
            when delta != "" ->
              send(test_pid, {:first_text_handler_entered, DateTime.utc_now()})
              :cancel

            _request_id, _event ->
              :ok
          end
        )
      end)

    assert_receive {:pre_text_events_sent, emitter}
    observed_before_first_text_at = DateTime.utc_now()
    send(emitter, :emit_first_text)
    assert_receive {:first_text_handler_entered, observed_after_first_text_at}
    assert_receive {:cancel_received, ^emitter}
    send(emitter, :finish_cancel)

    assert %AttemptOutcome{
             attempt_outcome: :cancelled,
             accepted: true,
             failure: %{
               "failure_class" => "cancellation",
               "failure_code" => "request_caller_disconnect"
             },
             execution_resolution: :terminated,
             capacity_release_outcome: :released
           } = outcome = Task.await(dispatch)

    assert DateTime.compare(outcome.first_token_at, observed_before_first_text_at) in [:gt, :eq]
    assert DateTime.compare(outcome.first_token_at, observed_after_first_text_at) in [:lt, :eq]
    assert DateTime.compare(outcome.ended_at, observed_after_first_text_at) in [:gt, :eq]
  end

  test "SPEC 7.5.5 cancellation drain detects an event after terminal" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cancel-post-terminal"

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.OutputTextDelta{}} -> :cancel
            _request_id, _event -> :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    events = assert_dispatch_success(Task.await(dispatch))

    assert [%InferenceEvent{event: %InferenceEvent.Failed{code: code}}] =
             Enum.filter(events, &InferenceEvent.terminal?/1)

    assert code == "runtime_endpoint_post_terminal_event"

    refute Enum.any?(
             events,
             &(InferenceEvent.kind(&1) == :output_text_delta and &1.event.delta =~ "late")
           )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 7.5.5 cancellation drain timeout preserves an observed post-terminal defect" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cancel-post-terminal-timeout"

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          cancel_drain_timeout_ms: 20,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.OutputTextDelta{}} -> :cancel
            _request_id, _event -> :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    events = assert_dispatch_success(Task.await(dispatch))

    assert [%InferenceEvent{event: %InferenceEvent.Failed{code: code}}] =
             Enum.filter(events, &InferenceEvent.terminal?/1)

    assert code == "runtime_endpoint_post_terminal_event"
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 7.5.5 handler failure preserves a post-terminal defect observed while draining" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-handler-failure-post-terminal"

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.OutputTextDelta{}} ->
              raise "delta handler failed"

            _request_id, _event ->
              :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    events = assert_dispatch_success(Task.await(dispatch))

    assert [%InferenceEvent{event: %InferenceEvent.Failed{code: code}}] =
             Enum.filter(events, &InferenceEvent.terminal?/1)

    assert code == "runtime_endpoint_post_terminal_event"
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 timeout before Accepted remains a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-timeout-before-accepted"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, emitter}, 5_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel_after_acceptance)

    assert %AttemptOutcome{
             attempt_outcome: :timed_out,
             node_id: ^node_id,
             accepted: false,
             execution_resolution: :terminated,
             capacity_release_outcome: :released
           } = Task.await(dispatch)

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 output drained after pre-acceptance cancel is never delivered publicly" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-drain-output-before-accepted"
    test_pid = self()

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          event_handler: fn _request_id, event ->
            send(test_pid, {:drained_public_event, event})
            :ok
          end
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
    send(emitter, :finish_cancel_with_output)

    assert %AttemptOutcome{
             attempt_outcome: :timed_out,
             accepted: false,
             output_committed: false,
             output_commitment_kind: nil,
             delivery_state: :pending,
             delivered_event_count: 0
           } = Task.await(dispatch)

    refute_receive {:drained_public_event, _event}
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 raising handler is not invoked before Accepted" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-handler-failure-before-acceptance"

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @nonterminal_then_error_client,
        event_handler: fn _request_id, _event -> raise "handler failed before acceptance" end
      ),
      :stream_failed
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  for cancel_failure <- [:raise, :exit] do
    test "SPEC 4.5 cancel #{cancel_failure} still drains before releasing the claim" do
      @pre_acceptance_cancel_client.configure(self(), cancel_failure: unquote(cancel_failure))
      authority = start_supervised!({AllocationAuthority, name: nil})
      node_id = claim_node_id()
      request_id = "request-cancel-#{unquote(cancel_failure)}"

      schedule = %{
        capacity_schedule(authority, node_id, request_id)
        | request_timeout_ms: @expiring_request_timeout_ms,
          timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
      }

      dispatch =
        Task.async(fn ->
          dispatch_with_deadline(
            schedule,
            execute_request(request_id),
            model_load_request(node_id),
            client_impl: @pre_acceptance_cancel_client
          )
        end)

      assert_receive {:pre_acceptance_cancel_received, emitter}, 5_000
      assert AllocationAuthority.claim_count(authority, node_id) == 1
      send(emitter, :finish_cancel)

      assert %AttemptOutcome{
               attempt_outcome: :timed_out,
               node_id: ^node_id,
               execution_resolution: :terminated,
               capacity_release_outcome: :released
             } = Task.await(dispatch)

      assert AllocationAuthority.claim_count(authority, node_id) == 0
    end
  end

  test "SPEC 4.5 a proven clean disconnect after cancel drain timeout does not quarantine" do
    @pre_acceptance_cancel_client.configure(self(),
      disconnect_results: [{:ok, :disconnected}, {:ok, :disconnected}]
    )

    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cancel-drain-timeout"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert_receive :pre_acceptance_disconnected, 1_000

    assert %AttemptOutcome{
             attempt_outcome: :timed_out,
             node_id: ^node_id,
             accepted: false,
             execution_resolution: :terminated,
             capacity_release_outcome: :released
           } = Task.await(dispatch)

    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, claim, available} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-cancel-timeout",
               enforcing_input(),
               authority: authority
             )

    assert available.eligible?
    refute :node_health_unhealthy in available.reason_codes
    assert :released = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end

  test "SPEC 4.5 an unproven disconnect after cancel drain timeout quarantines the Node" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cancel-drain-unproven-disconnect"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    assert_receive :pre_acceptance_disconnected, 1_000

    assert %AttemptOutcome{
             attempt_outcome: :timed_out,
             node_id: ^node_id,
             execution_resolution: :unresolved,
             capacity_release_outcome: :unresolved
           } = Task.await(dispatch)

    assert {:error, :dispatch_capacity_unavailable, quarantined} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-unproven-disconnect",
               enforcing_input(),
               authority: authority
             )

    assert :node_health_unhealthy in quarantined.reason_codes
  end

  test "SPEC 4.6.2 unavailable quarantine state keeps may-have-started release unresolved" do
    store = start_supervised!({Orchard.DispatchCapacity.QuarantineStore, name: nil})

    authority =
      start_supervised!(
        {AllocationAuthority, name: nil, quarantine_store: store},
        id: {:authority, make_ref()}
      )

    node_id = claim_node_id()
    request_id = "request-quarantine-unavailable"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    Process.exit(store, :kill)
    assert_receive :pre_acceptance_disconnected, 1_000

    assert %AttemptOutcome{
             attempt_outcome: :timed_out,
             node_id: ^node_id,
             execution_resolution: :unresolved,
             capacity_release_outcome: :unresolved
           } = Task.await(dispatch)
  end

  test "SPEC 4.6.2 defensive cleanup cannot upgrade ambiguous release evidence" do
    @pre_acceptance_cancel_client.configure(self(),
      disconnect_results: [{:error, :disconnect_failed}, {:ok, :disconnected}]
    )

    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cancel-drain-later-clean-disconnect"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    assert_receive :pre_acceptance_disconnected, 1_000
    refute_receive :pre_acceptance_disconnected, 50

    assert %AttemptOutcome{
             attempt_outcome: :timed_out,
             execution_resolution: :unresolved,
             capacity_release_outcome: :unresolved
           } = Task.await(dispatch)

    assert {:error, :dispatch_capacity_unavailable, quarantined} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-ambiguous-release",
               enforcing_input(),
               authority: authority
             )

    assert :node_health_unhealthy in quarantined.reason_codes
  end

  test "SPEC 4.5 a durable unhealthy transition reconciles a failed disconnect" do
    @pre_acceptance_cancel_client.configure(self(),
      disconnect_failure: :disconnect_failed,
      probe_ready?: false
    )

    authority = start_supervised!({AllocationAuthority, name: nil})
    target = Inference.runtime_client_target()
    heartbeat_at = DateTime.utc_now()
    node_id = claim_node_id()
    node = insert_admitted_node!(target, heartbeat_at, node_id)
    request_id = "request-cancel-drain-durable-unreachable"
    request_timeout_ms = 1_500

    schedule = %{
      capacity_schedule(authority, node.id, request_id)
      | request_timeout_ms: request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node.id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 5_000
    assert_receive :pre_acceptance_disconnected, 5_000
    assert_dispatch_failure(Task.await(dispatch), :request_timeout)
    assert Repo.get!(Node, node.id).health == :unhealthy

    assert {:ok, claim, available} =
             QueueManager.acquire_dispatch_capacity(
               node.id,
               "request-after-durable-cancel-reconciliation",
               enforcing_input(),
               authority: authority
             )

    assert available.eligible?
    refute :node_health_unhealthy in available.reason_codes
    assert :released = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end

  test "SPEC 4.5 cancellation drain deadline is not extended by nonterminal events" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-noisy-cancel-drain"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @noisy_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive :noisy_cancel_received, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert_receive :noisy_cancel_disconnected, 250

    assert_dispatch_failure(Task.await(dispatch), :request_timeout)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 no clean disconnect or matching durable health quarantines the claimed Node" do
    @pre_acceptance_cancel_client.configure(self(), disconnect_failure: :disconnect_failed)
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = Inference.runtime_client_target()
    inventory_node = insert_admitted_node!(target, DateTime.utc_now())
    claimed_node_id = claim_node_id()
    request_id = "request-mismatched-reconciliation-node"

    schedule = %{
      capacity_schedule(authority, claimed_node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms,
        timeout_at: DateTime.add(DateTime.utc_now(), @expiring_request_timeout_ms, :millisecond)
    }

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          schedule,
          execute_request(request_id),
          model_load_request(claimed_node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    assert_dispatch_failure(Task.await(dispatch), :request_timeout)
    assert Repo.get!(Node, inventory_node.id).health == :degraded

    assert {:error, :dispatch_capacity_unavailable, quarantined} =
             QueueManager.acquire_dispatch_capacity(
               claimed_node_id,
               "request-after-mismatched-reconciliation",
               enforcing_input(),
               authority: authority
             )

    assert :node_health_unhealthy in quarantined.reason_codes
  end

  test "SPEC 5.9 cancelling handler is not invoked before Accepted" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-handler-cancel-before-accepted"

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @nonterminal_then_error_client,
        event_handler: fn _request_id, _event -> :cancel end
      ),
      :stream_failed
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 caller death before Accepted remains a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-caller-death-before-accepted"
    caller = spawn(fn -> Process.sleep(:infinity) end)

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          caller: caller
        )
      end)

    assert_receive :pre_acceptance_stream_started, 1_000
    Process.exit(caller, :kill)
    assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel_after_acceptance)

    assert_dispatch_failure(Task.await(dispatch), :request_caller_disconnect)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 admitted SingleNode dispatch rejects missing post-load placement evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    now = DateTime.utc_now()
    node = insert_admitted_node!(target, now)
    initial_status = production_status(node, target, [])

    post_load_status =
      production_status(node, target, [%{model_id: "test/model", version: "v1"}])

    @production_fresh_status_client.configure(self(), initial_status, post_load_status)

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               target,
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority
             )

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(schedule.request_id),
        model_load_request(node.id),
        client_impl: @production_fresh_status_client
      ),
      :dispatch_capacity_revalidation_failed
    )

    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, node.id) == 0
  end

  test "SPEC 5.10 SingleNode acquisition applies placement suppression only when refreshed status requires load" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    now = DateTime.utc_now()
    node = insert_admitted_node!(target, now)
    model = Repo.get_by!(Model, model_id: "test/model", version: "v1")
    cold_status = production_status(node, target, [])

    @production_fresh_status_client.configure(self(), cold_status, cold_status)

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               target,
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority
             )

    open_placement_breaker!(node.id, model.id)

    loaded_status =
      node
      |> production_status(target, [%{model_id: "test/model", version: "v1"}])
      |> Map.put(:runtime_model_placements, [
        %{
          model_ref: %{model_id: "test/model", version: "v1"},
          active_request_count: 0,
          max_concurrency: 2
        }
      ])

    @production_fresh_status_client.configure(self(), loaded_status, loaded_status)
    loaded_input = schedule.dispatch_capacity_acquisition_input_provider.()
    assert loaded_input.breaker_eligible?

    @production_fresh_status_client.configure(self(), cold_status, cold_status)
    cold_input = schedule.dispatch_capacity_acquisition_input_provider.()
    refute cold_input.breaker_eligible?
  end

  test "SPEC 5.9 SingleNode target remap cannot move a queued claim to another Node" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    now = DateTime.utc_now()
    scheduled_node = insert_admitted_node!(target, now)

    remapped_target =
      target
      |> Keyword.put(:host, "127.0.0.2")
      |> Keyword.update!(:port, &(&1 + 1))

    remapped_node = insert_admitted_node!(remapped_target, now)
    resolver = start_supervised!({Agent, fn -> scheduled_node end})
    initial_status = production_status(scheduled_node, target, [])

    @production_fresh_status_client.configure(self(), initial_status, initial_status)

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               target,
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority,
               node_resolver: fn _target -> {:ok, Agent.get(resolver, & &1)} end
             )

    assert schedule.node_id == scheduled_node.id

    remapped_status = production_status(remapped_node, target, [])

    remapped_post_load_status =
      remapped_node
      |> production_status(target, [%{model_id: "test/model", version: "v1"}])
      |> Map.put(:runtime_model_placements, [
        %{
          model_ref: %{model_id: "test/model", version: "v1"},
          active_request_count: 0,
          max_concurrency: 2
        }
      ])

    scheduled_node
    |> Ecto.Changeset.change(
      advertise_addr: "127.0.0.3",
      rpc_port: Keyword.fetch!(target, :port) + 2,
      connect_host: "127.0.0.3",
      connect_port: Keyword.fetch!(target, :port) + 2
    )
    |> Repo.update!()

    remapped_node
    |> Ecto.Changeset.change(
      advertise_addr: Keyword.fetch!(target, :host),
      rpc_port: Keyword.fetch!(target, :port),
      connect_host: Keyword.fetch!(target, :host),
      connect_port: Keyword.fetch!(target, :port)
    )
    |> Repo.update!()

    assert {:ok, %Node{id: remapped_node_id}} = Orchard.Nodes.lookup_by_target_result(target)
    assert remapped_node_id == remapped_node.id

    Agent.update(resolver, fn _scheduled_node -> remapped_node end)

    @production_fresh_status_client.configure(
      self(),
      remapped_status,
      remapped_post_load_status
    )

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(schedule.request_id),
        model_load_request(scheduled_node.id),
        client_impl: @production_fresh_status_client
      ),
      :dispatch_capacity_facts_unavailable
    )

    refute_receive :model_loaded
    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, scheduled_node.id) == 0
    assert AllocationAuthority.claim_count(authority, remapped_node.id) == 0
  end

  test "ADR 0017 monitor-snapshot dispatch executes from newer eligible facts with no status call" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    {schedule, node, snapshot_reads} =
      monitor_snapshot_schedule(authority, :eligible)

    assert schedule.dispatch_identity_source == :trusted_monitor_snapshot
    assert schedule.node_id == schedule.runtime_endpoint_target.node_id

    _events =
      assert_dispatch_success(
        dispatch_with_deadline(
          schedule,
          execute_request(schedule.request_id),
          model_load_request(node.id),
          client_impl: @monitor_snapshot_client
        )
      )

    assert_receive :monitor_snapshot_model_loaded
    assert_receive :monitor_snapshot_execute_called
    refute_receive :monitor_snapshot_status_called
    assert Agent.get(snapshot_reads, & &1) == 3
    assert AllocationAuthority.claim_count(authority, node.id) == 0
    assert_acceptance_gate_available(authority, node.id)
  end

  for management_class <- [
        :unmanaged_compatibility,
        :unmanaged_source_development
      ] do
    test "SPEC 5.5 #{management_class} dispatch performs one status attempt through completion" do
      authority = start_supervised!({AllocationAuthority, name: nil})

      {schedule, node_id} =
        compatibility_single_wave_schedule(authority, unquote(management_class))

      assert %AttemptOutcome{
               attempt_outcome: :completed,
               node_id: ^node_id,
               capacity_release_outcome: :not_applicable
             } =
               dispatch_with_deadline(
                 schedule,
                 execute_request(schedule.request_id),
                 model_load_request(node_id),
                 client_impl: @compatibility_single_wave_client
               )

      assert_receive :compatibility_status_called
      refute_receive :compatibility_status_called
      assert_receive :model_loaded
      assert_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
      assert_acceptance_gate_available(authority, node_id)
    end

    for evidence_scenario <- [:absent, :invalid, :mismatched] do
      test "SPEC 5.5 cold #{management_class} #{evidence_scenario} load evidence fails closed without reprobe" do
        authority = start_supervised!({AllocationAuthority, name: nil})

        load_result = compatibility_load_result(unquote(evidence_scenario))

        {schedule, node_id} =
          compatibility_single_wave_schedule(
            authority,
            unquote(management_class),
            load_result
          )

        assert_dispatch_failure(
          dispatch_with_deadline(
            schedule,
            execute_request(schedule.request_id),
            model_load_request(node_id),
            client_impl: @compatibility_single_wave_client
          ),
          :dispatch_capacity_revalidation_failed
        )

        assert_receive :compatibility_status_called
        refute_receive :compatibility_status_called
        assert_receive :model_loaded
        refute_receive :execute_called
        assert AllocationAuthority.claim_count(authority, node_id) == 0
        assert_acceptance_gate_available(authority, node_id)
      end
    end

    test "SPEC 5.9 cold #{management_class} old BEAM load result without evidence state fails closed" do
      authority = start_supervised!({AllocationAuthority, name: nil})

      {schedule, node_id} =
        compatibility_single_wave_schedule(
          authority,
          unquote(management_class),
          compatibility_load_result(:legacy_absent)
        )

      assert_dispatch_failure(
        dispatch_with_deadline(
          schedule,
          execute_request(schedule.request_id),
          model_load_request(node_id),
          client_impl: @compatibility_single_wave_client
        ),
        :dispatch_capacity_revalidation_failed
      )

      assert_receive :compatibility_status_called
      refute_receive :compatibility_status_called
      assert_receive :model_loaded
      refute_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
      assert_acceptance_gate_available(authority, node_id)
    end

    test "SPEC 5.9 initially loaded #{management_class} old BEAM load result uses captured matching capacity" do
      authority = start_supervised!({AllocationAuthority, name: nil})

      {schedule, node_id} =
        compatibility_single_wave_schedule(
          authority,
          unquote(management_class),
          compatibility_load_result(:legacy_absent),
          :loaded
        )

      _events =
        assert_dispatch_success(
          dispatch_with_deadline(
            schedule,
            execute_request(schedule.request_id),
            model_load_request(node_id),
            client_impl: @compatibility_single_wave_client
          )
        )

      assert_receive :compatibility_status_called
      refute_receive :compatibility_status_called
      assert_receive :model_loaded
      assert_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
      assert_acceptance_gate_available(authority, node_id)
    end

    test "SPEC 5.9 initially loaded #{management_class} uses captured capacity only when load evidence is absent" do
      authority = start_supervised!({AllocationAuthority, name: nil})

      {schedule, node_id} =
        compatibility_single_wave_schedule(
          authority,
          unquote(management_class),
          compatibility_load_result(:absent),
          :loaded
        )

      _events =
        assert_dispatch_success(
          dispatch_with_deadline(
            schedule,
            execute_request(schedule.request_id),
            model_load_request(node_id),
            client_impl: @compatibility_single_wave_client
          )
        )

      assert_receive :compatibility_status_called
      refute_receive :compatibility_status_called
      assert_receive :model_loaded
      assert_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
      assert_acceptance_gate_available(authority, node_id)
    end

    for evidence_scenario <- [:invalid, :mismatched] do
      test "SPEC 5.9 initially loaded #{management_class} #{evidence_scenario} evidence fails closed without captured fallback" do
        authority = start_supervised!({AllocationAuthority, name: nil})

        {schedule, node_id} =
          compatibility_single_wave_schedule(
            authority,
            unquote(management_class),
            compatibility_load_result(unquote(evidence_scenario)),
            :loaded
          )

        assert_dispatch_failure(
          dispatch_with_deadline(
            schedule,
            execute_request(schedule.request_id),
            model_load_request(node_id),
            client_impl: @compatibility_single_wave_client
          ),
          :dispatch_capacity_revalidation_failed
        )

        assert_receive :compatibility_status_called
        refute_receive :compatibility_status_called
        assert_receive :model_loaded
        refute_receive :execute_called
        assert AllocationAuthority.claim_count(authority, node_id) == 0
        assert_acceptance_gate_available(authority, node_id)
      end
    end

    test "SPEC 5.5 captured #{management_class} identity mismatch fails closed without reprobe" do
      authority = start_supervised!({AllocationAuthority, name: nil})

      {schedule, node_id} =
        compatibility_single_wave_schedule(authority, unquote(management_class))

      {:bounded_compatibility_probe, observation} = schedule.dispatch_identity_source

      mismatched_observation = %{
        observation
        | metadata: Map.put(observation.metadata, :node_id, Ecto.UUID.generate())
      }

      schedule = %{
        schedule
        | dispatch_identity_source: {:bounded_compatibility_probe, mismatched_observation}
      }

      assert_dispatch_failure(
        dispatch_with_deadline(
          schedule,
          execute_request(schedule.request_id),
          model_load_request(node_id),
          client_impl: @compatibility_single_wave_client
        ),
        :dispatch_capacity_node_identity_mismatch
      )

      assert_receive :compatibility_status_called
      refute_receive :compatibility_status_called
      refute_receive :model_loaded
      refute_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
      assert_acceptance_gate_available(authority, node_id)
    end
  end

  test "SPEC 4.6.2 pre-cutover degraded monitor-snapshot acquisition reaches execution" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    {schedule, node, snapshot_reads} =
      monitor_snapshot_schedule(authority, :degraded_acquisition)

    _events =
      assert_dispatch_success(
        dispatch_with_deadline(
          schedule,
          execute_request(schedule.request_id),
          model_load_request(node.id),
          client_impl: @monitor_snapshot_client
        )
      )

    assert_receive :monitor_snapshot_model_loaded
    assert_receive :monitor_snapshot_execute_called
    refute_receive :monitor_snapshot_status_called
    assert Agent.get(snapshot_reads, & &1) == 3
    assert AllocationAuthority.claim_count(authority, node.id) == 0
    assert_acceptance_gate_available(authority, node.id)
  end

  for scenario <- [
        :stale,
        :unhealthy,
        :disappeared,
        :aggregate_exhausted,
        :placement_exhausted,
        :placement_missing,
        :snapshot_unavailable
      ] do
    test "ADR 0017 monitor-snapshot final #{scenario} facts refuse execution with no status call" do
      authority = start_supervised!({AllocationAuthority, name: nil})

      {schedule, node, snapshot_reads} =
        monitor_snapshot_schedule(authority, unquote(scenario))

      assert_dispatch_failure(
        dispatch_with_deadline(
          schedule,
          execute_request(schedule.request_id),
          model_load_request(node.id),
          client_impl: @monitor_snapshot_client
        ),
        :dispatch_capacity_revalidation_failed
      )

      assert_receive :monitor_snapshot_model_loaded
      refute_receive :monitor_snapshot_execute_called
      refute_receive :monitor_snapshot_status_called
      assert Agent.get(snapshot_reads, & &1) == 3
      assert AllocationAuthority.claim_count(authority, node.id) == 0
      assert_acceptance_gate_available(authority, node.id)
    end
  end

  test "SPEC 4.6.2 pre-cutover degraded final revalidation reaches execution" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    {schedule, node, snapshot_reads} =
      monitor_snapshot_schedule(authority, :degraded)

    _events =
      assert_dispatch_success(
        dispatch_with_deadline(
          schedule,
          execute_request(schedule.request_id),
          model_load_request(node.id),
          client_impl: @monitor_snapshot_client
        )
      )

    assert_receive :monitor_snapshot_model_loaded
    assert_receive :monitor_snapshot_execute_called
    refute_receive :monitor_snapshot_status_called
    assert Agent.get(snapshot_reads, & &1) == 3
    assert AllocationAuthority.claim_count(authority, node.id) == 0
    assert_acceptance_gate_available(authority, node.id)
  end

  test "SPEC 4.6.2 enforcing degraded acquisition fails before model load" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-enforcing-degraded-acquisition"
    degraded = %{enforcing_input() | health: :degraded}

    schedule =
      authority
      |> capacity_schedule(node_id, request_id)
      |> Map.put(:dispatch_identity_source, :trusted_monitor_snapshot)
      |> Map.put(:dispatch_capacity_acquisition_input_provider, fn -> degraded end)

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :dispatch_capacity_unavailable
    )

    refute_receive :model_loaded
    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
    assert_acceptance_gate_available(authority, node_id)
  end

  test "SPEC 4.6.2 enforcing degraded final revalidation suppresses execution" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-enforcing-degraded-revalidation"
    degraded = %{enforcing_input() | health: :degraded}

    schedule =
      authority
      |> capacity_schedule(node_id, request_id)
      |> Map.put(:dispatch_capacity_input_provider, fn -> degraded end)

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :dispatch_capacity_revalidation_failed
    )

    assert_receive :model_loaded
    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
    assert_acceptance_gate_available(authority, node_id)
  end

  test "ADR 0017 target removal before acquisition fails closed without probing" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    {schedule, node, snapshot_reads} =
      monitor_snapshot_schedule(authority, :target_removed_before_acquisition)

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(schedule.request_id),
        model_load_request(node.id),
        client_impl: @monitor_snapshot_client
      ),
      :dispatch_capacity_facts_unavailable
    )

    refute_receive :monitor_snapshot_model_loaded
    refute_receive :monitor_snapshot_execute_called
    refute_receive :monitor_snapshot_status_called
    assert Agent.get(snapshot_reads, & &1) == 2
    assert AllocationAuthority.claim_count(authority, node.id) == 0
    assert_acceptance_gate_available(authority, node.id)
  end

  test "ADR 0017 target removal before final revalidation suppresses execution" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    {schedule, node, snapshot_reads} =
      monitor_snapshot_schedule(authority, :target_removed_before_final)

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(schedule.request_id),
        model_load_request(node.id),
        client_impl: @monitor_snapshot_client
      ),
      :dispatch_capacity_revalidation_failed
    )

    assert_receive :monitor_snapshot_model_loaded
    refute_receive :monitor_snapshot_execute_called
    refute_receive :monitor_snapshot_status_called
    assert Agent.get(snapshot_reads, & &1) == 3
    assert AllocationAuthority.claim_count(authority, node.id) == 0
    assert_acceptance_gate_available(authority, node.id)
  end

  test "ADR 0017 marked snapshot dispatch rejects claim schedule target identity mismatch without probing" do
    authority = start_supervised!({AllocationAuthority, name: nil})

    {schedule, node, _snapshot_reads} =
      monitor_snapshot_schedule(authority, :eligible)

    mismatched_target = %{schedule.runtime_endpoint_target | node_id: Ecto.UUID.generate()}
    schedule = %{schedule | runtime_endpoint_target: mismatched_target}

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(schedule.request_id),
        model_load_request(node.id),
        client_impl: @monitor_snapshot_client
      ),
      :dispatch_capacity_node_identity_mismatch
    )

    refute_receive :monitor_snapshot_model_loaded
    refute_receive :monitor_snapshot_execute_called
    refute_receive :monitor_snapshot_status_called
    assert AllocationAuthority.claim_count(authority, node.id) == 0
  end

  test "SPEC 5.9 dispatch probe cannot move execution away from the claimed Node" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    runtime_node = insert_admitted_node!(target, DateTime.utc_now())
    claimed_node_id = claim_node_id()
    request_id = "request-probe-identity-remap"
    status = production_status(runtime_node, target, [])

    @production_fresh_status_client.configure(self(), status, status)

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, claimed_node_id, request_id),
        execute_request(request_id),
        model_load_request(claimed_node_id),
        client_impl: @production_fresh_status_client
      ),
      :dispatch_capacity_node_identity_mismatch
    )

    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, claimed_node_id) == 0
    assert AllocationAuthority.claim_count(authority, runtime_node.id) == 0
  end

  test "SPEC 5.9 a claimed Node whose dispatch probe reports no identity fails closed" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    DispatchCapacityFixtures.clear_probe_node_id()
    node_id = Ecto.UUID.generate()
    request_id = "request-probe-identity-missing"

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :dispatch_capacity_node_identity_mismatch
    )

    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 a claimed Node whose dispatch probe fails cannot prove identity" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-probe-identity-unverified"

    assert_dispatch_failure(
      dispatch_with_deadline(
        capacity_schedule(authority, node_id, request_id),
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @unprobeable_client
      ),
      :dispatch_capacity_node_identity_mismatch
    )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 admitted MultiNode dispatch rejects nonmatching post-load placement evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    put_inference(runtime_client_targets: [target])
    now = DateTime.utc_now()
    node = insert_admitted_node!(target, now)
    initial_status = production_status(node, target, [])

    post_load_status =
      node
      |> production_status(target, [%{model_id: "test/model", version: "v1"}])
      |> Map.put(:runtime_model_placements, [
        %{
          model_ref: %{model_id: "different/model", version: "v1"},
          active_request_count: 0,
          max_concurrency: 2
        }
      ])

    @production_fresh_status_client.configure(self(), initial_status, post_load_status)

    assert {:ok, schedule} =
             MultiNode.schedule(
               canonical_request(),
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority
             )

    assert schedule.strategy == :multi_node

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(schedule.request_id),
        model_load_request(node.id),
        client_impl: @production_fresh_status_client
      ),
      :dispatch_capacity_revalidation_failed
    )

    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, node.id) == 0
  end

  test "SPEC 5.9 an unprobed unmanaged schedule stays dispatchable end to end" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    request_id = "request-unprobed-unmanaged"

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               Inference.runtime_client_target(),
               probe_status?: false,
               dispatch_capacity_authority: authority
             )

    assert is_nil(schedule.node_id)
    assert %Input{} = schedule.dispatch_capacity_input
    assert %Evaluator.Result{eligible?: true} = schedule.dispatch_capacity_evaluation

    _events =
      assert_dispatch_success(
        dispatch_with_deadline(
          Map.put(schedule, :request_id, request_id),
          execute_request(request_id),
          model_load_request("unmanaged"),
          client_impl: @gate_client
        )
      )
  end

  test "SPEC 5.9 a held acceptance gate fails dispatch bounded instead of blocking" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-acceptance-gate-busy"

    {:ok, lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: 1_000,
        timeout_at: DateTime.add(DateTime.utc_now(), 1_000, :millisecond)
    }

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :dispatch_capacity_acceptance_gate_busy
    )

    refute_receive :execute_called, 50
    assert :ok = QueueManager.release_acceptance_gate(lease, authority: authority)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 an exhausted deadline reports dispatch timeout instead of gate contention" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-deadline-exhausted-before-acceptance-gate"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: 0,
        timeout_at: DateTime.utc_now()
    }

    assert_dispatch_failure(
      dispatch_with_deadline(
        schedule,
        execute_request(request_id),
        model_load_request(node_id),
        client_impl: @gate_client
      ),
      :request_timeout
    )

    refute_receive :execute_called, 50

    assert {:ok, lease} =
             QueueManager.acquire_acceptance_gate(node_id,
               authority: authority,
               gate_timeout_ms: 100
             )

    assert :ok = QueueManager.release_acceptance_gate(lease, authority: authority)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 caller death while waiting for acceptance prevents execution" do
    observer_tag = make_ref()

    authority =
      start_supervised!(
        {AllocationAuthority, name: nil, acceptance_gate_queue_observer: {self(), observer_tag}}
      )

    node_id = claim_node_id()
    request_id = "request-caller-death-during-acceptance-wait"
    caller = spawn(fn -> Process.sleep(:infinity) end)
    caller_ref = Process.monitor(caller)

    {:ok, held_lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @gate_client,
          caller: caller
        )
      end)

    try do
      assert_receive :model_loaded
      assert_receive {^observer_tag, :acceptance_gate_waiter_queued, ^node_id}
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      assert :ok = QueueManager.release_acceptance_gate(held_lease, authority: authority)

      assert %AttemptOutcome{
               attempt_outcome: :cancelled,
               node_id: ^node_id,
               accepted: false,
               events: [],
               failure: %{
                 "failure_class" => "cancellation",
                 "failure_code" => "request_caller_disconnect"
               },
               execution_resolution: :not_started,
               capacity_release_outcome: :released,
               output_committed: false
             } = Task.await(dispatch)

      refute_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
    after
      Task.shutdown(dispatch, :brutal_kill)
      QueueManager.release_acceptance_gate(held_lease, authority: authority)
    end

    assert {:ok, next_lease} =
             QueueManager.acquire_acceptance_gate(node_id,
               authority: authority,
               gate_timeout_ms: 100
             )

    assert :ok = QueueManager.release_acceptance_gate(next_lease, authority: authority)
  end

  test "SPEC 5.9 acceptance waiting and streaming share one request timeout" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-shared-acceptance-deadline"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: 1_500,
        timeout_at: DateTime.add(DateTime.utc_now(), 1_500, :millisecond)
    }

    {:ok, held_lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)
    started_at = System.monotonic_time(:millisecond)

    dispatch =
      Task.async(fn ->
        dispatch_with_deadline(schedule, execute_request(request_id), model_load_request(node_id),
          client_impl: @cancellable_stream_client
        )
      end)

    try do
      assert_receive :model_loaded
      Process.sleep(600)
      assert :ok = QueueManager.release_acceptance_gate(held_lease, authority: authority)

      # A deadline that excluded the 600ms gate wait would cancel no earlier
      # than 2,100ms after dispatch started, so the upper bound still proves
      # acceptance waiting and streaming share one request timeout.
      assert_receive {:cancel_received, emitter}, 1_300
      assert System.monotonic_time(:millisecond) - started_at < 2_000

      send(emitter, :finish_cancel)
      _events = assert_dispatch_success(Task.await(dispatch))
      assert AllocationAuthority.claim_count(authority, node_id) == 0
    after
      Task.shutdown(dispatch, :brutal_kill)
      QueueManager.release_acceptance_gate(held_lease, authority: authority)

      case :persistent_term.get({CancellableStreamClient, :emitter}, nil) do
        emitter when is_pid(emitter) -> Process.exit(emitter, :kill)
        nil -> :ok
      end
    end
  end

  defp claim_node_id do
    node_id = Ecto.UUID.generate()
    DispatchCapacityFixtures.put_probe_node_id(node_id)
    node_id
  end

  defp dispatch_with_deadline(schedule, execute_request, model_load_request, opts) do
    timeout_ms = Map.get(schedule, :request_timeout_ms, 5_000)

    schedule
    |> Map.put_new(:timeout_at, DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond))
    |> RequestDispatcher.dispatch(execute_request, model_load_request, opts)
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-capacity",
      model_id: "test/model",
      version: "v1",
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2
    }
  end

  defp model_load_request(node_id) do
    %EnsureModelLoadedRequest{
      node_id: node_id,
      model_id: "test/model",
      version: "v1"
    }
  end

  defp compatibility_single_wave_schedule(
         authority,
         management_class,
         load_result \\ compatibility_load_result(:valid),
         candidate_state \\ :cold
       ) do
    configured_address = SingleNode.target()

    configured_target =
      Target.grpc_compat(
        host: Keyword.fetch!(configured_address, :host),
        port: Keyword.fetch!(configured_address, :port),
        metadata: %{capacity_management_class: management_class}
      )

    node_id = claim_node_id()

    node = %Node{
      id: node_id,
      display_name: "compatibility-node",
      hostname: "compatibility-node.local"
    }

    response =
      case candidate_state do
        :cold ->
          production_status(node, configured_address, [])

        :loaded ->
          node
          |> production_status(configured_address, [%{model_id: "test/model", version: "v1"}])
          |> Map.put(:runtime_model_placements, [
            %{
              model_ref: %{model_id: "test/model", version: "v1"},
              placement_state: :PLACEMENT_STATE_LOADED,
              active_request_count: 0,
              max_concurrency: 2
            }
          ])
      end

    @compatibility_single_wave_client.configure(self(), response, load_result)

    put_inference(
      allow_static_runtime_target_fallback: true,
      runtime_endpoint_targets: [],
      runtime_client_targets: [configured_address]
    )

    assert {:ok, schedule} =
             MultiNode.schedule(
               canonical_request(),
               status_client: @compatibility_single_wave_client,
               active_runtime_endpoint_targets_provider: fn -> {:ok, []} end,
               runtime_endpoint_targets_provider: fn {:ok, []} -> [configured_target] end,
               dispatch_capacity_authority: authority
             )

    {schedule, node_id}
  end

  defp compatibility_load_result(:valid) do
    %Operation.EnsureModelLoadedResult{
      already_loaded: false,
      placement_state: :loaded,
      worker_supports_prompt_token_ids: true,
      placement_capacity: compatibility_placement_capacity("test/model"),
      placement_capacity_evidence_state: :valid
    }
  end

  defp compatibility_load_result(:absent) do
    %Operation.EnsureModelLoadedResult{
      already_loaded: false,
      placement_state: :loaded,
      worker_supports_prompt_token_ids: true,
      placement_capacity: nil,
      placement_capacity_evidence_state: :absent
    }
  end

  defp compatibility_load_result(:legacy_absent) do
    :absent
    |> compatibility_load_result()
    |> Map.delete(:placement_capacity_evidence_state)
  end

  defp compatibility_load_result(:invalid) do
    %Operation.EnsureModelLoadedResult{
      already_loaded: false,
      placement_state: :loaded,
      worker_supports_prompt_token_ids: true,
      placement_capacity: nil,
      placement_capacity_evidence_state: :invalid
    }
  end

  defp compatibility_load_result(:mismatched) do
    %Operation.EnsureModelLoadedResult{
      already_loaded: false,
      placement_state: :loaded,
      worker_supports_prompt_token_ids: true,
      placement_capacity: compatibility_placement_capacity("other/model"),
      placement_capacity_evidence_state: :valid
    }
  end

  defp compatibility_placement_capacity(model_id) do
    PlacementCapacity.new(%{
      model_ref: %{model_id: model_id, version: "v1"},
      active_request_count: 0,
      max_concurrency: 2,
      source: :ensure_model_loaded_result
    })
  end

  defp monitor_snapshot_schedule(authority, final_scenario) do
    configured_target = SingleNode.target()
    now = DateTime.utc_now()
    initial_at = DateTime.add(now, -2, :second)
    acquisition_at = DateTime.add(now, -1, :second)
    node = insert_admitted_node!(configured_target, initial_at)

    target =
      Target.grpc_compat(
        host: Keyword.fetch!(configured_target, :host),
        port: Keyword.fetch!(configured_target, :port),
        node_id: node.id,
        metadata: %{
          authorization: :inference_dispatch,
          source: :trusted_node_inventory
        }
      )

    initial =
      monitor_snapshot(
        [monitor_snapshot_candidate(node, target, initial_at)],
        initial_at
      )

    acquisition =
      monitor_snapshot_acquisition(final_scenario, node, target, acquisition_at)

    final = monitor_snapshot_final(final_scenario, node, target, now)

    snapshot_reads =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> 0 end},
          id: {__MODULE__, :monitor_snapshot_schedule_snapshot_reads}
        )
      )

    effective_reads =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> 0 end},
          id: {__MODULE__, :monitor_snapshot_schedule_effective_reads}
        )
      )

    effective_targets_provider = fn {:ok, [^target]} ->
      read_count = Agent.get_and_update(effective_reads, fn count -> {count, count + 1} end)

      case {final_scenario, read_count} do
        {:target_removed_before_acquisition, count} when count >= 1 -> []
        {:target_removed_before_final, count} when count >= 2 -> []
        _available -> [target]
      end
    end

    snapshot_provider = fn effective_targets, _active_targets, _opts ->
      read_count = Agent.get_and_update(snapshot_reads, fn count -> {count, count + 1} end)

      result =
        monitor_snapshot_schedule_result(
          effective_targets,
          target,
          read_count,
          initial,
          acquisition,
          final,
          now
        )

      persist_monitor_snapshot_evidence(result)
      result
    end

    put_inference(
      allow_static_runtime_target_fallback: true,
      runtime_endpoint_targets: [],
      runtime_client_targets: [configured_target]
    )

    assert {:ok, schedule} =
             MultiNode.schedule(
               canonical_request(),
               active_runtime_endpoint_targets_provider: fn -> {:ok, [target]} end,
               runtime_endpoint_targets_provider: effective_targets_provider,
               production_candidate_snapshot_provider: snapshot_provider,
               dispatch_capacity_authority: authority
             )

    {schedule, node, snapshot_reads}
  end

  defp monitor_snapshot_schedule_result(
         effective_targets,
         target,
         read_count,
         initial,
         acquisition,
         final,
         now
       ) do
    if effective_targets == [target] do
      case read_count do
        0 -> {:ok, initial}
        1 -> {:ok, acquisition}
        _later -> final
      end
    else
      {:ok, monitor_snapshot([], now)}
    end
  end

  defp monitor_snapshot_acquisition(:degraded_acquisition, node, target, observed_at) do
    degraded_node = %{node | health: :degraded}

    monitor_snapshot(
      [monitor_snapshot_candidate(degraded_node, target, observed_at)],
      observed_at
    )
  end

  defp monitor_snapshot_acquisition(_scenario, node, target, observed_at) do
    monitor_snapshot(
      [monitor_snapshot_candidate(node, target, observed_at)],
      observed_at
    )
  end

  defp monitor_snapshot_final(:eligible, node, target, observed_at) do
    placement = monitor_snapshot_placement(0, 2)

    {:ok,
     monitor_snapshot(
       [monitor_snapshot_candidate(node, target, observed_at, placements: [placement])],
       observed_at
     )}
  end

  defp monitor_snapshot_final(:aggregate_exhausted, node, target, observed_at) do
    {:ok,
     monitor_snapshot(
       [
         monitor_snapshot_candidate(node, target, observed_at,
           active_request_count: 2,
           max_concurrency: 2
         )
       ],
       observed_at
     )}
  end

  defp monitor_snapshot_final(:placement_exhausted, node, target, observed_at) do
    placement = monitor_snapshot_placement(1, 1)

    {:ok,
     monitor_snapshot(
       [monitor_snapshot_candidate(node, target, observed_at, placements: [placement])],
       observed_at
     )}
  end

  defp monitor_snapshot_final(:placement_missing, node, target, observed_at) do
    {:ok,
     monitor_snapshot(
       [monitor_snapshot_candidate(node, target, observed_at)],
       observed_at
     )}
  end

  defp monitor_snapshot_final(:degraded, node, target, observed_at) do
    degraded_node = %{node | health: :degraded}
    placement = monitor_snapshot_placement(0, 2)

    {:ok,
     monitor_snapshot(
       [monitor_snapshot_candidate(degraded_node, target, observed_at, placements: [placement])],
       observed_at
     )}
  end

  defp monitor_snapshot_final(scenario, node, target, observed_at)
       when scenario in [
              :degraded_acquisition,
              :target_removed_before_acquisition,
              :target_removed_before_final
            ],
       do: monitor_snapshot_final(:eligible, node, target, observed_at)

  defp monitor_snapshot_final(:snapshot_unavailable, _node, _target, _observed_at) do
    {:error, :candidate_snapshot_unavailable}
  end

  defp monitor_snapshot_final(scenario, node, target, observed_at)
       when scenario in [:stale, :unhealthy, :disappeared] do
    reason_code =
      case scenario do
        :stale -> "node_observation_stale"
        :unhealthy -> "node_health_unhealthy"
        :disappeared -> "node_not_active"
      end

    rejection = %CandidateSnapshot.Rejection{
      target: target,
      node_id: node.id,
      observed_at: observed_at,
      reason_codes: [reason_code],
      diagnostics: %{fact: Atom.to_string(scenario)},
      candidate_source: "monitor_snapshot"
    }

    {:ok, monitor_snapshot([], observed_at, [rejection])}
  end

  defp monitor_snapshot(candidates, observed_at, rejections \\ []) do
    %CandidateSnapshot{
      observed_at: observed_at,
      freshness_threshold_ms: 30_000,
      candidates: candidates,
      rejections: rejections
    }
  end

  defp monitor_snapshot_candidate(node, target, observed_at, opts \\ []) do
    active_request_count = Keyword.get(opts, :active_request_count, 0)
    max_concurrency = Keyword.get(opts, :max_concurrency, 2)

    %Candidate{
      target: target,
      node: %{node | last_heartbeat_at: observed_at},
      heartbeat_id: System.unique_integer([:positive]),
      observed_at: observed_at,
      availability: :available,
      worker_state: :idle,
      active_request_count: active_request_count,
      max_concurrency: max_concurrency,
      aggregate_capacity_evidence: %{
        active_request_count: active_request_count,
        runtime_concurrency_limit: max_concurrency,
        validity: :valid
      },
      placements: Keyword.get(opts, :placements, []),
      runtime_memory_budgets: [],
      runtime_prefix_cache_statuses: [],
      supports_prompt_token_ids: true,
      candidate_source: "monitor_snapshot"
    }
  end

  defp monitor_snapshot_placement(active_request_count, max_concurrency) do
    Placement.new(%{
      model_ref: %{model_id: "test/model", version: "v1"},
      state: :loaded,
      capacity: %{
        active_request_count: active_request_count,
        max_concurrency: max_concurrency,
        source: :runtime
      }
    })
  end

  defp persist_monitor_snapshot_evidence({:ok, snapshot}) do
    Enum.each(snapshot.candidates, fn candidate ->
      assert {:ok, _evidence} =
               Orchard.DispatchCapacity.record_capacity_evidence(candidate.node.id, %{
                 active_request_count: candidate.active_request_count,
                 observed_at: candidate.observed_at,
                 runtime_concurrency_limit: candidate.max_concurrency,
                 validity: :valid
               })
    end)
  end

  defp persist_monitor_snapshot_evidence({:error, _reason}), do: :ok

  defp assert_acceptance_gate_available(authority, node_id) do
    assert {:ok, lease} =
             QueueManager.acquire_acceptance_gate(node_id, authority: authority)

    assert :ok = QueueManager.release_acceptance_gate(lease, authority: authority)
  end

  defp capacity_schedule(authority, node_id, request_id) do
    input = enforcing_input()

    %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      timeout_at: DateTime.add(DateTime.utc_now(), 5_000, :millisecond),
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end,
      dispatch_capacity_authority: authority
    }
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "int-production-post-load",
      public_id: "pub-production-post-load",
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %ModelRef{model_id: "test/model", version: "v1"},
      rendered_prompt: "hello orchard"
    })
  end

  defp insert_canonical_model! do
    %Model{}
    |> Model.changeset(%{
      model_id: "test/model",
      version: "v1",
      state: :active,
      format: "mlx",
      capabilities: ["text"],
      tokenizer: %{"type" => "huggingface", "ref" => "test/tokenizer"},
      artifact_uri: "file:///tmp/request-dispatcher-claim-test-model",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1,
      resident_memory_bytes: 1,
      kv_cache_bytes_per_token: 1,
      prefill_workspace_bytes_per_token: 1,
      runtime_requirements: %{}
    })
    |> Repo.insert!()
  end

  defp open_placement_breaker!(node_id, model_id) do
    now = DateTime.utc_now()

    for offset <- [2, 1, 0] do
      assert {:ok, _decision} =
               CircuitBreakers.record_failure(
                 %{
                   failure_id: Ecto.UUID.generate(),
                   node_id: node_id,
                   model_id: model_id,
                   failure_class: "model_load_failure",
                   occurred_at: DateTime.add(now, -offset, :second)
                 },
                 now: now
               )
    end
  end

  defp put_inference(overrides) do
    config = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(config, overrides))
  end

  defp insert_admitted_node!(target, now, node_id \\ Ecto.UUID.generate()) do
    host = Keyword.fetch!(target, :host)
    port = Keyword.fetch!(target, :port)
    unique = System.unique_integer([:positive])

    {:ok, node} =
      Repo.transaction(fn ->
        node =
          %Node{}
          |> Node.changeset(%{
            id: node_id,
            hostname: "dispatch-#{unique}.local",
            display_name: "dispatch-#{unique}",
            advertise_addr: host,
            rpc_port: port,
            state: :active,
            health: :healthy,
            capabilities: %{},
            last_heartbeat_at: now
          })
          |> Repo.insert!()

        decision =
          %AdmissionDecision{}
          |> AdmissionDecision.changeset(%{
            node_id: node.id,
            decision: :admitted,
            actor_type: "system",
            actor_id: "request-dispatcher-test",
            observed_identity: %{},
            metadata: %{},
            decided_at: now
          })
          |> Repo.insert!()

        %Policy{}
        |> Policy.approved_explicit_changeset(%{
          node_id: node.id,
          admission_decision_id: decision.id,
          controller_dispatch_ceiling: 2,
          approved_by_actor_type: "system",
          approved_by_actor_id: "request-dispatcher-test",
          approved_at: now,
          approval_reason: "request dispatcher test fixture",
          version: 1
        })
        |> Repo.insert!()

        node
      end)

    node
  end

  defp production_status(node, target, loaded_models) do
    %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "test",
        listen_host: Keyword.fetch!(target, :host),
        listen_port: Keyword.fetch!(target, :port),
        worker_backend: "mlx"
      },
      runtime_health: %{ready: true},
      loaded_models: loaded_models,
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    }
  end

  defp assert_dispatch_success(%AttemptOutcome{events: events}) when is_list(events), do: events

  defp assert_dispatch_failure(%AttemptOutcome{failure: failure} = outcome, expected_reason)
       when is_map(failure) and is_atom(expected_reason) do
    actual_reason = Map.get(failure, "raw_source_code", failure["failure_code"])
    assert actual_reason == Atom.to_string(expected_reason)
    outcome
  end

  defp enforcing_input do
    %Input{
      authority_phase: :enforcing,
      policy_presence: :present,
      policy_state: :enforcing,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 1},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: {:valid, 1},
      controller_accounted_allocation: 0,
      placement_capacity: {:valid, 0, 1},
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp unmanaged_input do
    %Input{
      authority_phase: :invalid,
      policy_presence: :missing,
      policy_state: :missing,
      management_classification: {:ok, :unmanaged_compatibility},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 1},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: :missing,
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end
end
