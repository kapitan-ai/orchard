defmodule OrchardNodeAgentTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.InferenceEvent
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{RuntimeRequirements, Tokenizer}
  alias Orchard.Node.SharedContract

  test "node agent version is exposed" do
    assert Orchard.NodeAgent.version() == "0.1.0"
  end

  test "node supervisor is already part of the started application tree" do
    pid = Process.whereis(Orchard.Node.Supervisor)

    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = Orchard.Node.Supervisor.start_link([])
  end

  test "node supervisor init returns a one_for_one strategy" do
    assert {:ok, {%{strategy: :one_for_one}, []}} = Orchard.Node.Supervisor.init([])
  end

  test "node agent application supervisor is running" do
    assert is_pid(Process.whereis(Orchard.NodeAgent.Supervisor))
  end

  test "node agent references the shared request, event, and manifest shapes" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })

    event = InferenceEvent.progress("loading", "warming model")

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
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
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
  end
end
