defmodule Orchard.API.EndpointRegressionTest do
  @moduledoc """
  Regression tests for endpoint-level behavior after LiveView additions.

  Ensures the API routes retain their security properties (JSON-only parsing,
  CORS preflight) when sharing the endpoint with the console browser pipeline.
  """

  use Orchard.ConnCase

  @moduletag :live
  @moduletag :db

  describe "API security after LiveView endpoint changes" do
    test "endpoint clears process-local Sentry context after completed requests", %{conn: conn} do
      Sentry.Context.set_extra_context(%{orchard_request_id: "stale-request"})

      conn = get(conn, "/health/live")

      assert conn.status == 200
      assert Sentry.Context.get_all().extra == %{}
      assert Sentry.Context.get_all().breadcrumbs == []
    end

    test "POST /v1/chat/completions still returns 401 for unauthenticated form-urlencoded input",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/v1/chat/completions", "model=test&messages=hello")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "POST /v1/responses still returns 401 for unauthenticated form-urlencoded input",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/v1/responses", "model=test&input=hello")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "authenticated form-urlencoded API input remains invalid", %{conn: conn} do
      {:ok, tenant} =
        Orchard.Governance.create_tenant(%{
          slug: "form-api-#{System.unique_integer([:positive])}",
          name: "Form API"
        })

      {:ok, %{token: token}} =
        Orchard.Governance.create_api_key(tenant.id, %{name: "Form API key"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/v1/responses", "model=nonexistent%40v1&input=hello")

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
    end

    test "authenticated form-urlencoded chat input remains invalid", %{conn: conn} do
      {:ok, tenant} =
        Orchard.Governance.create_tenant(%{
          slug: "form-chat-#{System.unique_integer([:positive])}",
          name: "Form Chat"
        })

      {:ok, %{token: token}} =
        Orchard.Governance.create_api_key(tenant.id, %{name: "Form chat key"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/v1/chat/completions", "model=nonexistent%40v1&messages=hello")

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "invalid_value"
    end

    test "health endpoint still responds through modified endpoint", %{conn: conn} do
      conn = get(conn, "/health/live")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"
    end

    test "/console returns HTML, not JSON", %{conn: conn} do
      conn = get(conn, "/console")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    end
  end
end
