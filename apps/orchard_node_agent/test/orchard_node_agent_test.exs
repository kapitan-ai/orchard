defmodule OrchardNodeAgentTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef, as: CanonicalModelRef
  alias Orchard.Cluster.V1.Accepted
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.Completed
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.Cluster.V1.InferenceEvent, as: RPCInferenceEvent
  alias Orchard.Cluster.V1.ModelRef, as: RPCModelRef
  alias Orchard.Cluster.V1.NodeRuntimeService.Stub, as: NodeRuntimeStub
  alias Orchard.Cluster.V1.StatusRequest
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.TokenUsage
  alias Orchard.InferenceEvent, as: OrchardInferenceEvent
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.RuntimeRequirements
  alias Orchard.ModelManifest.Tokenizer
  alias Orchard.Node
  alias Orchard.Node.SharedContract
  alias Orchard.Node.Status, as: NodeStatus
  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.NodeAgent.Supervisor, as: NodeAgentSupervisor

  setup do
    :ok = NodeStatus.reset()
    :ok
  end

  test "node agent version is exposed" do
    assert Orchard.NodeAgent.version() == "0.1.0"
  end

  test "node supervisor is already part of the started application tree" do
    pid = Process.whereis(NodeSupervisor)

    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = NodeSupervisor.start_link([])
  end

  test "node supervisor boots status tracking and the gRPC server child" do
    assert is_pid(Process.whereis(NodeSupervisor))
    assert is_pid(Process.whereis(NodeStatus))

    child_ids =
      Supervisor.which_children(NodeSupervisor)
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert NodeSupervisor.grpc_server_id() in child_ids
    assert NodeStatus in child_ids
  end

  test "node agent application supervisor is running" do
    assert is_pid(Process.whereis(NodeAgentSupervisor))
  end

  test "node agent references the shared request, event, and manifest shapes" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: %CanonicalModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })

    event = OrchardInferenceEvent.progress("loading", "warming model")

    manifest =
      ModelManifest.new(%{
        model_id: "mlx-community/phi-3",
        version: "main",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{
          adapter: "mlx_lm",
          min_agent_capability: "mlx"
        }
      })

    assert request.endpoint == :responses
    assert SharedContract.request_model_ref(request).model_id == "mlx-community/phi-3"
    assert SharedContract.event_kind(event) == :progress
    assert %Orchard.Cluster.V1.ModelRef{} = SharedContract.manifest_proto_model_ref(manifest)
  end

  test "test environment config uses fake runtime and local worker paths" do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    assert runtime[:fake_runtime?]
    assert runtime[:listen_address] == [host: "127.0.0.1", port: 50_071]
    assert Path.type(runtime[:models_root]) == :absolute
    assert Path.type(runtime[:worker_socket_dir]) == :absolute
    assert String.ends_with?(runtime[:models_root], "/tmp/test/models")
    assert String.ends_with?(runtime[:worker_socket_dir], "/tmp/test/data/worker-sockets")

    assert Node.listen_host() == "127.0.0.1"
    assert Node.listen_port() == 50_071
    assert Node.fake_runtime?()
  end

  test "get_status responds over gRPC" do
    with_channel(fn channel ->
      assert {:ok, %StatusResponse{} = response} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert response.worker_state == :WORKER_STATE_IDLE
      assert response.loaded_models == []
      assert response.active_request_count == 0
    end)
  end

  test "ensure_model_loaded is accepted and reflected in status" do
    request = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: "mlx-community/phi-3",
      version: "main",
      artifact_sha256: "sha256:test",
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }

    with_channel(fn channel ->
      assert {:ok,
              %EnsureModelLoadedResponse{
                already_loaded: false,
                placement_state: :PLACEMENT_STATE_LOADED
              }} = NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %EnsureModelLoadedResponse{already_loaded: true}} =
               NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %StatusResponse{loaded_models: [%RPCModelRef{} = loaded_model]}} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert loaded_model.model_id == "mlx-community/phi-3"
      assert loaded_model.version == "main"
    end)
  end

  test "execute_inference streams accepted and terminal contract events" do
    request = %ExecuteInferenceRequest{
      request_id: "req-r2-execute",
      controller_session_id: "controller-session-1",
      model_id: "mlx-community/phi-3",
      version: "main",
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2,
      params: %GenerationParams{max_output_tokens: 16},
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      metadata_json: ~s({"source":"test"})
    }

    with_channel(fn channel ->
      assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request)

      assert [
               {:ok,
                %RPCInferenceEvent{
                  event: {:accepted, %Accepted{accepted_at_unix_ms: accepted_at}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event:
                    {:completed,
                     %Completed{
                       finish_reason: :FINISH_REASON_STOP,
                       usage: %TokenUsage{input_tokens: 2, output_tokens: 0, total_tokens: 2}
                     }}
                }}
             ] = Enum.to_list(event_stream)

      assert is_integer(accepted_at)
      assert accepted_at > 0

      assert {:ok, %StatusResponse{active_request_count: 0}} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})
    end)
  end

  test "cancel_inference is accepted over gRPC" do
    with_channel(fn channel ->
      request = %CancelInferenceRequest{
        request_id: "req-r2-cancel",
        controller_session_id: "controller-session-2"
      }

      assert {:ok, %{ok: true, message: "cancel accepted"}} =
               NodeRuntimeStub.cancel_inference(channel, request)
    end)
  end

  defp with_channel(fun) when is_function(fun, 1) do
    target = "#{Node.listen_host()}:#{Node.listen_port()}"

    {:ok, channel} = GRPC.Stub.connect(target)

    try do
      fun.(channel)
    after
      _ = GRPC.Stub.disconnect(channel)
    end
  end
end
