defmodule Orchard.API.ResponsesControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.API.Router
  alias Orchard.ArtifactBundle
  alias Orchard.Governance
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Repo
  alias Orchard.Requests.Idempotency
  alias Orchard.Requests.Request

  defp post_responses(params, token \\ default_api_token!(), headers \\ []) do
    conn =
      build_conn(:post, "/v1/responses")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    conn
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> Router.call(Router.init([]))
  end

  setup do
    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      Enum.each(bundle.cache_paths, &File.rm_rf/1)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

  test "missing bearer auth returns a JSON 401 before request validation" do
    conn =
      build_conn(:post, "/v1/responses")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"input" => "hi"})
      |> Map.put(:params, %{"input" => "hi"})
      |> Router.call(Router.init([]))

    assert conn.status == 401
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "authentication_error"
    assert body["error"]["code"] == "invalid_api_key"
  end

  test "rejects malformed model values with an OpenAI error envelope" do
    conn = post_responses(%{"model" => 123, "input" => "hello"})

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "invalid_value"
    assert body["error"]["param"] == "model"
  end

  test "rejects non-boolean stream parameter with OpenAI error envelope" do
    conn =
      post_responses(%{
        "model" => "test-model@v1",
        "input" => "hello",
        "stream" => "yes"
      })

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "invalid_value"
    assert body["error"]["param"] == "stream"
  end

  test "returns context_length_exceeded for an oversized request" do
    %{token: token} = create_api_key_with_token!("responses-context-overflow")

    model =
      create_model!(%{
        model_id: "responses-context-overflow-model",
        version: "v1",
        state: :active,
        max_context_tokens: 100
      })

    content = Enum.map_join(1..98, " ", &"word#{&1}")

    conn =
      post_responses(
        %{"model" => "#{model.model_id}@#{model.version}", "input" => content},
        token
      )

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "context_length_exceeded"
  end

  test "returns model_not_found for a valid request with an unknown model" do
    conn = post_responses(%{"model" => "missing@v1", "input" => "hello"})

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "model_not_found"
    assert body["error"]["param"] == "model"
  end

  test "successful non-stream request returns response payload and persists responses endpoint",
       %{bundle: bundle} do
    %{token: token} = create_api_key_with_token!("responses-success")

    _model =
      create_model!(%{
        model_id: "responses-success-model",
        version: "v1",
        display_name: "Responses Success Model",
        artifact_uri: "file:///tmp/responses-success-model",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file:///tmp/responses-success-model",
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
      post_responses(
        %{
          "model" => "responses-success-model@v1",
          "instructions" => "Be helpful",
          "input" => [
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "hello"}]
            }
          ],
          "max_output_tokens" => 32,
          "metadata" => %{"trace" => "abc"},
          "store" => false
        },
        token
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "response"
    assert body["status"] == "completed"
    assert body["model"] == "responses-success-model@v1"
    assert body["output_text"] != nil
    assert body["metadata"] == %{"trace" => "abc"}

    [request] = Repo.all(Request)
    assert request.endpoint == :responses
    assert request.canonical_request["endpoint"] == "responses"
    assert request.response_payload == body
    assert request.response_preview == body["output_text"]
  end

  test "replays completed tenant-scoped responses for the same idempotency key", %{bundle: bundle} do
    %{token: token, tenant: tenant} = create_api_key_with_token!("responses-replay")

    _model =
      create_model!(%{
        model_id: "responses-replay-model",
        version: "v1",
        display_name: "Responses Replay Model",
        artifact_uri: "file:///tmp/responses-replay-model",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file:///tmp/responses-replay-model",
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

    params = %{"model" => "responses-replay-model@v1", "input" => "hello"}

    conn_a = post_responses(params, token, [{"idempotency-key", "responses-replay"}])
    conn_b = post_responses(params, token, [{"idempotency-key", "responses-replay"}])

    assert conn_a.status == 200
    assert conn_b.status == 200
    assert Jason.decode!(conn_a.resp_body) == Jason.decode!(conn_b.resp_body)

    [request] = Repo.all(Request)
    assert request.tenant_id == tenant.id
    assert request.idempotency_key == "responses-replay"
  end

  test "returns 409 request_in_progress for a matching active tenant-scoped request" do
    %{token: token, tenant: tenant} = create_api_key_with_token!("responses-active")

    {:ok, idempotency} =
      Idempotency.build_context(tenant.id, "responses-active", %{
        "model" => "responses-active-model@v1",
        "input" => "hello"
      })

    create_request!(%{
      tenant_id: tenant.id,
      endpoint: :responses,
      requested_model: "responses-active-model@v1",
      idempotency_key: "responses-active",
      body_hash: idempotency.body_hash,
      stream: false,
      state: :running
    })

    conn =
      post_responses(
        %{"model" => "responses-active-model@v1", "input" => "hello"},
        token,
        [{"idempotency-key", "responses-active"}]
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "conflict_error"
    assert body["error"]["code"] == "request_in_progress"
  end

  test "returns 409 idempotency_mismatch for the same tenant and key with a different body" do
    %{token: token, tenant: tenant} = create_api_key_with_token!("responses-mismatch")

    {:ok, idempotency} =
      Idempotency.build_context(tenant.id, "responses-mismatch", %{
        "model" => "responses-mismatch-model@v1",
        "input" => "hello"
      })

    create_request!(%{
      tenant_id: tenant.id,
      endpoint: :responses,
      requested_model: "responses-mismatch-model@v1",
      idempotency_key: "responses-mismatch",
      body_hash: idempotency.body_hash,
      stream: false,
      state: :completed,
      response_payload: %{"id" => "resp_prior", "object" => "response"}
    })

    conn =
      post_responses(
        %{"model" => "responses-mismatch-model@v1", "input" => "different"},
        token,
        [{"idempotency-key", "responses-mismatch"}]
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "conflict_error"
    assert body["error"]["code"] == "idempotency_mismatch"
  end

  defp default_api_token! do
    %{token: token} =
      create_api_key_with_token!("responses-auth-#{System.unique_integer([:positive])}")

    token
  end

  defp create_api_key_with_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant.id, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

  # -- Streaming tests -------------------------------------------------------

  test "successful stream emits typed events in correct order", %{bundle: bundle} do
    %{token: token} = create_api_key_with_token!("responses-stream-success")

    _model =
      create_model!(%{
        model_id: "responses-stream-model",
        version: "v1",
        display_name: "Responses Stream Model",
        artifact_uri: "file:///tmp/responses-stream-model",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file:///tmp/responses-stream-model",
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
      post_responses(
        %{
          "model" => "responses-stream-model@v1",
          "input" => "hello",
          "stream" => true,
          "metadata" => %{"trace" => "stream-test"}
        },
        token
      )

    assert conn.status == 200
    assert resp_header(conn, "content-type") == ["text/event-stream"]

    events = parse_typed_sse_events(conn)

    # Must start with response.created
    assert hd(events).type == "response.created"
    created = hd(events)
    assert created.data["response"]["status"] == "in_progress"
    assert created.data["response"]["model"] == "responses-stream-model@v1"
    assert created.data["response"]["metadata"] == %{"trace" => "stream-test"}

    # Must contain at least one response.output_text.delta
    delta_events = Enum.filter(events, &(&1.type == "response.output_text.delta"))
    assert length(delta_events) >= 1
    first_delta = hd(delta_events)
    assert is_binary(first_delta.data["delta"])
    assert first_delta.data["output_index"] == 0
    assert first_delta.data["content_index"] == 0

    # Must contain exactly one response.output_text.done
    done_events = Enum.filter(events, &(&1.type == "response.output_text.done"))
    assert length(done_events) == 1
    done = hd(done_events)
    assert is_binary(done.data["text"])

    # output_text.done must appear after all deltas and before terminal
    delta_indices =
      Enum.with_index(events)
      |> Enum.filter(fn {e, _} -> e.type == "response.output_text.delta" end)
      |> Enum.map(fn {_, i} -> i end)

    [{_, done_index}] =
      Enum.with_index(events)
      |> Enum.filter(fn {e, _} -> e.type == "response.output_text.done" end)

    terminal_index = length(events) - 1
    assert Enum.all?(delta_indices, &(&1 < done_index))
    assert done_index < terminal_index

    # Must end with response.completed (terminal)
    terminal = List.last(events)
    assert terminal.type == "response.completed"
    assert terminal.data["response"]["status"] == "completed"
    assert terminal.data["response"]["output_text"] != nil
    # Completed terminal's output_text must match concatenated deltas
    concatenated = Enum.map_join(delta_events, "", & &1.data["delta"])
    assert terminal.data["response"]["output_text"] == concatenated

    # No [DONE] in stream
    body = collect_chunked_body(conn)
    refute String.contains?(body, "[DONE]")

    # Request persisted with endpoint = :responses and stream = true
    [request] = Repo.all(Request)
    assert request.endpoint == :responses
    assert request.stream == true
  end

  test "post-start failure emits response.created then response.failed with no [DONE]" do
    %{token: token} = create_api_key_with_token!("responses-stream-fail")

    # Model with a mismatched hash — will fail at dispatch/model-load
    _model =
      create_model!(%{
        model_id: "responses-stream-fail-model",
        version: "v1",
        display_name: "Responses Stream Fail Model",
        artifact_uri: "file:///tmp/nonexistent",
        artifact_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        artifact_source_uri: "file:///tmp/nonexistent",
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
      post_responses(
        %{
          "model" => "responses-stream-fail-model@v1",
          "input" => "hello",
          "stream" => true
        },
        token
      )

    assert conn.status == 200
    assert resp_header(conn, "content-type") == ["text/event-stream"]

    events = parse_typed_sse_events(conn)

    # Must start with response.created
    assert hd(events).type == "response.created"
    assert hd(events).data["response"]["status"] == "in_progress"

    # Must contain response.output_text.done before terminal
    done_events = Enum.filter(events, &(&1.type == "response.output_text.done"))
    assert length(done_events) == 1

    # Must end with response.failed (terminal)
    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "failed"
    assert terminal.data["response"]["error"] != nil
    assert terminal.data["response"]["error"]["type"] != nil

    # No [DONE] in stream
    body = collect_chunked_body(conn)
    refute String.contains?(body, "[DONE]")
  end

  test "streaming pre-stream validation failure returns JSON, not SSE" do
    conn =
      post_responses(%{
        "model" => "missing@v1",
        "input" => "hello",
        "stream" => true
      })

    # Pre-stream errors are JSON, not SSE
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "model_not_found"
    refute resp_header(conn, "content-type") == ["text/event-stream"]
  end

  test "streaming idempotency replay before stream start returns JSON 409" do
    %{token: token, tenant: tenant} = create_api_key_with_token!("responses-stream-replay")

    {:ok, idempotency} =
      Idempotency.build_context(tenant.id, "responses-stream-replay", %{
        "model" => "responses-stream-replay-model@v1",
        "input" => "hello",
        "stream" => true
      })

    create_request!(%{
      tenant_id: tenant.id,
      endpoint: :responses,
      requested_model: "responses-stream-replay-model@v1",
      idempotency_key: "responses-stream-replay",
      body_hash: idempotency.body_hash,
      stream: true,
      state: :running
    })

    conn =
      post_responses(
        %{
          "model" => "responses-stream-replay-model@v1",
          "input" => "hello",
          "stream" => true
        },
        token,
        [{"idempotency-key", "responses-stream-replay"}]
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "conflict_error"
  end

  # -- Test helpers -----------------------------------------------------------

  defp resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end

  defp collect_chunked_body(conn) do
    case conn.resp_body do
      body when is_binary(body) -> body
      nil -> ""
    end
  end

  defp parse_typed_sse_events(conn) do
    body = collect_chunked_body(conn)

    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, "\n", trim: true)

      case lines do
        ["event: " <> event_type, "data: " <> json] ->
          %{type: event_type, data: Jason.decode!(json)}

        ["data: " <> json] ->
          %{type: nil, data: Jason.decode!(json)}

        _ ->
          %{type: nil, data: nil, raw: block}
      end
    end)
  end

  defp stage_test_bundle! do
    models_root = Node.models_root()
    source_path = Path.join([models_root, ".test-source", "responses-bundle"])

    File.rm_rf(source_path)
    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    cache_paths =
      Enum.map(
        [
          {"responses-success-model", "v1"},
          {"responses-replay-model", "v1"},
          {"responses-stream-model", "v1"}
        ],
        fn {model_id, version} ->
          cache_path = Path.join([models_root, model_id, version])
          File.rm_rf(cache_path)
          File.mkdir_p!(cache_path)
          :ok = ArtifactBundle.copy_directory(source_path, cache_path)
          cache_path
        end
      )

    %{hash: hash, source_path: source_path, cache_paths: cache_paths}
  end
end
