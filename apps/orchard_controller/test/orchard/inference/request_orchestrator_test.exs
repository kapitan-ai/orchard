defmodule Orchard.Inference.RequestOrchestratorTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.ArtifactBundle
  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestrator
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Requests
  alias Orchard.Requests.Idempotency

  setup do
    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      Enum.each(bundle.cache_paths, &File.rm_rf/1)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

  test "execute/3 persists canonical endpoint instead of hardcoding chat", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-endpoint")

    canonical =
      canonical_request("request-orchestrator-endpoint", endpoint: :responses, stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.endpoint == :responses
    assert request.canonical_request["endpoint"] == "responses"
  end

  test "execute/3 persists success payload attrs for completed non-stream requests", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-success")
    canonical = canonical_request("request-orchestrator-success", stream?: false)

    success_persistence = fn canonical_request, events ->
      %{
        response_payload: %{id: canonical_request.public_id},
        response_preview: joined_preview(events)
      }
    end

    assert {:ok, ^canonical, _events} =
             RequestOrchestrator.execute(canonical, model,
               success_persistence: success_persistence
             )

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :completed
    assert request.response_payload == %{"id" => canonical.public_id}
    assert request.response_preview != nil
  end

  test "execute/3 skips success payload persistence for streaming requests", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-stream")
    canonical = canonical_request("request-orchestrator-stream", stream?: true)

    success_persistence = fn canonical_request, _events ->
      %{
        response_payload: %{id: canonical_request.public_id},
        response_preview: "should-not-persist"
      }
    end

    assert {:ok, ^canonical, _events} =
             RequestOrchestrator.execute(canonical, model,
               success_persistence: success_persistence
             )

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.stream == true
    assert request.response_payload == nil
    assert request.response_preview == nil
  end

  test "execute/3 returns an error before insert when canonical serialization fails", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-serialization")

    canonical =
      canonical_request("request-orchestrator-serialization",
        stream?: false,
        metadata: %{bad: %URI{scheme: "file", path: "/tmp/test"}}
      )

    assert {:error, {:canonical_request_serialization_failed, _message}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 replays an existing completed request after idempotency insert conflict", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-idem-replay")
    tenant_id = Ecto.UUID.generate()
    key = "req-orch-replay"
    params = %{"model" => "request-orchestrator-idem-replay@v1"}
    {:ok, idempotency} = Idempotency.build_context(tenant_id, key, params)

    existing =
      create_request!(%{
        public_id: "req_existing_replay",
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: idempotency.body_hash,
        stream: false,
        state: :completed,
        requested_model: "request-orchestrator-idem-replay@v1",
        response_payload: %{"id" => "req_existing_replay"}
      })

    existing_id = existing.id

    canonical =
      canonical_request("request-orchestrator-idem-replay",
        tenant_id: tenant_id,
        public_id: "req_new_replay"
      )

    assert {:replay, %{id: ^existing_id}} =
             RequestOrchestrator.execute(canonical, model, idempotency: idempotency)

    assert length(Orchard.Repo.all(Orchard.Requests.Request)) == 1
  end

  test "execute/3 returns idempotency conflict after insert race with active request", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-idem-active")
    tenant_id = Ecto.UUID.generate()
    key = "req-orch-active"
    params = %{"model" => "request-orchestrator-idem-active@v1"}
    {:ok, idempotency} = Idempotency.build_context(tenant_id, key, params)

    create_request!(%{
      public_id: "req_existing_active",
      tenant_id: tenant_id,
      idempotency_key: key,
      body_hash: idempotency.body_hash,
      state: :running,
      requested_model: "request-orchestrator-idem-active@v1"
    })

    canonical =
      canonical_request("request-orchestrator-idem-active",
        tenant_id: tenant_id,
        public_id: "req_new_active"
      )

    assert {:error, {:idempotency_conflict, :request_in_progress}} =
             RequestOrchestrator.execute(canonical, model, idempotency: idempotency)

    assert length(Orchard.Repo.all(Orchard.Requests.Request)) == 1
  end

  defp canonical_request(model_id, overrides) do
    endpoint = Keyword.get(overrides, :endpoint, :chat_completions)
    stream? = Keyword.get(overrides, :stream?, false)
    metadata = Keyword.get(overrides, :metadata, %{})
    tenant_id = Keyword.get(overrides, :tenant_id, Ecto.UUID.generate())
    public_id = Keyword.get(overrides, :public_id, "req_#{System.unique_integer([:positive])}")

    CanonicalRequest.new(%{
      internal_id: Ecto.UUID.generate(),
      public_id: public_id,
      endpoint: endpoint,
      tenant_id: tenant_id,
      api_key_id: Ecto.UUID.generate(),
      model_ref: %{model_id: model_id, version: "v1"},
      input_items: [%{"role" => "user", "content" => "hello"}],
      rendered_prompt: "hello",
      input_token_count: 1,
      stream?: stream?,
      sampling: %{temperature: 1.0, top_p: 1.0, stop: []},
      response_format: %{type: :text},
      metadata: metadata
    })
  end

  defp joined_preview(events) do
    events
    |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
    |> Enum.map_join("", & &1.event.delta)
  end

  defp create_active_model!(bundle, model_id) do
    {:ok, model} =
      Orchard.Models.create_model(%{
        model_id: model_id,
        version: "v1",
        display_name: model_id,
        artifact_uri: "file:///tmp/#{model_id}",
        artifact_sha256: bundle.hash,
        state: :active,
        format: "mlx",
        backend: "mlx",
        capabilities: ["chat"],
        artifact_size_bytes: 1024,
        resident_memory_bytes: 2048,
        kv_cache_bytes_per_token: 128,
        prefill_workspace_bytes_per_token: 64,
        max_context_tokens: 131_072
      })

    model
  end

  defp stage_test_bundle! do
    models_root = Node.models_root()
    source_path = Path.join([models_root, ".test-source", "request-orchestrator-bundle"])

    File.rm_rf(source_path)
    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    model_ids = [
      {"request-orchestrator-endpoint", "v1"},
      {"request-orchestrator-success", "v1"},
      {"request-orchestrator-stream", "v1"},
      {"request-orchestrator-serialization", "v1"},
      {"request-orchestrator-start-failure", "v1"},
      {"request-orchestrator-idem-replay", "v1"},
      {"request-orchestrator-idem-active", "v1"}
    ]

    cache_paths =
      Enum.map(model_ids, fn {model_id, version} ->
        cache_path = Path.join([models_root, model_id, version])
        File.rm_rf(cache_path)
        File.mkdir_p!(cache_path)
        :ok = ArtifactBundle.copy_directory(source_path, cache_path)
        cache_path
      end)

    %{hash: hash, source_path: source_path, cache_paths: cache_paths}
  end
end
