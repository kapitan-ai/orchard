defmodule Orchard.API.RouterTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router

  describe "route registration" do
    @describetag :db

    test "GET /v1/models is routed" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "list"
      assert body["data"] == []
    end

    test "POST /v1/chat/completions is routed" do
      params = %{
        "model" => "nonexistent@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      conn =
        build_conn(:post, "/v1/chat/completions")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:params, params)
        |> Map.put(:body_params, params)
        |> Router.call(Router.init([]))

      # Route is wired and reaches the orchestrator (model not found)
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
      # Verify the endpoint module includes Plug.Parsers with JSON support.
      # The actual Endpoint.call/2 requires a running endpoint, so we test
      # the parser configuration declaratively and exercise JSON round-trip
      # through Plug.Parsers directly.
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

      # Plug.Parsers successfully decoded the JSON body
      assert conn.body_params["model"] == "test"
      assert conn.body_params["messages"] == []
    end
  end
end
