defmodule Orchard.API.ChatCompletionsControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router
  alias Orchard.Inference.ChatRequestNormalizer

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

  # Parse SSE response body into a list of parsed events.
  # Returns [{:data, decoded_map}, {:done, nil}, {:error, decoded_map}]
  defp parse_sse_body(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_sse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_sse_line("data: [DONE]"), do: {:done, nil}

  defp parse_sse_line("data: " <> json) do
    decoded = Jason.decode!(json)

    if Map.has_key?(decoded, "error") do
      {:error, decoded}
    else
      {:data, decoded}
    end
  end

  defp parse_sse_line(_), do: nil

  describe "POST /v1/chat/completions (non-streaming)" do
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

  describe "POST /v1/chat/completions (streaming pre-stream errors)" do
    test "stream=true with missing model returns JSON error, not SSE" do
      conn =
        post_chat(%{
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      # Pre-stream validation errors are returned as normal JSON, not SSE
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "missing_required_field"
      assert body["error"]["param"] == "model"
      # Verify it's NOT SSE
      refute get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))
    end

    test "stream=true with unsupported parameter returns JSON error, not SSE" do
      conn =
        post_chat(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true,
          "logprobs" => true
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unsupported_parameter"

      refute get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))
    end

    @tag :db
    test "stream=true with unknown model returns JSON 404, not SSE" do
      conn =
        post_chat(%{
          "model" => "nonexistent@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "model_not_found"

      refute get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))
    end
  end

  describe "POST /v1/chat/completions (streaming happy path)" do
    @tag :db
    test "stream=true with valid model emits SSE chunks then [DONE]" do
      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "test-stream-model",
          version: "v1",
          display_name: "Test Stream Model",
          artifact_uri: "file:///tmp/test-stream-model",
          artifact_sha256: "abc123",
          state: :active,
          format: "mlx",
          backend: "mlx",
          capabilities: ["chat"],
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 128,
          prefill_workspace_bytes_per_token: 64,
          max_context_tokens: 4096
        })

      conn =
        post_chat(%{
          "model" => "test-stream-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      # SSE started (chunked 200)
      assert conn.status == 200

      assert get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))

      # Parse SSE body
      events = parse_sse_body(conn.resp_body)

      # Should have data chunks followed by [DONE]
      data_events = Enum.filter(events, fn {type, _} -> type == :data end)
      done_events = Enum.filter(events, fn {type, _} -> type == :done end)

      # At least: role chunk + content chunk(s) + finish chunk
      assert length(data_events) >= 3

      # First chunk should be the role marker
      {:data, first_chunk} = List.first(data_events)
      assert first_chunk["object"] == "chat.completion.chunk"
      assert first_chunk["model"] == "test-stream-model@v1"
      [first_choice] = first_chunk["choices"]
      assert first_choice["delta"]["role"] == "assistant"

      # Last data chunk should have a finish_reason
      {:data, last_chunk} = List.last(data_events)
      [last_choice] = last_chunk["choices"]
      assert last_choice["finish_reason"] != nil

      # Stream ends with [DONE]
      assert done_events == [{:done, nil}]

      # No error events
      error_events = Enum.filter(events, fn {type, _} -> type == :error end)
      assert error_events == []
    end
  end

  describe "stream_options.include_usage normalization" do
    test "stream_include_usage defaults to false" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true
        })

      assert canonical.stream? == true
      assert canonical.stream_include_usage == false
    end

    test "stream_include_usage is true when stream_options.include_usage is true" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true,
          "stream_options" => %{"include_usage" => true}
        })

      assert canonical.stream? == true
      assert canonical.stream_include_usage == true
    end

    test "stream_include_usage is false for non-boolean include_usage" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true,
          "stream_options" => %{"include_usage" => "yes"}
        })

      assert canonical.stream_include_usage == false
    end
  end
end
