defmodule Orchard.API.ChatCompletionsControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.API.Router
  alias Orchard.Inference.ChatRequestNormalizer
  alias Orchard.Node
  alias Orchard.Node.ModelManager

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

  setup do
    # Reset node-agent state and stage a test bundle so model acquisition
    # succeeds for any model_id when the bundle is pre-cached.
    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      Enum.each(bundle.cache_paths, &File.rm_rf/1)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

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
    test "stream=true with valid model emits SSE chunks then [DONE]", %{bundle: bundle} do
      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "test-stream-model",
          version: "v1",
          display_name: "Test Stream Model",
          artifact_uri: "file:///tmp/test-stream-model",
          artifact_sha256: bundle.hash,
          state: :active,
          format: "mlx",
          backend: "mlx",
          capabilities: ["chat"],
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 128,
          prefill_workspace_bytes_per_token: 64,
          max_context_tokens: 131_072
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

  describe "POST /v1/chat/completions (streaming persistence, T4)" do
    @tag :db
    test "streaming request persists request row and state events", %{bundle: bundle} do
      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "persist-model",
          version: "v1",
          display_name: "Persist Model",
          artifact_uri: "file:///tmp/persist-model",
          artifact_sha256: bundle.hash,
          state: :active,
          format: "mlx",
          backend: "mlx",
          capabilities: ["chat"],
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 128,
          prefill_workspace_bytes_per_token: 64,
          max_context_tokens: 131_072
        })

      conn =
        post_chat(%{
          "model" => "persist-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      assert conn.status == 200

      requests = Orchard.Repo.all(Orchard.Requests.Request)
      assert length(requests) == 1
      [request] = requests

      assert request.tenant_id == "00000000-0000-0000-0000-000000000000"
      assert request.requested_model == "persist-model@v1"
      assert request.stream == true
      assert request.endpoint == :chat_completions
      assert is_map(request.canonical_request)
      assert request.canonical_request["public_id"] == request.public_id

      assert request.canonical_request["model_ref"] == %{
               "model_id" => "persist-model",
               "version" => "v1"
             }

      assert request.canonical_request["sampling"]["temperature"] == 1.0
      assert request.canonical_request["response_format"] == %{"type" => "text"}
      assert request.canonical_request["stream"] == true
      assert request.canonical_request["stream_include_usage"] == false
      refute_struct_artifacts!(request.canonical_request)
      # Terminal state after successful completion
      assert request.state in [:completed, :streaming]

      # Verify request_events reflect a state sequence
      events =
        Orchard.Repo.all(Orchard.Requests.RequestEvent)
        |> Enum.filter(&(&1.request_id == request.id))
        |> Enum.sort_by(& &1.seq)

      event_states = Enum.map(events, & &1.state)
      # Should include forward progression through the FSM
      assert length(events) >= 2
      assert Enum.all?(events, &match?(%DateTime{}, &1.occurred_at))
      assert :validated in event_states
    end
  end

  describe "POST /v1/chat/completions (model load failure mapping)" do
    @tag :db
    test "non-streaming model load failure returns mapped HTTP status and error envelope", %{
      bundle: bundle
    } do
      # Create a model in DB but don't stage cache, and give a source URI
      # pointing to a nonexistent path so model acquisition fails.
      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "fail-model",
          version: "v1",
          display_name: "Fail Model",
          artifact_uri: "file:///nonexistent/fail-model",
          artifact_sha256: bundle.hash,
          state: :active,
          format: "mlx",
          backend: "mlx",
          capabilities: ["chat"],
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 128,
          prefill_workspace_bytes_per_token: 64,
          max_context_tokens: 131_072
        })

      # Remove any cached bundle for this model
      File.rm_rf(Path.join([Node.models_root(), "fail-model", "v1"]))

      conn =
        post_chat(%{
          "model" => "fail-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      # Should get 503 (acquisition failed) not generic 500
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "server_error"
      assert body["error"]["code"] != nil
      assert body["error"]["message"] != nil

      # Verify persisted request row has mapped terminal fields
      requests = Orchard.Repo.all(Orchard.Requests.Request)
      failed_requests = Enum.filter(requests, &(&1.state == :failed))
      assert length(failed_requests) == 1
      [request] = failed_requests
      assert request.http_status == 503
      assert request.error_code != nil
      assert request.error_message != nil
      assert is_map(request.canonical_request)

      assert request.canonical_request["model_ref"] == %{
               "model_id" => "fail-model",
               "version" => "v1"
             }

      refute_struct_artifacts!(request.canonical_request)
    end

    @tag :db
    test "streaming model load failure emits SSE error with mapped code and no [DONE]", %{
      bundle: bundle
    } do
      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "fail-stream-model",
          version: "v1",
          display_name: "Fail Stream Model",
          artifact_uri: "file:///nonexistent/fail-stream-model",
          artifact_sha256: bundle.hash,
          state: :active,
          format: "mlx",
          backend: "mlx",
          capabilities: ["chat"],
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 128,
          prefill_workspace_bytes_per_token: 64,
          max_context_tokens: 131_072
        })

      File.rm_rf(Path.join([Node.models_root(), "fail-stream-model", "v1"]))

      conn =
        post_chat(%{
          "model" => "fail-stream-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      # HTTP status is 200 because SSE headers already sent
      assert conn.status == 200

      assert get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))

      events = parse_sse_body(conn.resp_body)

      # Should have an error event with mapped type/code
      error_events = Enum.filter(events, fn {type, _} -> type == :error end)
      assert length(error_events) == 1
      {:error, error_payload} = hd(error_events)
      assert error_payload["error"]["type"] == "server_error"
      assert error_payload["error"]["code"] != nil
      assert error_payload["error"]["message"] != nil

      # Must NOT emit [DONE] after error
      done_events = Enum.filter(events, fn {type, _} -> type == :done end)
      assert done_events == []
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

  defp refute_struct_artifacts!(value) when is_map(value) do
    refute Map.has_key?(value, "__struct__")
    refute Map.has_key?(value, :__struct__)

    Enum.each(value, fn {_key, nested} ->
      refute_struct_artifacts!(nested)
    end)
  end

  defp refute_struct_artifacts!(value) when is_list(value) do
    Enum.each(value, &refute_struct_artifacts!/1)
  end

  defp refute_struct_artifacts!(_value), do: :ok

  # Stage a test bundle at the cache path for model_ids used in streaming tests.
  # Returns %{hash, source_path, cache_paths} so tests can use the real hash.
  defp stage_test_bundle! do
    models_root = Node.models_root()
    source_path = Path.join([models_root, ".test-source", "chat-bundle"])

    File.rm_rf(source_path)
    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    # Pre-stage at cache locations for all model_ids these tests use
    model_ids = [{"test-stream-model", "v1"}, {"persist-model", "v1"}]

    cache_paths =
      Enum.map(model_ids, fn {model_id, version} ->
        cache_path = Path.join([models_root, model_id, version])
        File.rm_rf(cache_path)
        File.mkdir_p!(cache_path)
        :ok = ArtifactBundle.copy_directory(source_path, cache_path)
        cache_path
      end)

    %{hash: hash, source_path: source_path, cache_paths: cache_paths}
  end
end
