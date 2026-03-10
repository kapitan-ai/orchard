defmodule Orchard.Dispatch.DispatchTest do
  @moduledoc """
  Tests for R6: single-node dispatch and cancellation.

  These tests run against the live node-agent gRPC server (on port 50071
  in test config, backed by FakeRuntimeAdapter) to prove end-to-end
  dispatch through the controller → node-agent boundary.
  """

  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    StatusResponse
  }

  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: Client
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference
  alias Orchard.InferenceEvent
  alias Orchard.Node.ModelManager

  @model_id "mlx-community/phi-3"
  @version "main"

  setup do
    # Reset node-agent state between tests to avoid model-already-loaded
    ModelManager.reset()
    :ok
  end

  describe "GrpcNodeRuntimeClient" do
    test "connects to the node-agent and retrieves status" do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      assert {:ok, %StatusResponse{} = response} = Client.status(channel)
      assert response.worker_state == :WORKER_STATE_IDLE
      assert response.loaded_models == []

      Client.disconnect(channel)
    end

    test "ensure_model_loaded loads a model via gRPC" do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      request = model_load_request()
      assert {:ok, response} = Client.ensure_model_loaded(channel, request)
      refute response.already_loaded
      assert response.placement_state == :PLACEMENT_STATE_LOADED

      # Idempotent
      assert {:ok, response2} = Client.ensure_model_loaded(channel, request)
      assert response2.already_loaded

      Client.disconnect(channel)
    end

    test "execute_inference streams events to the caller" do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      # Load model first
      {:ok, _} = Client.ensure_model_loaded(channel, model_load_request())

      # Execute inference
      request = execute_request("req-dispatch-stream")
      {:ok, task_ref} = Client.execute_inference(channel, request)

      events = collect_dispatch_events(task_ref, "req-dispatch-stream")

      # FakeRuntimeAdapter emits: accepted, "orchard ", "ready", completed
      assert length(events) >= 3
      assert InferenceEvent.kind(hd(events)) == :accepted
      assert List.last(events) |> InferenceEvent.terminal?()

      Client.disconnect(channel)
    end

    test "cancel_inference sends cancellation to node-agent" do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      {:ok, _} = Client.ensure_model_loaded(channel, model_load_request())

      assert :ok = Client.cancel_inference(channel, "req-nonexistent")

      Client.disconnect(channel)
    end
  end

  describe "RequestDispatcher" do
    test "dispatches a request and returns all events including terminal" do
      schedule = build_schedule("req-dispatch-e2e")
      execute = execute_request("req-dispatch-e2e")
      model_load = model_load_request()

      assert {:ok, events} = RequestDispatcher.dispatch(schedule, execute, model_load)

      assert length(events) >= 3
      assert InferenceEvent.kind(hd(events)) == :accepted
      assert List.last(events) |> InferenceEvent.terminal?()

      # Verify delta content from fake adapter
      deltas =
        events
        |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
        |> Enum.map(& &1.event.delta)

      assert deltas == ["orchard ", "ready"]
    end

    test "dispatches with event_handler callback" do
      schedule = build_schedule("req-dispatch-handler")
      execute = execute_request("req-dispatch-handler")
      model_load = model_load_request()

      test_pid = self()

      handler = fn request_id, event ->
        send(test_pid, {:handler_event, request_id, event})
      end

      assert {:ok, events} =
               RequestDispatcher.dispatch(schedule, execute, model_load, event_handler: handler)

      assert length(events) >= 3

      # Verify handler received all events
      Enum.each(events, fn event ->
        assert_received {:handler_event, "req-dispatch-handler", ^event}
      end)
    end

    test "timeout fires cancellation and returns events with terminal" do
      # Use a very short timeout to trigger it
      schedule = build_schedule("req-dispatch-timeout", request_timeout_ms: 1)
      execute = execute_request("req-dispatch-timeout")
      model_load = model_load_request()

      assert {:ok, events} = RequestDispatcher.dispatch(schedule, execute, model_load)

      # Should have at least a terminal event (either from cancel or timeout synthesis)
      assert events != []
      terminal = List.last(events)
      assert InferenceEvent.terminal?(terminal)
    end

    test "caller disconnect triggers cancellation" do
      schedule = build_schedule("req-dispatch-disconnect")
      execute = execute_request("req-dispatch-disconnect")
      model_load = model_load_request()

      test_pid = self()

      # Spawn a caller process that we'll kill to simulate disconnect
      caller =
        spawn(fn ->
          receive do
            :stay_alive -> :ok
          end
        end)

      # Dispatch in a separate process, monitoring the caller
      dispatch_pid =
        spawn(fn ->
          result =
            RequestDispatcher.dispatch(schedule, execute, model_load, caller: caller)

          send(test_pid, {:dispatch_result, result})
        end)

      # Give dispatch a moment to connect and start
      Process.sleep(50)

      # Kill the caller to simulate disconnect
      Process.exit(caller, :kill)

      # Dispatch should complete with events
      assert_receive {:dispatch_result, {:ok, events}}, 10_000
      assert events != []
      terminal = List.last(events)
      assert InferenceEvent.terminal?(terminal)

      # Clean up
      if Process.alive?(dispatch_pid), do: Process.exit(dispatch_pid, :kill)
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp model_load_request do
    %EnsureModelLoadedRequest{
      node_id: "local",
      model_id: @model_id,
      version: @version
    }
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-dispatch",
      model_id: @model_id,
      version: @version,
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2
    }
  end

  defp build_schedule(request_id, opts \\ []) do
    %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 5_000)
    }
  end

  defp collect_dispatch_events(task_ref, request_id, events \\ []) do
    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        events = [event | events]

        if InferenceEvent.terminal?(event) do
          Enum.reverse(events)
        else
          collect_dispatch_events(task_ref, request_id, events)
        end

      {:dispatch_done, ^task_ref, _result} ->
        Enum.reverse(events)
    after
      5_000 ->
        flunk("timed out waiting for dispatch events")
    end
  end
end
