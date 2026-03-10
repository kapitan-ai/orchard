defmodule Orchard.API.ChatCompletionsControllerTest do
  use Orchard.ConnCase, async: false

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
      conn = post_chat(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["param"] == "model"
      assert body["error"]["code"] == "missing_required_field"
      assert body["error"]["message"] =~ "model"
    end

    test "rejects request missing messages field with OpenAI error envelope" do
      conn = post_chat(%{"model" => "test-model@v1"})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["param"] == "messages"
      assert body["error"]["code"] == "missing_required_field"
    end

    @tag :db
    test "returns model_not_found for valid request with unknown model" do
      # No models are imported, so this should return 404
      conn =
        post_chat(%{
          "model" => "nonexistent@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
      assert body["error"]["param"] == "model"
    end

    test "rejects unsupported parameter" do
      conn =
        post_chat(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "logprobs" => true
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unsupported_parameter"
    end

    test "error envelope always has message, type, param, code keys" do
      conn = post_chat(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      body = Jason.decode!(conn.resp_body)
      error = body["error"]
      assert Map.has_key?(error, "message")
      assert Map.has_key?(error, "type")
      assert Map.has_key?(error, "param")
      assert Map.has_key?(error, "code")
    end
  end
end
