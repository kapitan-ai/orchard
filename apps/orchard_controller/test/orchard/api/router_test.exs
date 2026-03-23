defmodule Orchard.API.RouterTest do
  use Orchard.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Repo

  describe "route registration" do
    @describetag :db

    test "GET /v1/models requires bearer auth" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "GET /v1/models is routed for authenticated callers" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{default_api_token!()}")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "list"
      assert body["data"] == []
    end

    test "POST /v1/chat/completions is routed for authenticated callers" do
      params = %{
        "model" => "nonexistent@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      conn =
        build_conn(:post, "/v1/chat/completions")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{default_api_token!()}")
        |> Map.put(:params, params)
        |> Map.put(:body_params, params)
        |> Router.call(Router.init([]))

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
    end

    test "POST /v1/responses requires bearer auth" do
      conn =
        build_conn(:post, "/v1/responses")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:params, %{"model" => "test@v1", "input" => "hello"})
        |> Map.put(:body_params, %{"model" => "test@v1", "input" => "hello"})
        |> Router.call(Router.init([]))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "POST /v1/responses is routed for authenticated callers" do
      params = %{"model" => "nonexistent@v1", "input" => "hello"}

      conn =
        build_conn(:post, "/v1/responses")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{default_api_token!()}")
        |> Map.put(:params, params)
        |> Map.put(:body_params, params)
        |> Router.call(Router.init([]))

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
    end

    test "health endpoints still work" do
      conn =
        build_conn(:get, "/health/live")
        |> put_req_header("accept", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"
    end
  end

  describe "JSON body parsing" do
    test "Plug.Parsers is configured for JSON on the endpoint" do
      body = Jason.encode!(%{model: "test", messages: []})

      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", body)
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(
          Plug.Parsers.init(
            parsers: [:json],
            pass: ["application/json"],
            json_decoder: Jason
          )
        )

      assert conn.body_params["model"] == "test"
      assert conn.body_params["messages"] == []
    end
  end

  describe "console LiveView routes" do
    @describetag :live
    @describetag :db

    setup do
      Sandbox.mode(Repo, {:shared, self()})
      :ok
    end

    test "GET /console/playground is routed", %{conn: conn} do
      conn = get(conn, "/console/playground")

      assert conn.status == 200
      assert conn.resp_body =~ "Playground"
      assert conn.resp_body =~ "playground-form"
    end

    test "GET /console/requests/:public_id is routed", %{conn: conn} do
      conn = get(conn, "/console/requests/req_router_test")

      assert conn.status == 200
      assert conn.resp_body =~ "req_router_test"
      assert conn.resp_body =~ "request-loading-card"
    end

    test "GET /console/models is routed", %{conn: conn} do
      conn = get(conn, "/console/models")

      assert conn.status == 200
      assert conn.resp_body =~ "Model Catalog"
    end

    test "GET /console/model-hub is routed", %{conn: conn} do
      conn = get(conn, "/console/model-hub")

      assert conn.status == 200
      assert conn.resp_body =~ "Model Hub"
      assert conn.resp_body =~ "model-hub-search-card"
      assert conn.resp_body =~ "model-hub-search-form"
      assert conn.resp_body =~ "Read-only in B1. Download and import are deferred to B2/B3."
    end

    test "GET /console/tenants is routed", %{conn: conn} do
      conn = get(conn, "/console/tenants")

      assert conn.status == 200
      assert conn.resp_body =~ "Tenants"
    end

    test "GET /console/tenants/:id is routed", %{conn: conn} do
      conn = get(conn, "/console/tenants/#{Orchard.Governance.legacy_tenant_id()}")

      assert conn.status == 200
      assert conn.resp_body =~ "Tenant"
    end
  end

  defp default_api_token! do
    slug = "router-auth-#{System.unique_integer([:positive])}"
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Primary"})
    token
  end
end
