defmodule OrchardTest do
  use ExUnit.Case, async: true

  alias Orchard.API.ErrorJSON
  alias Orchard.API.Readiness
  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.InferenceContract
  alias Orchard.InferenceEvent
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{RuntimeRequirements, Tokenizer}
  alias Orchard.Release

  test "controller version is exposed" do
    assert Orchard.version() == "0.1.0"
  end

  test "readiness and release helpers fail closed when repo-backed db checks are disabled" do
    assert {:error, :postgres_reachable, _checks} = Readiness.status()
    refute Release.migrations_current?()
  end

  test "error json renders standard status messages" do
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "controller references the shared request, event, and manifest shapes" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })

    event = InferenceEvent.output_text_delta("hello")

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

    assert InferenceContract.request_model_ref(request).model_id == "mlx-community/phi-3"
    assert InferenceContract.event_kind(event) == :output_text_delta
    assert %Orchard.Cluster.V1.ModelRef{} = InferenceContract.manifest_proto_model_ref(manifest)
  end
end
