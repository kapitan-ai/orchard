defmodule Orchard.Dispatch.DispatchTest.DisconnectRaisingClient do
  @moduledoc false

  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  def connect(_target), do: {:ok, :disconnect_raising_channel}

  def status(_channel, _opts \\ []), do: {:ok, %StatusResponse{}}

  def disconnect(_channel) do
    raise FunctionClauseError, module: __MODULE__, function: :disconnect, arity: 1
  end

  def ensure_model_loaded(
        _channel,
        %Operation.EnsureModelLoadedRequest{},
        _opts \\ []
      ) do
    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    send(owner, {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)})

    send(
      owner,
      {:runtime_endpoint_event, ref, request.request_id,
       InferenceEvent.completed(:finish_reason_stop, nil)}
    )

    send(owner, {:runtime_endpoint_done, ref, :ok})

    {:ok, ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.Dispatch.DispatchTest do
  @moduledoc """
  Tests for R6: single-node dispatch and cancellation.

  These tests run against the live node-agent gRPC server (on port 50071
  in test config, backed by FakeRuntimeAdapter) to prove end-to-end
  dispatch through the controller → node-agent boundary.
  """

  use ExUnit.Case, async: false

  import Orchard.TestSupport.SentryContextHelpers

  alias Orchard.ArtifactBundle

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    ModelRef,
    ScorePrefixCacheRequest,
    StatusResponse
  }

  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: Client
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager

  @model_id "mlx-community/phi-3"
  @version "main"

  setup :setup_sentry_context

  setup do
    # Reset node-agent state between tests to avoid model-already-loaded
    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      File.rm_rf(bundle.cache_path)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
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

    test "ensure_model_loaded loads a model via gRPC", %{bundle: bundle} do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      request = model_load_request(bundle)
      assert {:ok, response} = Client.ensure_model_loaded(channel, request)
      refute response.already_loaded
      assert response.placement_state == :PLACEMENT_STATE_LOADED

      # Idempotent
      assert {:ok, response2} = Client.ensure_model_loaded(channel, request)
      assert response2.already_loaded

      Client.disconnect(channel)
    end

    test "execute_inference streams events to the caller", %{bundle: bundle} do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      # Load model first
      {:ok, _} = Client.ensure_model_loaded(channel, model_load_request(bundle))

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

    test "cancel_inference sends cancellation to node-agent", %{bundle: bundle} do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      {:ok, _} = Client.ensure_model_loaded(channel, model_load_request(bundle))

      assert :ok = Client.cancel_inference(channel, "req-nonexistent")

      Client.disconnect(channel)
    end

    test "score_prefix_cache canonicalizes worker status_message for model_not_loaded" do
      target = Inference.runtime_client_target()

      assert {:ok, response} =
               Client.score_prefix_cache(
                 target,
                 score_prefix_cache_request("missing-model", "req-score-model-not-loaded")
               )

      assert response.status_code == "model_not_loaded"
      assert response.status_message == "model not loaded"
      refute response.status_message == "model is not loaded"
      assert response.score_tier == "unknown"
    end

    test "score_prefix_cache canonicalizes transport failures to default error message" do
      target = [host: "127.0.0.1", port: 1]

      assert {:ok, response} =
               Client.score_prefix_cache(
                 target,
                 score_prefix_cache_request("missing-model", "req-score-transport-error")
               )

      assert response.status_code == "error"
      assert response.status_message == "prefix cache scoring error"
      assert response.score_tier == "unknown"
      assert response.resident_fingerprint_match == false
      assert response.session_started_unix_ms == 0
    end
  end

  describe "RequestDispatcher" do
    test "dispatches a request and returns all events including terminal", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-e2e")
      execute = execute_request("req-dispatch-e2e")
      model_load = model_load_request(bundle)

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

    test "returns streamed events when disconnect cleanup raises", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-cleanup-raises")
      execute = execute_request("req-dispatch-cleanup-raises")
      model_load = model_load_request(bundle)

      assert {:ok, events} =
               RequestDispatcher.dispatch(schedule, execute, model_load,
                 client_impl: Orchard.Dispatch.DispatchTest.DisconnectRaisingClient
               )

      assert Enum.map(events, &InferenceEvent.kind/1) == [:accepted, :completed]
      assert List.last(events) |> InferenceEvent.terminal?()
    end

    test "Sentry controller enrichment records sparse dispatch context", %{bundle: bundle} do
      enable_controller_sentry()
      schedule = build_schedule("req-dispatch-sentry")
      execute = execute_request("req-dispatch-sentry")
      model_load = model_load_request(bundle)

      assert {:ok, events} = RequestDispatcher.dispatch(schedule, execute, model_load)
      assert Enum.any?(events, &InferenceEvent.terminal?/1)

      context = sentry_context()
      messages = breadcrumb_messages()

      assert context.tags.orchard_app == "controller"
      assert context.tags.orchard_surface == "api"
      assert context.tags.scheduler_strategy == "single_node"
      assert context.tags.failure_category == "ok"
      assert context.tags.terminal_source == "stream"

      assert context.extra.orchard_scheduler_strategy == :single_node
      assert context.extra.orchard_target_host_sanitized == "[redacted]"
      assert is_integer(context.extra.orchard_ensure_model_loaded_ms)
      assert is_integer(context.extra.orchard_accepted_to_first_delta_ms)
      assert is_integer(context.extra.orchard_accepted_to_terminal_ms)
      assert context.extra.orchard_event_count == length(events)

      assert "node.resolved" in messages
      assert "ensure_model_load.started" in messages
      assert "ensure_model_load.completed" in messages
      assert Enum.count(messages, &(&1 == "first_delta.received")) == 1
      refute inspect(context) =~ "127.0.0.1"
    end

    test "dispatches with event_handler callback", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-handler")
      execute = execute_request("req-dispatch-handler")
      model_load = model_load_request(bundle)

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

    test "timeout fires cancellation and returns events with terminal", %{bundle: bundle} do
      # Use a very short timeout to trigger it
      schedule = build_schedule("req-dispatch-timeout", request_timeout_ms: 1)
      execute = execute_request("req-dispatch-timeout")
      model_load = model_load_request(bundle)

      assert {:ok, events} = RequestDispatcher.dispatch(schedule, execute, model_load)

      # Should have at least a terminal event (either from cancel or timeout synthesis)
      assert events != []
      terminal = List.last(events)
      assert InferenceEvent.terminal?(terminal)

      # Exactly one terminal event in the stream (Task 4 guarantee)
      terminal_count = Enum.count(events, &InferenceEvent.terminal?/1)
      assert terminal_count == 1, "expected exactly 1 terminal, got #{terminal_count}"
    end

    test "caller disconnect triggers cancellation", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-disconnect")
      execute = execute_request("req-dispatch-disconnect")
      model_load = model_load_request(bundle)

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

      # Exactly one terminal event in the stream (Task 4 guarantee)
      terminal_count = Enum.count(events, &InferenceEvent.terminal?/1)
      assert terminal_count == 1, "expected exactly 1 terminal, got #{terminal_count}"

      # Clean up
      if Process.alive?(dispatch_pid), do: Process.exit(dispatch_pid, :kill)
    end

    test "dispatch returns sanitized error when node connection fails" do
      # Use a target that will fail to connect — port 1 is privileged and won't have a gRPC server
      schedule = %{
        strategy: :single_node,
        request_id: "req-connect-fail",
        runtime_client_target: [host: "127.0.0.1", port: 1],
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 5_000
      }

      execute = execute_request("req-connect-fail")

      model_load =
        %EnsureModelLoadedRequest{
          node_id: "local",
          model_id: "test/model",
          version: "v1"
        }

      assert {:error, {:model_load_failed, %ModelLoadFailure{} = failure}} =
               RequestDispatcher.dispatch(schedule, execute, model_load)

      assert failure.category == :runtime_unavailable
      assert failure.code == "node_unavailable"
      assert failure.message == "node runtime is unavailable"
    end

    test "dispatch returns error when ensure-load placement state is not LOADED" do
      schedule = build_schedule("req-dispatch-fail-load")

      execute =
        %ExecuteInferenceRequest{
          request_id: "req-dispatch-fail-load",
          controller_session_id: "controller-session-dispatch",
          model_id: "fail-load/test-model",
          version: "v1",
          rendered_prompt_utf8: "hello",
          input_tokens: 1
        }

      model_load =
        %EnsureModelLoadedRequest{
          node_id: "local",
          model_id: "fail-load/test-model",
          version: "v1"
        }

      assert {:error, {:model_load_failed, %ModelLoadFailure{} = failure}} =
               RequestDispatcher.dispatch(schedule, execute, model_load)

      assert failure.category in [
               :model_invalid,
               :acquisition_failed,
               :runtime_unavailable,
               :timeout,
               :resource_exhausted,
               :internal
             ]

      assert is_binary(failure.code) and failure.code != ""
      assert is_binary(failure.message) and failure.message != ""
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp model_load_request(bundle) do
    %EnsureModelLoadedRequest{
      node_id: "local",
      model_id: @model_id,
      version: @version,
      artifact_sha256: bundle.hash,
      artifact_source_uri: bundle.source_uri,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
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
      request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 5_000),
      model_load_timeout_ms: Keyword.get(opts, :model_load_timeout_ms, 5_000)
    }
  end

  defp score_prefix_cache_request(model_id, request_id) do
    %ScorePrefixCacheRequest{
      request_id: request_id,
      controller_session_id: "controller-session-dispatch",
      model_ref: %ModelRef{model_id: model_id, version: @version},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("0", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 500
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

  defp stage_test_bundle! do
    models_root = Node.models_root()
    cache_path = Path.join([models_root, @model_id, @version])
    source_path = Path.join([models_root, ".test-source", "bundle"])

    File.rm_rf(cache_path)
    File.rm_rf(source_path)

    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    File.mkdir_p!(cache_path)
    :ok = ArtifactBundle.copy_directory(source_path, cache_path)

    source_uri = "file://#{source_path}"

    %{cache_path: cache_path, source_path: source_path, source_uri: source_uri, hash: hash}
  end
end
