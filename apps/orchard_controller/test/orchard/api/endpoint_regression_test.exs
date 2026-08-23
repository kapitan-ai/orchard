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

    test "streaming chat request accepts text/event-stream through the endpoint", %{conn: conn} do
      token = create_api_token!("streaming-chat-accept")

      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/v1/chat/completions", %{
          "model" => "nonexistent@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "model_not_found"
    end

    test "streaming responses request accepts text/event-stream through the endpoint", %{
      conn: conn
    } do
      token = create_api_token!("streaming-responses-accept")

      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/v1/responses", %{
          "model" => "nonexistent@v1",
          "input" => "hello",
          "stream" => true
        })

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "model_not_found"
    end

    test "inference endpoints return an OpenAI 406 for unsupported Accept media types", %{
      conn: conn
    } do
      token = create_api_token!("unsupported-inference-accept")

      for {path, params} <- [
            {"/v1/chat/completions",
             %{
               "model" => "nonexistent@v1",
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "stream" => true
             }},
            {"/v1/responses",
             %{"model" => "nonexistent@v1", "input" => "hello", "stream" => true}}
          ] do
        response =
          conn
          |> put_req_header("accept", "application/xml")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer #{token}")
          |> post(path, params)

        assert response.status == 406
        assert get_resp_header(response, "content-type") |> hd() =~ "application/json"

        assert Jason.decode!(response.resp_body)["error"] == %{
                 "message" => "No acceptable response media type was requested",
                 "type" => "invalid_request_error",
                 "param" => nil,
                 "code" => "not_acceptable"
               }
      end
    end

    test "non-streaming inference rejects text/event-stream without a JSON alternative", %{
      conn: conn
    } do
      token = create_api_token!("non-streaming-event-stream-accept")

      for {path, params} <- [
            {"/v1/chat/completions",
             %{
               "model" => "nonexistent@v1",
               "messages" => [%{"role" => "user", "content" => "hello"}]
             }},
            {"/v1/responses", %{"model" => "nonexistent@v1", "input" => "hello"}}
          ] do
        response =
          conn
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer #{token}")
          |> post(path, params)

        assert response.status == 406
        assert Jason.decode!(response.resp_body)["error"]["code"] == "not_acceptable"
      end
    end

    test "inference Accept wildcards and zero quality remain stream-aware", %{conn: conn} do
      token = create_api_token!("inference-accept-ranges")

      for {path, base_params} <- [
            {"/v1/chat/completions",
             %{
               "model" => "nonexistent@v1",
               "messages" => [%{"role" => "user", "content" => "hello"}]
             }},
            {"/v1/responses", %{"model" => "nonexistent@v1", "input" => "hello"}}
          ],
          {accept, stream?, expected_status} <- [
            {"*/*", false, 404},
            {"text/*", true, 404},
            {"text/*", false, 406},
            {"application/json;q=0", false, 406}
          ] do
        params = if stream?, do: Map.put(base_params, "stream", true), else: base_params

        response =
          conn
          |> put_req_header("accept", accept)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer #{token}")
          |> post(path, params)

        assert response.status == expected_status
      end
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

  defp create_api_token!(slug) do
    {:ok, tenant} =
      Orchard.Governance.create_tenant(%{
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        name: slug
      })

    {:ok, %{token: token}} =
      Orchard.Governance.create_api_key(tenant.id, %{name: "#{slug} key"})

    token
  end
end
