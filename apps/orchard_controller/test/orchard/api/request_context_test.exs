defmodule Orchard.API.RequestContextTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.RequestContext
  alias Orchard.API.Router
  alias Orchard.Inference.ChatRequestNormalizer

  describe "RequestContext plug" do
    test "assigns default tenant_id in M1 mode" do
      conn =
        build_conn(:get, "/v1/models")
        |> RequestContext.call([])

      assert conn.assigns[:tenant_id] == "00000000-0000-0000-0000-000000000000"
    end

    test "assigns nil principal_id and api_key_id in M1 mode" do
      conn =
        build_conn(:get, "/v1/models")
        |> RequestContext.call([])

      assert conn.assigns[:principal_id] == nil
      assert conn.assigns[:api_key_id] == nil
    end

    @tag :db
    test "/v1 routes have caller context assigned via pipeline" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> Router.call(Router.init([]))

      # The request context plug runs in the :authenticated_api pipeline,
      # so assigns should be present after routing
      assert conn.assigns[:tenant_id] == "00000000-0000-0000-0000-000000000000"
      assert conn.assigns[:principal_id] == nil
      assert conn.assigns[:api_key_id] == nil
    end

    test "health routes do NOT have caller context assigned" do
      conn =
        build_conn(:get, "/health/live")
        |> Router.call(Router.init([]))

      # Health routes use :api pipeline, not :authenticated_api
      refute Map.has_key?(conn.assigns, :tenant_id)
    end
  end

  describe "caller context flows through to orchestrator" do
    test "normalizer receives tenant_id from caller context" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(
          %{
            "model" => "test@v1",
            "messages" => [%{"role" => "user", "content" => "hi"}]
          },
          tenant_id: "custom-tenant",
          principal_id: "principal-123",
          api_key_id: "key-456"
        )

      assert canonical.tenant_id == "custom-tenant"
      assert canonical.principal_id == "principal-123"
      assert canonical.api_key_id == "key-456"
    end

    test "normalizer uses defaults when caller context is empty" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert canonical.tenant_id == "00000000-0000-0000-0000-000000000000"
      assert canonical.principal_id == nil
      assert canonical.api_key_id == nil
    end
  end
end
