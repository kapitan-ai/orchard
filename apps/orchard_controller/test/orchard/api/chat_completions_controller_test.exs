defmodule Orchard.API.ChatCompletionsControllerTest.UnsupportedVersionScoreScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference
  alias Orchard.TestSupport.DispatchCapacityFixtures

  def schedule(%CanonicalRequest{} = request) do
    schedule =
      DispatchCapacityFixtures.authorize_unmanaged_schedule(%{
        strategy: :multi_node,
        request_id: request.public_id,
        runtime_client_target: Inference.runtime_client_target(),
        request_timeout_ms: Inference.request_timeout_ms(),
        model_load_timeout_ms: Inference.model_load_timeout_ms(),
        candidate_count: 1,
        selected_tier: :loaded,
        selected_cache_tier: "warm_prefix",
        prefix_cache_score: %{
          status_code: "unsupported_version",
          status_message:
            "must not persist prompt=unsupported-version smoke token_ids=[1,2,3] hmac-sha256:#{String.duplicate("f", 64)} raw_score",
          resident_fingerprint_match: true,
          score_tier: "resident_fingerprint",
          session_started_unix_ms: 1_713_726_400_456
        }
      })

    {:ok, schedule}
  end
end

defmodule Orchard.API.ChatCompletionsControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.QueueAdmissionAPI
  import Orchard.TestSupport.ToolRegistryTestSupport

  alias Orchard.API.Router
  alias Orchard.ArtifactBundle
  alias Orchard.Governance
  alias Orchard.Governance.Tenant
  alias Orchard.Inference.ChatRequestNormalizer
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent
  alias Orchard.Models.Access, as: ModelAccess
  alias Orchard.Models.RoutingPolicy
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Repo
  alias Orchard.Requests
  alias Orchard.Requests.{Idempotency, Request}

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

  defp post_chat_endpoint(params, token, accept) do
    build_conn()
    |> put_req_header("accept", accept)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/v1/chat/completions", params)
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
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    previous_runtime_owner =
      Application.get_env(:orchard_controller, :queue_admission_api_runtime_owner)

    # Reset node-agent state and stage a test bundle so model acquisition
    # succeeds for any model_id when the bundle is pre-cached.
    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      restore_env(:api_chat_orchestrator_impl, previous_orchestrator)
      restore_env(:queue_admission_api_runtime_owner, previous_runtime_owner)
      Application.put_env(:orchard_controller, :inference, previous_inference)
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      QueueManager.reset()
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

    test "SPEC.md §5.2 returns exact 403 for an active ungranted Model before persistence" do
      model = create_model!(%{state: :active})
      %{token: token} = create_api_key_with_token!("chat-ungranted", grant_active?: false)
      before_count = Repo.aggregate(Request, :count, :id)

      conn =
        post_chat(
          %{
            "model" => "#{model.model_id}@#{model.version}",
            "messages" => [%{"role" => "user", "content" => "hello"}],
            "max_tokens" => 1
          },
          token
        )

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body)["error"] == %{
               "type" => "invalid_request_error",
               "code" => "model_not_authorized",
               "message" => "Model not authorized for tenant",
               "param" => "model"
             }

      assert Repo.aggregate(Request, :count, :id) == before_count
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
    @tag :live
    test "successful metadata-capture request returns JSON without retaining the response", %{
      bundle: bundle
    } do
      %{token: token, tenant: tenant} = create_api_key_with_token!("non-stream-persist")

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

      grant_active_models!(tenant)

      conn =
        post_chat_endpoint(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}]
          },
          token,
          "application/json"
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "chat.completion"

      [request] =
        Orchard.Repo.all(Orchard.Requests.Request)
        |> Enum.filter(&(&1.public_id == body["id"]))

      assert request.state == :completed
      assert request.payload_capture_mode == :metadata
      assert request.response_payload == nil
      assert request.response_preview == nil
      assert request.response_hash != nil
      assert_text_commitment!(request)

      tenant
      |> Tenant.changeset(%{request_body_capture_mode: :full})
      |> Orchard.Repo.update!()

      full_conn =
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "retain in full mode"}]
          },
          token
        )

      assert full_conn.status == 200
      full_body = Jason.decode!(full_conn.resp_body)
      full_request = Requests.get_request_by_public_id(full_body["id"])
      assert full_request.payload_capture_mode == :full
      assert full_request.canonical_request["rendered_prompt"] =~ "retain in full mode"
      assert full_request.response_payload == full_body
      assert_text_commitment!(full_request)

      %{token: none_token, tenant: none_tenant} =
        create_api_key_with_token!("non-stream-none")

      none_tenant
      |> Tenant.changeset(%{request_body_capture_mode: :none})
      |> Orchard.Repo.update!()

      none_conn =
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [%{"role" => "user", "content" => "retain nothing"}]
          },
          none_token
        )

      assert none_conn.status == 200
      none_request = Requests.get_request_by_public_id(Jason.decode!(none_conn.resp_body)["id"])
      assert none_request.payload_capture_mode == :none
      assert none_request.canonical_request == nil
      assert none_request.request_shape == nil
      assert none_request.response_payload == nil
      assert_text_commitment!(none_request)
    end

    @tag :db
    test "Phase 4D unsupported-version score smoke stays HTTP 200 and persists sanitized diagnostics",
         %{
           bundle: bundle
         } do
      inference = Application.fetch_env!(:orchard_controller, :inference)

      Application.put_env(
        :orchard_controller,
        :inference,
        inference
        |> Keyword.put(:scheduler_impl, __MODULE__.UnsupportedVersionScoreScheduler)
        |> Keyword.put(:cache_introspection, enabled: true)
        |> Keyword.put(:prefix_cache_scoring, enabled: true, timeout_ms: 120)
        |> Keyword.put(:cache_affinity,
          enabled: true,
          live_fingerprint_match_enabled: true,
          hmac_secret: "unsupported-version-smoke-secret"
        )
      )

      %{token: token, tenant: tenant} =
        create_api_key_with_token!("unsupported-version-score")

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

      grant_active_models!(tenant)

      conn =
        post_chat(
          %{
            "model" => "persist-non-stream-model@v1",
            "messages" => [
              %{"role" => "user", "content" => "unsupported-version smoke prompt"}
            ]
          },
          token
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "chat.completion"

      request = Requests.get_request_by_public_id(body["id"])
      assert request.state == :completed

      decision = request.scheduler_decision
      assert decision["strategy"] == "multi_node"
      assert decision["candidate_count"] == 1
      assert decision["selected_cache_tier"] == "warm_prefix"
      assert decision["selected_prefix_cache_score_status_code"] == "unsupported_version"
      assert decision["selected_prefix_cache_score_tier"] == "unknown"

      assert decision["selected_prefix_cache_score_source"] == "score_prefix_cache_rpc"
      refute Map.has_key?(decision, "selected_prefix_cache_score_status_message")
      refute Map.has_key?(decision, "prefix_cache_score")
      refute Map.has_key?(decision, "selected_prefix_cache_score_resident_fingerprint_match")
      refute Map.has_key?(decision, "selected_prefix_cache_score_session_started_unix_ms")

      encoded = Jason.encode!(decision)
      refute encoded =~ "unsupported-version smoke prompt"
      refute encoded =~ "\"prompt\""
      refute encoded =~ "token_ids"
      refute encoded =~ "hmac-sha256"
      refute encoded =~ "raw_score"
      refute encoded =~ "raw_cache"
    end

    @tag :db
    test "SPEC.md §10.10 metadata capture fails closed when replay content is unavailable",
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

      grant_active_models!(tenant)

      params = %{
        "model" => "persist-non-stream-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      conn_a = post_chat(params, token, [{"idempotency-key", "tenant-replay"}])
      conn_b = post_chat(params, token, [{"idempotency-key", "tenant-replay"}])

      assert conn_a.status == 200
      assert conn_b.status == 409
      assert Jason.decode!(conn_b.resp_body)["error"]["code"] == "idempotency_not_replayable"

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
      %{tenant: tenant_a, token: token_a} =
        create_api_key_with_token!("idempotency-tenant-a")

      %{tenant: tenant_b, token: token_b} =
        create_api_key_with_token!("idempotency-tenant-b")

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

      grant_active_models!(tenant_a)
      grant_active_models!(tenant_b)

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
      %{tenant: tenant, token: token} = create_api_key_with_token!("chat-ref-success")
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

      grant_active_models!(tenant)

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

    test "SPEC 7.5.5 non-stream terminal conformance failure is a generic 500" do
      canonical = stub_chat_canonical(false)

      stub_chat_orchestrator(
        prepare: {:ok, canonical, %{}},
        execute:
          {:ok, canonical,
           [
             InferenceEvent.accepted(1_710_000_123_000),
             InferenceEvent.failed(
               "runtime_endpoint_missing_terminal",
               "Runtime Endpoint stream ended without a terminal event",
               false
             )
           ]}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == "api_error"
      assert body["error"]["code"] == "internal_error"
      assert body["error"]["message"] == "Internal error"
    end

    @tag :db
    test "queue admission enabled queues overlapping same-model chat completions", %{
      bundle: bundle
    } do
      put_queue_admission_config!()
      put_blocking_runtime_adapter!(self())
      create_queue_model!(bundle, "chat-queue-overlap-model")

      %{token: token} = create_api_key_with_token!("chat-queue-overlap")

      params = %{
        "model" => "chat-queue-overlap-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      first = Task.async(fn -> post_chat(params, token) end)

      assert_receive {:queue_admission_runtime_started, first_pid, first_request_id,
                      "chat-queue-overlap-model"},
                     2_000

      second = Task.async(fn -> post_chat(params, token) end)

      assert wait_for_queued_request("chat-queue-overlap-model@v1")

      send(first_pid, :queue_admission_runtime_release)
      first_conn = Task.await(first, 5_000)

      assert_receive {:queue_admission_runtime_started, second_pid, second_request_id,
                      "chat-queue-overlap-model"},
                     2_000

      refute second_request_id == first_request_id

      send(second_pid, :queue_admission_runtime_release)
      second_conn = Task.await(second, 5_000)

      assert first_conn.status == 200
      assert second_conn.status == 200

      immediate = request_with_queue_result!("chat-queue-overlap-model@v1", "immediate")
      queued = request_with_queue_result!("chat-queue-overlap-model@v1", "queued")

      assert_queue_metadata(immediate, "immediate", granted?: true)
      assert_queue_metadata(queued, "queued", queued?: true, granted?: true)
    end

    @tag :db
    test "SPEC.md §5.2/§5.4/§7.5 queue admission capacity two exposes WorkerProcess telemetry over gRPC",
         %{
           bundle: bundle
         } do
      put_queue_admission_config!(capacity: 2, max_wait_ms: 2_000)
      put_blocking_runtime_adapter!(self(), max_concurrent_requests: 2)
      create_queue_model!(bundle, "chat-queue-capacity2-model")

      %{token: token} = create_api_key_with_token!("chat-queue-capacity2")

      params = %{
        "model" => "chat-queue-capacity2-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      Process.put(:queue_admission_runtime_pids, [])
      tasks = Enum.map(1..3, fn _index -> Task.async(fn -> post_chat(params, token) end) end)

      try do
        {first_pid, first_request_id} = runtime_start_message("chat-queue-capacity2-model")
        remember_runtime_pid(first_pid)
        {second_pid, second_request_id} = runtime_start_message("chat-queue-capacity2-model")
        remember_runtime_pid(second_pid)

        refute second_request_id == first_request_id

        status = grpc_status_snapshot()
        placement = runtime_model_placement!(status, "chat-queue-capacity2-model", "v1")
        assert status.active_request_count == 2
        assert placement.active_request_count == 2
        assert placement.max_concurrency == 2

        assert wait_for_queued_request("chat-queue-capacity2-model@v1")

        refute_receive {:queue_admission_runtime_started, _pid, _request_id,
                        "chat-queue-capacity2-model"},
                       100

        send(first_pid, :queue_admission_runtime_release)

        {third_pid, third_request_id} = runtime_start_message("chat-queue-capacity2-model")
        remember_runtime_pid(third_pid)

        refute third_request_id in [first_request_id, second_request_id]

        send(second_pid, :queue_admission_runtime_release)
        send(third_pid, :queue_admission_runtime_release)

        conns = Enum.map(tasks, &Task.await(&1, 5_000))
        assert Enum.map(conns, & &1.status) == [200, 200, 200]
        assert wait_until(fn -> grpc_status_snapshot().active_request_count == 0 end)

        final_status = grpc_status_snapshot()

        final_placement =
          runtime_model_placement!(final_status, "chat-queue-capacity2-model", "v1")

        assert final_placement.active_request_count == 0
        assert final_placement.max_concurrency == 2

        assert_queue_result_count!("chat-queue-capacity2-model@v1", "immediate", 2)
        assert_queue_result_count!("chat-queue-capacity2-model@v1", "queued", 1)

        Enum.each(
          requests_with_queue_result!("chat-queue-capacity2-model@v1", "immediate"),
          &assert_queue_metadata(&1, "immediate", granted?: true)
        )

        [queued] = requests_with_queue_result!("chat-queue-capacity2-model@v1", "queued")
        assert_queue_metadata(queued, "queued", queued?: true, granted?: true)
      after
        Enum.each(Process.get(:queue_admission_runtime_pids, []), fn pid ->
          send(pid, :queue_admission_runtime_release)
        end)

        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        Process.delete(:queue_admission_runtime_pids)
      end
    end

    @tag :db
    test "SPEC.md §5.4 tenant active cap queues same-tenant chat completions despite lane capacity",
         %{bundle: bundle} do
      put_queue_admission_config!(capacity: 2, max_active_per_tenant: 1)

      put_blocking_runtime_adapter!(self(),
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 2,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      )

      create_queue_model!(bundle, "chat-queue-tenant-active-cap-model")

      %{token: token} = create_api_key_with_token!("chat-queue-tenant-active-cap")

      params = %{
        "model" => "chat-queue-tenant-active-cap-model@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      }

      first = Task.async(fn -> post_chat(params, token) end)

      assert_receive {:queue_admission_runtime_started, first_pid, first_request_id,
                      "chat-queue-tenant-active-cap-model"},
                     2_000

      second = Task.async(fn -> post_chat(params, token) end)

      assert wait_for_queued_request("chat-queue-tenant-active-cap-model@v1")

      refute_receive {:queue_admission_runtime_started, _pid, _request_id,
                      "chat-queue-tenant-active-cap-model"},
                     100

      send(first_pid, :queue_admission_runtime_release)
      first_conn = Task.await(first, 5_000)

      assert_receive {:queue_admission_runtime_started, second_pid, second_request_id,
                      "chat-queue-tenant-active-cap-model"},
                     2_000

      assert first_conn.status == 200
      refute second_request_id == first_request_id

      send(second_pid, :queue_admission_runtime_release)
      second_conn = Task.await(second, 5_000)

      assert second_conn.status == 200

      immediate =
        request_with_queue_result!("chat-queue-tenant-active-cap-model@v1", "immediate")

      queued = request_with_queue_result!("chat-queue-tenant-active-cap-model@v1", "queued")

      assert_queue_metadata(immediate, "immediate", granted?: true)
      assert_queue_metadata(queued, "queued", queued?: true, granted?: true)
    end

    test "SPEC.md §7.2.7 returns top-level chat envelopes for busy and queue execute errors" do
      cases = [
        {:model_busy, 503, "server_error", "model_busy"},
        {:queue_full, 429, "rate_limit_error", "queue_full"},
        {:queue_timeout, 504, "server_error", "queue_timeout"},
        {:request_caller_disconnect, 499, "server_error", "request_cancelled"}
      ]

      for {reason, status, type, code} <- cases do
        stub_chat_orchestrator(
          prepare: {:ok, stub_chat_canonical(false), %{}},
          execute: {:error, reason}
        )

        conn =
          post_chat(%{
            "model" => "stub-tool-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}]
          })

        assert conn.status == status
        body = Jason.decode!(conn.resp_body)
        assert body["error"]["type"] == type
        assert body["error"]["code"] == code
        assert Map.has_key?(body["error"], "message")
        assert Map.has_key?(body["error"], "param")
        refute Map.has_key?(body, "response")
      end
    end

    test "node-agent load deadline returns a gateway timeout with load_timeout" do
      failure = ModelLoadFailure.from_transport_reason(:node_timeout)

      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(false), %{}},
        execute: {:error, {:model_load_failed, failure}}
      )

      conn =
        post_chat(%{
          "model" => "stub-tool-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      assert conn.status == 504

      assert Jason.decode!(conn.resp_body)["error"] == %{
               "type" => "server_error",
               "code" => "load_timeout",
               "message" => "model load timed out",
               "param" => nil
             }
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
    for accept <- ["text/event-stream", "application/json"] do
      @tag :db
      @tag :live
      test "SPEC.md §7.2.5 keeps one public ID across SSE chunks and persistence with Accept: #{accept}",
           %{bundle: bundle} do
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
          post_chat_endpoint(
            %{
              "model" => "test-stream-model@v1",
              "messages" => [%{"role" => "user", "content" => "hello"}],
              "stream" => true
            },
            default_api_token!(),
            unquote(accept)
          )

        # SSE started (chunked 200)
        assert conn.status == 200

        assert get_resp_header(conn, "content-type")
               |> Enum.any?(&String.contains?(&1, "text/event-stream"))

        # Parse SSE body
        events = parse_sse_body(conn.resp_body)

        # Should have data chunks followed by [DONE]
        data_events = Enum.filter(events, fn {type, _} -> type == :data end)
        done_events = Enum.filter(events, fn {type, _} -> type == :done end)

        chunk_ids = Enum.map(data_events, fn {:data, chunk} -> Map.fetch!(chunk, "id") end)
        assert [public_id] = Enum.uniq(chunk_ids)
        assert String.starts_with?(public_id, "chatcmpl-")
        assert %{public_id: ^public_id} = Requests.get_request_by_public_id(public_id)

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

        request = Requests.get_request_by_public_id(first_chunk["id"])
        assert_text_commitment!(request)

        assert Sentry.Context.get_all().extra == %{}
        assert Sentry.Context.get_all().breadcrumbs == []
      end
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
          InferenceEvent.tool_call_delta("call_0", "not-json"),
          InferenceEvent.completed(:finish_reason_tool_calls, nil)
        ],
        capture_handler_pid: self(),
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

      assert_receive {:handler_result, :accepted, :ok}
      assert_receive {:handler_result, :tool_call_delta, {:error, :serializer_failed}}
      refute_receive {:handler_result, :completed, _result}
    end

    test "post-commit serializer failure keeps public SSE shape and durable commitment",
         %{bundle: bundle} do
      put_queue_admission_config!()

      put_blocking_runtime_adapter!(self(),
        events: [
          InferenceEvent.tool_call_delta("call-stable", "not-json"),
          InferenceEvent.completed(:finish_reason_tool_calls, nil)
        ]
      )

      create_queue_model!(bundle, "chat-queue-overlap-model")
      %{token: token} = create_api_key_with_token!("chat-tool-serializer-failure")

      task =
        Task.async(fn ->
          post_chat(
            %{
              "model" => "chat-queue-overlap-model@v1",
              "messages" => [%{"role" => "user", "content" => "call a tool"}],
              "stream" => true
            },
            token
          )
        end)

      assert_receive {:queue_admission_runtime_started, runtime_pid, request_id,
                      "chat-queue-overlap-model"},
                     2_000

      send(runtime_pid, :queue_admission_runtime_release)
      conn = Task.await(task, 5_000)
      events = parse_sse_body(conn.resp_body)

      assert Enum.any?(events, fn
               {:error, payload} -> payload["error"]["message"] == "Malformed tool call delta"
               _other -> false
             end)

      refute Enum.any?(events, fn {type, _payload} -> type == :done end)

      request = Requests.get_request_by_public_id(request_id)
      assert request.state == :failed
      assert_tool_serializer_failure!(request)
    end

    test "SPEC 7.5.5 streaming terminal conformance failure emits one generic SSE error" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(), %{}},
        events: [
          InferenceEvent.accepted(1_710_000_123_000),
          InferenceEvent.failed(
            "runtime_endpoint_missing_terminal",
            "Runtime Endpoint stream ended without a terminal event",
            false
          )
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

      assert [{:error, payload}] = Enum.filter(events, fn {type, _payload} -> type == :error end)
      assert payload["error"]["type"] == "server_error"
      assert payload["error"]["code"] == "internal_error"
      assert payload["error"]["message"] == "Internal error"
      refute Enum.any?(events, fn {type, _payload} -> type == :done end)
    end

    test "SPEC.md §7.2.7 runtime caller disconnect uses the public cancellation SSE envelope" do
      stub_chat_orchestrator(
        prepare: {:ok, stub_chat_canonical(), %{}},
        events: [
          InferenceEvent.accepted(1_710_000_123_000),
          InferenceEvent.failed("request_caller_disconnect", "caller exited", false)
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
      assert [{:error, payload}] = Enum.filter(events, fn {type, _payload} -> type == :error end)

      assert payload["error"] == %{
               "type" => "server_error",
               "code" => "request_cancelled",
               "message" => "Request was cancelled",
               "param" => nil
             }

      refute Enum.any?(events, fn {type, _payload} -> type == :done end)
    end

    test "SPEC.md §7.2.7 streaming busy and queue execute errors use chat SSE error envelope" do
      cases = [
        {:model_busy, "server_error", "model_busy"},
        {:queue_full, "rate_limit_error", "queue_full"},
        {:queue_timeout, "server_error", "queue_timeout"},
        {:request_caller_disconnect, "server_error", "request_cancelled"}
      ]

      for {reason, type, code} <- cases do
        stub_chat_orchestrator(
          prepare: {:ok, stub_chat_canonical(), %{}},
          execute: {:error, reason}
        )

        conn =
          post_chat(%{
            "model" => "stub-tool-model@v1",
            "messages" => [%{"role" => "user", "content" => "hello"}],
            "stream" => true
          })

        assert conn.status == 200
        events = parse_sse_body(conn.resp_body)
        assert [{:error, payload}] = events
        assert payload["error"]["type"] == type
        assert payload["error"]["code"] == code
        refute Enum.any?(events, fn {event_type, _payload} -> event_type == :done end)
      end
    end
  end

  describe "POST /v1/chat/completions (streaming persistence, T4)" do
    @tag :db
    test "streaming request persists request row and state events", %{bundle: bundle} do
      %{tenant: tenant, api_key: api_key, token: token} =
        create_api_key_with_token!("persist-request")

      tenant
      |> Tenant.changeset(%{request_body_capture_mode: :full})
      |> Orchard.Repo.update!()

      {:ok, model} =
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

      grant_active_models!(tenant)

      {:ok, policy} =
        %RoutingPolicy{}
        |> RoutingPolicy.changeset(%{
          tenant_id: tenant.id,
          name: "cold-deadline",
          residency_preference: :allow_cold_load,
          max_cold_start_ms: 180_000,
          max_queue_wait_ms: 3_000
        })
        |> Repo.insert()

      assert {:ok, _result} = ModelAccess.grant_model_access(tenant, model, policy.id)

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
      assert request.payload_capture_mode == :full
      assert request.canonical_request["stream"] == true
      assert request.request_payload["prompt"] =~ "hello"
      assert request.response_payload["object"] == "chat.completion"
      assert is_binary(request.response_preview)

      assert_in_delta DateTime.diff(request.timeout_at, request.inserted_at, :millisecond),
                      Orchard.Inference.request_timeout_ms() + 3_000 + 180_000,
                      1

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
      refute Enum.any?(events, &(&1.event_type == "output_text.delta"))
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

      grant_active_models!(tenant)

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
      assert body["error"]["code"] == "acquisition_failed"
      assert body["error"]["message"] != nil

      # Verify persisted request row has mapped terminal fields
      requests = Orchard.Repo.all(Orchard.Requests.Request)
      failed_requests = Enum.filter(requests, &(&1.state == :failed))
      assert length(failed_requests) == 1
      [request] = failed_requests
      assert request.http_status == 503
      assert request.error_code == "acquisition_failed"
      assert request.error_message == nil
      assert request.canonical_request == nil
      assert request.request_shape["capture_mode"] == "metadata"

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
      assert error_payload["error"]["code"] == "acquisition_failed"
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

  defp grant_active_models!(tenant) do
    Enum.each(Orchard.Models.list_active_models(), fn model ->
      assert {:ok, _result} = ModelAccess.grant_model_access(tenant, model)
    end)
  end

  defp create_api_key_with_token!(slug, opts \\ []) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant.id, %{name: "Primary"})

    if Keyword.get(opts, :grant_active?, true), do: grant_active_models!(tenant)
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
      {"tenant-scope-model", "v1"},
      {"chat-queue-overlap-model", "v1"},
      {"chat-queue-capacity2-model", "v1"},
      {"chat-queue-tenant-active-cap-model", "v1"}
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

  defp remember_runtime_pid(pid) do
    pids = Process.get(:queue_admission_runtime_pids, [])
    Process.put(:queue_admission_runtime_pids, [pid | pids])
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
        _handler_result =
          Enum.reduce_while(Keyword.get(config, :events, []), :ok, fn event, _acc ->
            deliver_event(
              event_handler,
              canonical.public_id,
              event,
              Keyword.get(config, :capture_handler_pid)
            )
          end)
      end

      case Keyword.get(config, :execute) do
        nil -> {:ok, canonical, Keyword.get(config, :events, [])}
        result -> result
      end
    end

    defp deliver_event(event_handler, request_id, event, capture_pid) do
      result = event_handler.(request_id, event)

      if capture_pid do
        send(capture_pid, {:handler_result, Orchard.InferenceEvent.kind(event), result})
      end

      case result do
        :ok -> {:cont, :ok}
        :cancel -> {:halt, :cancel}
        {:error, :serializer_failed} = error -> {:halt, error}
      end
    end
  end
end
