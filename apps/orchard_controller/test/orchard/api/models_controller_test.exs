defmodule Orchard.API.ModelsControllerTest do
  use Orchard.ConnCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Models.Access

  describe "GET /v1/models" do
    @describetag :db

    test "SPEC.md §7.2.7 returns 401 when bearer auth is missing" do
      conn = request_models(nil)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "SPEC.md §7.2.3 returns empty list when the Tenant has no authorized active Models" do
      %{token: token} = create_direct_token!("models-empty")
      _ungranted = create_model!(%{state: :active})

      conn = request_models(token)
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert body == %{"object" => "list", "data" => []}
    end

    test "SPEC.md §7.2.3 returns OpenAI-shaped objects only for active granted Models" do
      %{tenant: tenant, token: token} = create_direct_token!("models-granted")

      model =
        create_model!(%{
          model_id: "llama-3.1-8b-instruct",
          version: "mlx-q4-v1",
          state: :active,
          artifact_uri: "file:///models/llama-3.1-8b"
        })

      assert {:ok, %{outcome: :created}} = Access.grant_model_access(tenant, model)

      conn = request_models(token)
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
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

    test "SPEC.md §7.2.3 excludes inactive, disabled, revoked, ungranted, and other-Tenant Models" do
      %{tenant: tenant, token: token} = create_direct_token!("models-scope-a")
      %{tenant: other_tenant, token: other_token} = create_direct_token!("models-scope-b")

      visible = create_model!(%{state: :active})
      inactive = create_model!(%{state: :retired})
      disabled = create_model!(%{state: :active})
      revoked = create_model!(%{state: :active})
      _ungranted = create_model!(%{state: :active})

      assert {:ok, _result} = Access.grant_model_access(tenant, visible)
      assert {:ok, _result} = Access.grant_model_access(tenant, inactive)
      assert {:ok, _result} = Access.grant_model_access(tenant, disabled)
      assert {:ok, _result} = Access.disable_model_access(tenant, disabled)
      assert {:ok, _result} = Access.grant_model_access(tenant, revoked)
      assert {:ok, _result} = Access.revoke_model_access(tenant, revoked)
      assert {:ok, _result} = Access.grant_model_access(other_tenant, disabled)

      assert model_ids(request_models(token)) == ["#{visible.model_id}@#{visible.version}"]

      assert model_ids(request_models(other_token)) == [
               "#{disabled.model_id}@#{disabled.version}"
             ]
    end

    test "SPEC.md §5.2 uses the same effective Tenant for direct and Service Account credentials" do
      %{tenant: tenant, token: direct_token} = create_direct_token!("models-principals")
      service_token = create_service_account_token!(tenant)
      model = create_model!(%{state: :active})

      assert {:ok, _result} = Access.grant_model_access(tenant, model)

      expected = ["#{model.model_id}@#{model.version}"]
      assert model_ids(request_models(direct_token)) == expected
      assert model_ids(request_models(service_token)) == expected
    end
  end

  defp request_models(nil) do
    build_conn(:get, "/v1/models")
    |> put_req_header("accept", "application/json")
    |> Router.call(Router.init([]))
  end

  defp request_models(token) do
    build_conn(:get, "/v1/models")
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(Router.init([]))
  end

  defp model_ids(conn) do
    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("data")
    |> Enum.map(&Map.fetch!(&1, "id"))
  end

  defp create_direct_token!(prefix) do
    slug = unique_slug(prefix)
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Primary"})
    %{tenant: tenant, token: token}
  end

  defp create_service_account_token!(tenant) do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "models-client-#{System.unique_integer([:positive])}",
        owner_contact: "owner@example.com"
      })

    {:ok, _role_binding} = Governance.ensure_inference_client_access(api_client, tenant)

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    token
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
