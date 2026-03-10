defmodule Orchard.API.ChatCompletionsControllerTest do
  use Orchard.ConnCase, async: true

  alias Orchard.API.Router

  # When testing through Router.call/2 directly (not the Endpoint),
  # Plug.Parsers does not run, so body_params are not merged into params.
  # We simulate the merge explicitly.
  defp post_chat(params) do
    build_conn(:post, "/v1/chat/completions")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> Router.call(Router.init([]))
  end

  describe "POST /v1/chat/completions" do
    test "rejects request missing model field with OpenAI error envelope" do
      conn = post_chat(%{"messages" => []})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["param"] == "model"
      assert body["error"]["code"] == "missing_required_field"
      assert body["error"]["message"] =~ "model"
    end

    test "rejects request missing messages field with OpenAI error envelope" do
      conn = post_chat(%{"model" => "test-model"})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["param"] == "messages"
      assert body["error"]["code"] == "missing_required_field"
    end

    test "returns not-implemented for valid request shape" do
      conn = post_chat(%{"model" => "test-model", "messages" => []})

      # Stub returns 501 until dispatch is wired in A4
      assert conn.status == 501
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "api_error"
      assert body["error"]["code"] == "not_implemented"
    end

    test "error envelope always has message, type, param, code keys" do
      conn = post_chat(%{})

      body = Jason.decode!(conn.resp_body)
      error = body["error"]
      assert Map.has_key?(error, "message")
      assert Map.has_key?(error, "type")
      assert Map.has_key?(error, "param")
      assert Map.has_key?(error, "code")
    end
  end
end
