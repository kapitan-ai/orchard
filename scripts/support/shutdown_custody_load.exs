alias Orchard.ArtifactBundle
alias Orchard.Cluster.V1.EnsureModelLoadedRequest
alias Orchard.Cluster.V1.EnsureModelLoadedResponse
alias Orchard.Cluster.V1.NodeRuntimeService.Stub, as: NodeRuntimeStub

repo_root = Path.expand("../..", __DIR__)
model_id = "issue-286-shutdown-custody"
version = "v1"
bundle_path = Path.join([repo_root, "tmp", "dev", "models", model_id, version])

File.rm_rf!(bundle_path)
File.mkdir_p!(Path.join(bundle_path, "weights"))
File.write!(Path.join(bundle_path, "config.json"), ~s({"model_type":"test"}))
File.write!(Path.join(bundle_path, "tokenizer.json"), ~s({"version":"1.0"}))
File.write!(Path.join(bundle_path, "weights/model.safetensors"), "fake-weights-data")
{:ok, artifact_sha256} = ArtifactBundle.tree_sha256(bundle_path)

{:ok, _apps} = Application.ensure_all_started(:grpc)
port = System.fetch_env!("ORCHARD_NODE_AGENT_LISTEN_PORT")
{:ok, channel} = GRPC.Stub.connect("127.0.0.1:" <> port)

request = %EnsureModelLoadedRequest{
  node_id: "node-local",
  model_id: model_id,
  version: version,
  artifact_sha256: artifact_sha256,
  preload: true,
  deadline_unix_ms: System.system_time(:millisecond) + 30_000
}

result = NodeRuntimeStub.ensure_model_loaded(channel, request, timeout: 30_000)
_ = GRPC.Stub.disconnect(channel)

case result do
  {:ok, %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}} -> :ok
  other -> raise "shutdown custody load failed: #{inspect(other)}"
end
