defmodule Orchard.API.ChatCompletionsControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.ToolRegistryTestSupport

  alias Orchard.API.Router
  alias Orchard.ArtifactBundle
  alias Orchard.Governance
  alias Orchard.Inference.ChatRequestNormalizer
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Requests.Idempotency

  # When testing through Router.call/2 directly (not the Endpoint),
  # Plug.Parsers does not run, so body_params are not merged into params.
  # We simulate the merge explicitly.
  defp post_chat(params, token \\ default_api_token!(), headers \\ []) do
    conn =
      build_conn(:post, "/v1/chat/completions")
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
    previous_orchestrator = Application.get_env(:orchard_controller, :api_chat_orchestrator_impl)

    # Reset node-agent state and stage a test bundle so model acquisition
    # succeeds for any model_id when the bundle is pre-cached.
    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      restore_env(:api_chat_orchestrator_impl, previous_orchestrator)
      clear_chat_stub_config()
      Enum.each(bundle.cache_paths, &File.rm_rf/1)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

  describe "POST /v1/chat/completions auth boundary" do
    test "missing bearer auth returns a JSON 401 before request validation" do
      conn =
        build_conn(:post, "/v1/chat/completions")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"messages" => [%{"role" => "user", "content" => "hi"}]})
        |> Map.put(:params, %{"messages" => [%{"role" => "user", "content" => "hi"}]})
        |> Router.call(Router.init([]))

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "authentication_error"
      assert body["error"]["code"] == "invalid_api_key"
    end

    test "stream=true without bearer auth still returns JSON 401, not SSE" do
      conn =
        build_conn(:post, "/v1/chat/completions")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true
        })
        |> Map.put(:params, %{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true
        })
        |> Router.call(Router.init([]))

      assert conn.status == 401

      refute get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))
    end
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

    @tag :db
    test "successful non-stream request persists replay payload equal to returned JSON", %{
      bundle: bundle
    } do
      %{token: token} = create_api_key_with_token!("non-stream-persist")

      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "persist-non-stream-model",
          version: "v1",
          display_name: "Persist Non Stream Model",
          artifact_uri: "file:///tmp/persist-non-stream-model",
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
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}]
          },
          token
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "chat.completion"

      [request] =
        Orchard.Repo.all(Orchard.Requests.Request)
        |> Enum.filter(&(&1.public_id == body["id"]))

      assert request.state == :completed
      assert request.response_payload == body
      assert request.response_preview != nil
      assert request.response_preview != ""
    end

    @tag :db
    test "SPEC.md §3.9 replays a tenant-scoped non-stream response for the same Idempotency-Key",
         %{
           bundle: bundle
         } do
      %{token: token, tenant: tenant} = create_api_key_with_token!("idempotency-replay")

      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "persist-non-stream-model",
          version: "v1",
          display_name: "Persist Non Stream Model",
          artifact_uri: "file:///tmp/persist-non-stream-model",
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

      params = %{
        "model" => "persist-non-stream-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      conn_a = post_chat(params, token, [{"idempotency-key", "tenant-replay"}])
      conn_b = post_chat(params, token, [{"idempotency-key", "tenant-replay"}])

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert Jason.decode!(conn_a.resp_body) == Jason.decode!(conn_b.resp_body)

      [request] = Orchard.Repo.all(Orchard.Requests.Request)
      assert request.tenant_id == tenant.id
      assert request.idempotency_key == "tenant-replay"
      assert is_binary(request.body_hash)
      assert byte_size(request.body_hash) == 32
    end

    @tag :db
    test "SPEC.md §3.9 returns 409 request_in_progress for a matching active tenant-scoped request" do
      %{token: token, tenant: tenant} = create_api_key_with_token!("idempotency-active")

      {:ok, idempotency} =
        Idempotency.build_context(tenant.id, "tenant-active", %{
          "model" => "persist-non-stream-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      create_request!(%{
        tenant_id: tenant.id,
        requested_model: "persist-non-stream-model@v1",
        idempotency_key: "tenant-active",
        body_hash: idempotency.body_hash,
        state: :running
      })

      conn =
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}]
          },
          token,
          [{"idempotency-key", "tenant-active"}]
        )

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "conflict_error"
      assert body["error"]["code"] == "request_in_progress"
    end

    @tag :db
    test "SPEC.md §3.9 returns 409 idempotency_mismatch for the same tenant and key with a different body" do
      %{token: token, tenant: tenant} = create_api_key_with_token!("idempotency-mismatch")

      {:ok, idempotency} =
        Idempotency.build_context(tenant.id, "tenant-mismatch", %{
          "model" => "persist-non-stream-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      create_request!(%{
        tenant_id: tenant.id,
        requested_model: "persist-non-stream-model@v1",
        idempotency_key: "tenant-mismatch",
        body_hash: idempotency.body_hash,
        stream: false,
        state: :completed,
        response_payload: %{"id" => "req_prior", "object" => "chat.completion"}
      })

      conn =
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "different"}]
          },
          token,
          [{"idempotency-key", "tenant-mismatch"}]
        )

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "conflict_error"
      assert body["error"]["code"] == "idempotency_mismatch"
    end

    @tag :db
    test "SPEC.md §3.9 scopes idempotency by tenant so different tenants may reuse the same key",
         %{
           bundle: bundle
         } do
      %{token: token_a} = create_api_key_with_token!("idempotency-tenant-a")
      %{token: token_b} = create_api_key_with_token!("idempotency-tenant-b")

      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "tenant-scope-model",
          version: "v1",
          display_name: "Tenant Scope Model",
          artifact_uri: "file:///tmp/tenant-scope-model",
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

      params = %{
        "model" => "tenant-scope-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      conn_a = post_chat(params, token_a, [{"idempotency-key", "shared-key"}])
      conn_b = post_chat(params, token_b, [{"idempotency-key", "shared-key"}])

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert length(Orchard.Repo.all(Orchard.Requests.Request)) == 2
    end

    @tag :db
    test "SPEC.md §3.9 returns 400 for a blank Idempotency-Key header" do
      conn =
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}]
          },
          default_api_token!(),
          [{"idempotency-key", "   "}]
        )

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "invalid_idempotency_key"
      assert body["error"]["param"] == "Idempotency-Key"
    end

    @tag :db
    test "SPEC.md §3.9 returns 400 for repeated Idempotency-Key headers" do
      token = default_api_token!()

      conn =
        build_conn(:post, "/v1/chat/completions")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.update!(:req_headers, fn headers ->
          [{"idempotency-key", "first"}, {"idempotency-key", "second"} | headers]
        end)
        |> Map.put(:body_params, %{
          "model" => "persist-non-stream-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })
        |> Map.put(:params, %{
          "model" => "persist-non-stream-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })
        |> Router.call(Router.init([]))

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "invalid_idempotency_key"
      assert body["error"]["param"] == "Idempotency-Key"
    end

    test "returns tool-call-only non-stream payload with finish_reason tool_calls" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(false), %{}},
        execute:
          {:ok, stub_chat_canonical(false),
           [
             InferenceEvent.accepted(1_710_000_123_000),
             tool_call_event("call_0", %{
               index: 0,
               type: "function",
               function: %{name: "lookup_weather"}
             }),
             tool_call_event("call_0", %{
               index: 0,
               function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
             }),
             InferenceEvent.completed(:finish_reason_tool_calls, nil)
           ]}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      [choice] = body["choices"]
      assert choice["finish_reason"] == "tool_calls"
      assert choice["message"]["content"] == nil

      assert choice["message"]["tool_calls"] == [
               %{
                 "id" => "call_0",
                 "type" => "function",
                 "function" => %{
                   "name" => "lookup_weather",
                   "arguments" => "{\"city\":\"Singapore\"}"
                 }
               }
             ]
    end

    test "returns mixed text and tool-call non-stream payload when both are emitted" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(false), %{}},
        execute:
          {:ok, stub_chat_canonical(false),
           [
             InferenceEvent.accepted(1_710_000_123_000),
             InferenceEvent.output_text_delta("Let me check."),
             tool_call_event("call_0", %{
               index: 0,
               type: "function",
               function: %{name: "lookup_weather"}
             }),
             tool_call_event("call_0", %{
               index: 0,
               function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
             }),
             InferenceEvent.completed(:finish_reason_tool_calls, nil)
           ]}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      [choice] = body["choices"]
      assert choice["finish_reason"] == "tool_calls"
      assert choice["message"]["content"] == "Let me check."
      assert length(choice["message"]["tool_calls"]) == 1
    end

    @tag :db
    test "valid ref-backed request succeeds without API shape changes" do
      %{token: token} = create_api_key_with_token!("chat-ref-success")
      create_tool!("lookup_weather", "2026-04-10")
      executable = write_tokenizer_executable!()
      on_exit(fn -> File.rm(executable) end)

      model =
        create_model!(%{
          model_id: "chat-ref-success-model",
          version: "v1",
          state: :active,
          capabilities: ["chat", "tool_calling"],
          artifact_uri: "file://#{fixture_bundle_path()}",
          artifact_source_uri: "file://#{fixture_bundle_path()}"
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
        "tool_choice" => "auto"
      }

      with_inference_overrides([tokenizer_mode: :port, tokenizer_executable: executable], fn ->
        stub_chat_orchestrator(
          prepare_real: true,
          capture_execute_pid: self(),
          events: [
            InferenceEvent.accepted(1_710_000_123_000),
            InferenceEvent.output_text_delta("Ref-backed tools are accepted."),
            InferenceEvent.completed(:finish_reason_stop, nil)
          ]
        )

        conn = post_chat(params, token)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["object"] == "chat.completion"
        assert body["model"] == "#{model.model_id}@#{model.version}"

        assert get_in(body, ["choices", Access.at(0), "message", "content"]) ==
                 "Ref-backed tools are accepted."

        assert_receive {:captured_execute_canonical, canonical, prepared_model}
        assert prepared_model.id == model.id
        assert canonical.tooling.requested_tools == params["tools"]
        assert canonical.tooling.tools == [function_definition("lookup_weather")]
      end)
    end

    @tag :db
    test "invalid ref-backed request returns stable validation error on tools" do
      conn =
        post_chat(%{
          "model" => "chat-ref-missing-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          "tool_choice" => "auto"
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "invalid_value"
      assert body["error"]["param"] == "tools"
      assert body["error"]["message"] =~ "tool://lookup_weather@2026-04-10"
    end

    @tag :db
    test "tool-calling request against a model without tool_calling capability returns tooling_not_supported",
         %{bundle: bundle} do
      {:ok, _model} =
        Orchard.Models.create_model(%{
          model_id: "tool-gate-model",
          version: "v1",
          display_name: "Tool Gate Model",
          artifact_uri: "file:///tmp/tool-gate-model",
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
          "model" => "tool-gate-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
          "tool_choice" => "auto"
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "tooling_not_supported"
      assert body["error"]["param"] == "model"
    end

    test "required tool_choice failures surface as terminal chat errors" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(false), %{}},
        execute:
          {:ok, stub_chat_canonical(false),
           [
             InferenceEvent.accepted(1_710_000_123_000),
             InferenceEvent.failed(
               "tool_choice_not_satisfied",
               "model did not emit any required tool calls",
               false
             )
           ]}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
          "tool_choice" => "required"
        })

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)

      assert body["error"]["message"] ==
               "Inference failed: model did not emit any required tool calls"
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

  describe "POST /v1/chat/completions (streaming tool calls)" do
    test "stream=true emits tool-call delta chunks, terminal tool_calls finish reason, and [DONE]" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(), %{}},
        events: [
          InferenceEvent.accepted(1_710_000_123_000),
          tool_call_event("call_0", %{
            index: 0,
            type: "function",
            function: %{name: "lookup_weather", arguments_delta: "{\"city\":\"Sing"}
          }),
          tool_call_event("call_0", %{index: 0, function: %{arguments_delta: "apore\"}"}}),
          InferenceEvent.completed(:finish_reason_tool_calls, nil)
        ],
        execute: {:ok, stub_chat_canonical(), []}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      assert conn.status == 200
      events = parse_sse_body(conn.resp_body)
      data_events = Enum.filter(events, fn {type, _} -> type == :data end)
      done_events = Enum.filter(events, fn {type, _} -> type == :done end)

      assert length(data_events) == 4
      {:data, role_chunk} = Enum.at(data_events, 0)
      assert hd(role_chunk["choices"])["delta"]["role"] == "assistant"

      {:data, first_tool_chunk} = Enum.at(data_events, 1)
      [first_choice] = first_tool_chunk["choices"]
      [first_tool_call] = first_choice["delta"]["tool_calls"]
      assert first_tool_call["index"] == 0
      assert first_tool_call["id"] == "call_0"
      assert first_tool_call["type"] == "function"

      assert first_tool_call["function"] == %{
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Sing"
             }

      {:data, second_tool_chunk} = Enum.at(data_events, 2)
      [second_choice] = second_tool_chunk["choices"]
      [second_tool_call] = second_choice["delta"]["tool_calls"]
      assert second_tool_call["function"] == %{"arguments" => "apore\"}"}

      {:data, finish_chunk} = Enum.at(data_events, 3)
      assert hd(finish_chunk["choices"])["finish_reason"] == "tool_calls"
      assert done_events == [{:done, nil}]
    end

    test "malformed tool-call delta after stream start emits SSE error envelope and no [DONE]" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(), %{}},
        events: [
          InferenceEvent.accepted(1_710_000_123_000),
          InferenceEvent.tool_call_delta("call_0", "not-json")
        ],
        execute: {:ok, stub_chat_canonical(), []}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => true
        })

      assert conn.status == 200
      events = parse_sse_body(conn.resp_body)

      assert Enum.any?(events, fn
               {:error, payload} -> payload["error"]["message"] == "Malformed tool call delta"
               _other -> false
             end)

      refute Enum.any?(events, fn {type, _payload} -> type == :done end)
    end
  end

  describe "POST /v1/chat/completions (streaming persistence, T4)" do
    @tag :db
    test "streaming request persists request row and state events", %{bundle: bundle} do
      %{tenant: tenant, api_key: api_key, token: token} =
        create_api_key_with_token!("persist-request")

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
        post_chat(
          %{
            "model" => "persist-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}],
            "stream" => true
          },
          token
        )

      assert conn.status == 200

      requests = Orchard.Repo.all(Orchard.Requests.Request)
      assert length(requests) == 1
      [request] = requests

      assert request.tenant_id == tenant.id
      assert request.api_key_id == api_key.id
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
      assert request.response_payload == nil
      assert request.response_preview == nil
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

    @tag :db
    test "SPEC.md §3.9 returns 409 before SSE start when a streaming duplicate is not replayable",
         %{
           bundle: bundle
         } do
      %{tenant: tenant, token: token} = create_api_key_with_token!("stream-idempotency")

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

      params = %{
        "model" => "persist-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "stream" => true
      }

      first = post_chat(params, token, [{"idempotency-key", "stream-dup"}])
      second = post_chat(params, token, [{"idempotency-key", "stream-dup"}])

      assert first.status == 200
      assert second.status == 409

      refute get_resp_header(second, "content-type")
             |> Enum.any?(&String.contains?(&1, "text/event-stream"))

      body = Jason.decode!(second.resp_body)
      assert body["error"]["code"] == "idempotency_not_replayable"

      assert Enum.count(Orchard.Repo.all(Orchard.Requests.Request), &(&1.tenant_id == tenant.id)) ==
               1
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

  defp stub_chat_orchestrator(config) do
    Application.put_env(
      :orchard_controller,
      :api_chat_orchestrator_impl,
      __MODULE__.StubChatOrchestrator
    )

    Process.put({__MODULE__, :stub_chat_orchestrator}, config)
  end

  defp clear_chat_stub_config do
    Process.delete({__MODULE__, :stub_chat_orchestrator})
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)

  defp stub_chat_canonical(stream? \\ true, overrides \\ %{}) do
    defaults = %{
      internal_id: Ecto.UUID.generate(),
      public_id: "chatcmpl_tool_stub",
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %{model_id: "stub-tool-model", version: "v1"},
      input_items: [%{"role" => "user", "content" => "hello"}],
      rendered_prompt: "hello",
      input_token_count: 3,
      stream?: stream?,
      stream_include_usage: false
    }

    Orchard.CanonicalRequest.new(Map.merge(defaults, overrides))
  end

  defp tool_call_event(tool_call_id, delta) do
    InferenceEvent.tool_call_delta(tool_call_id, Jason.encode!(delta))
  end

  defp default_api_token! do
    %{token: token} =
      create_api_key_with_token!("chat-auth-#{System.unique_integer([:positive])}")

    token
  end

  defp create_api_key_with_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant.id, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

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
    model_ids = [
      {"test-stream-model", "v1"},
      {"persist-model", "v1"},
      {"persist-non-stream-model", "v1"},
      {"tenant-scope-model", "v1"}
    ]

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

  defmodule StubChatOrchestrator do
    alias Orchard.Inference.ChatOrchestrator

    def prepare(params, caller_context) do
      config =
        Process.get({Orchard.API.ChatCompletionsControllerTest, :stub_chat_orchestrator}, %{})

      if Keyword.get(config, :prepare_real, false) do
        ChatOrchestrator.prepare(params, caller_context)
      else
        Keyword.fetch!(config, :prepare)
      end
    end

    def execute(canonical, model, opts) do
      config =
        Process.get({Orchard.API.ChatCompletionsControllerTest, :stub_chat_orchestrator}, %{})

      if pid = Keyword.get(config, :capture_execute_pid) do
        send(pid, {:captured_execute_canonical, canonical, model})
      end

      if event_handler = Keyword.get(opts, :event_handler) do
        Enum.each(Keyword.get(config, :events, []), fn event ->
          event_handler.(canonical.public_id, event)
        end)
      end

      case Keyword.get(config, :execute) do
        nil -> {:ok, canonical, Keyword.get(config, :events, [])}
        result -> result
      end
    end
  end
end
