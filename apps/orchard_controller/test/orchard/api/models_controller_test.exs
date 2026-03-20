defmodule Orchard.API.ModelsControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Models

  describe "GET /v1/models" do
    @describetag :db

    test "SPEC.md §7.2.7 returns 401 when bearer auth is missing" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "returns empty list when no models exist" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{default_api_token!()}")
        |> Router.call(Router.init([]))

      body = Jason.decode!(conn.resp_body)
      assert conn.status == 200
      assert body["object"] == "list"
      assert body["data"] == []
    end

    test "returns OpenAI-shaped model objects for active models" do
      {:ok, _model} =
        Models.create_model(%{
          model_id: "llama-3.1-8b-instruct",
          version: "mlx-q4-v1",
          state: :active,
          format: "mlx",
          capabilities: ["chat"],
          artifact_uri: "file:///models/llama-3.1-8b",
          artifact_sha256: "abc123",
          artifact_size_bytes: 1000,
          resident_memory_bytes: 2000,
          kv_cache_bytes_per_token: 32,
          prefill_workspace_bytes_per_token: 64,
          max_context_tokens: 8192,
          tokenizer: %{"type" => "huggingface_tokenizer_json"},
          runtime_requirements: %{"backend" => "mlx"}
        })

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{default_api_token!()}")
        |> Router.call(Router.init([]))

      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "list"
      assert length(body["data"]) == 1

      [model_obj] = body["data"]
      assert model_obj["id"] == "llama-3.1-8b-instruct@mlx-q4-v1"
      assert model_obj["object"] == "model"
      assert is_integer(model_obj["created"])
      assert model_obj["owned_by"] == "local"

      refute Map.has_key?(model_obj, "artifact_source_uri")
      refute Map.has_key?(model_obj, "artifact_uri")
      refute Map.has_key?(model_obj, "artifact_sha256")
    end

    test "excludes non-active models" do
      {:ok, _} =
        Models.create_model(%{
          model_id: "retired-model",
          version: "v1",
          state: :retired,
          format: "mlx",
          capabilities: ["chat"],
          artifact_uri: "file:///models/retired",
          artifact_sha256: "def456",
          artifact_size_bytes: 500,
          resident_memory_bytes: 1000,
          kv_cache_bytes_per_token: 16,
          prefill_workspace_bytes_per_token: 32,
          max_context_tokens: 4096,
          tokenizer: %{"type" => "sentencepiece"},
          runtime_requirements: %{"backend" => "mlx"}
        })

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{default_api_token!()}")
        |> Router.call(Router.init([]))

      body = Jason.decode!(conn.resp_body)
      assert body["data"] == []
    end
  end

  defp default_api_token! do
    slug = "models-auth-#{System.unique_integer([:positive])}"
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Primary"})
    token
  end
end
