defmodule Orchard.API.ResponsesControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.QueueAdmissionAPI
  import Orchard.TestSupport.RetryAPI
  import Orchard.TestSupport.ToolRegistryTestSupport

  alias Orchard.API.Router
  alias Orchard.ArtifactBundle
  alias Orchard.Governance
  alias Orchard.Governance.Tenant
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent
  alias Orchard.Models.Access, as: ModelAccess
  alias Orchard.Models.RoutingPolicy
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Repo
  alias Orchard.Requests
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

  defp post_responses_endpoint(params, token, accept, headers \\ []) do
    conn =
      build_conn()
      |> put_req_header("accept", accept)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    |> post("/v1/responses", params)
  end

  setup do
    previous_orchestrator =
      Application.get_env(:orchard_controller, :api_responses_orchestrator_impl)

    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    previous_runtime_owner =
      Application.get_env(:orchard_controller, :queue_admission_api_runtime_owner)

    ModelManager.reset()
    bundle = stage_test_bundle!()

    on_exit(fn ->
      restore_env(:api_responses_orchestrator_impl, previous_orchestrator)
      restore_env(:queue_admission_api_runtime_owner, previous_runtime_owner)
      Application.put_env(:orchard_controller, :inference, previous_inference)
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      QueueManager.reset()
      clear()
      clear_responses_stub_config()
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

  test "rejects non-object inline tool parameters before model lookup or dispatch" do
    conn =
      post_responses(%{
        "model" => "not-looked-up@v1",
        "input" => "hello",
        "tools" => [
          %{
            "type" => "function",
            "function" => %{"name" => "lookup_weather", "parameters" => "nope"}
          }
        ]
      })

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "invalid_value"
    assert body["error"]["param"] == "tools"
    assert body["error"]["message"] =~ "function parameters must be an object"
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

  test "SPEC.md §5.2 returns exact 403 for an active ungranted Model before persistence" do
    model = create_model!(%{state: :active})
    %{token: token} = create_api_key_with_token!("responses-ungranted", grant_active?: false)
    before_count = Repo.aggregate(Request, :count, :id)

    conn =
      post_responses(
        %{
          "model" => "#{model.model_id}@#{model.version}",
          "input" => "hello",
          "max_output_tokens" => 1
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

  @tag :live
  test "successful non-stream request returns response payload and persists responses endpoint",
       %{bundle: bundle} do
    %{token: token, tenant: tenant} = create_api_key_with_token!("responses-success")

    tenant
    |> Tenant.changeset(%{request_body_capture_mode: :full})
    |> Repo.update!()

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

    grant_active_models!(tenant)

    conn =
      post_responses_endpoint(
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
        token,
        "application/json"
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
    assert request.payload_capture_mode == :metadata
    assert request.canonical_request == nil
    assert request.request_payload == nil
    assert request.response_payload == nil
    assert request.response_preview == nil
    assert request.request_shape["capture_mode"] == "metadata"
    assert request.response_hash != nil

    # first_token_at must be persisted for successful requests with output
    request = Requests.get_request_by_public_id(body["id"])
    assert_text_commitment!(request)

    full_conn =
      post_responses(
        %{
          "model" => "responses-success-model@v1",
          "input" => "retain this only in full mode",
          "store" => true
        },
        token
      )

    assert full_conn.status == 200
    full_body = Jason.decode!(full_conn.resp_body)
    full_request = Requests.get_request_by_public_id(full_body["id"])
    assert full_request.payload_capture_mode == :full
    assert full_request.canonical_request["endpoint"] == "responses"
    assert full_request.response_payload == full_body
    assert_text_commitment!(full_request)

    for params <- [
          %{"model" => "responses-success-model@v1", "input" => "store omitted"},
          %{"model" => "responses-success-model@v1", "input" => "store null", "store" => nil}
        ] do
      default_store_conn = post_responses(params, token)
      assert default_store_conn.status == 200

      default_store_request =
        default_store_conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("id")
        |> Requests.get_request_by_public_id()

      assert default_store_request.payload_capture_mode == :full
      assert default_store_request.canonical_request != nil
      assert default_store_request.response_payload != nil
    end

    invalid_store_conn =
      post_responses(
        %{
          "model" => "responses-success-model@v1",
          "input" => "invalid store",
          "store" => "false"
        },
        token
      )

    assert invalid_store_conn.status == 400
    assert Jason.decode!(invalid_store_conn.resp_body)["error"]["param"] == "store"

    %{token: none_token, tenant: none_tenant} =
      create_api_key_with_token!("responses-none")

    none_tenant
    |> Tenant.changeset(%{request_body_capture_mode: :none})
    |> Repo.update!()

    none_conn =
      post_responses(
        %{"model" => "responses-success-model@v1", "input" => "retain nothing"},
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

  test "successful non-stream request can return function_call output items" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(false), %{}},
      execute:
        {:ok, stub_responses_canonical(false),
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
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello"
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "completed"
    assert body["output_text"] == ""

    assert body["output"] == [
             %{
               "type" => "function_call",
               "id" => "call_0",
               "call_id" => "call_0",
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Singapore\"}",
               "status" => "completed"
             }
           ]
  end

  test "valid ref-backed request succeeds without API shape changes" do
    %{tenant: tenant, token: token} = create_api_key_with_token!("responses-ref-success")
    create_tool!("lookup_weather", "2026-04-10")
    executable = write_tokenizer_executable!()
    on_exit(fn -> File.rm(executable) end)

    model =
      create_model!(%{
        model_id: "responses-ref-success-model",
        version: "v1",
        state: :active,
        capabilities: ["chat", "tool_calling"],
        artifact_uri: "file://#{fixture_bundle_path()}",
        artifact_source_uri: "file://#{fixture_bundle_path()}"
      })

    grant_active_models!(tenant)

    params = %{
      "model" => "#{model.model_id}@#{model.version}",
      "input" => "hello",
      "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
      "tool_choice" => "auto"
    }

    with_inference_overrides([tokenizer_mode: :port, tokenizer_executable: executable], fn ->
      stub_responses_orchestrator(
        prepare_real: true,
        capture_execute_pid: self(),
        events: [
          InferenceEvent.accepted(1_710_000_123_000),
          InferenceEvent.output_text_delta("Ref-backed responses tools are accepted."),
          InferenceEvent.completed(:finish_reason_stop, nil)
        ]
      )

      conn = post_responses(params, token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "response"
      assert body["model"] == "#{model.model_id}@#{model.version}"
      assert body["output_text"] == "Ref-backed responses tools are accepted."

      assert_receive {:captured_execute_canonical, canonical, prepared_model}
      assert prepared_model.id == model.id
      assert canonical.tooling.requested_tools == params["tools"]
      assert canonical.tooling.tools == [function_definition("lookup_weather")]
    end)
  end

  test "invalid ref-backed request returns stable validation error on tools" do
    conn =
      post_responses(%{
        "model" => "responses-ref-missing-model@v1",
        "input" => "hello",
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

  test "tool-calling request against a model without tool_calling capability returns tooling_not_supported",
       %{bundle: bundle} do
    _model =
      create_model!(%{
        model_id: "responses-tool-gate-model",
        version: "v1",
        display_name: "Responses Tool Gate Model",
        artifact_uri: "file:///tmp/responses-tool-gate-model",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file:///tmp/responses-tool-gate-model",
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
      post_responses(%{
        "model" => "responses-tool-gate-model@v1",
        "input" => "hello",
        "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
        "tool_choice" => "auto"
      })

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "tooling_not_supported"
    assert body["error"]["param"] == "model"
  end

  test "named tool_choice failures surface as terminal response errors" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(false), %{}},
      execute:
        {:ok, stub_responses_canonical(false),
         [
           InferenceEvent.accepted(1_710_000_123_000),
           InferenceEvent.failed(
             "tool_choice_not_satisfied",
             "model emitted tool call outside required function lookup_weather",
             false
           )
         ]}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
        "tool_choice" => %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
      })

    assert conn.status == 500
    body = Jason.decode!(conn.resp_body)

    assert body["error"]["message"] ==
             "Inference failed: model emitted tool call outside required function lookup_weather"
  end

  test "SPEC 7.5.5 sync terminal conformance failure is a generic 500" do
    canonical = stub_responses_canonical(false)

    stub_responses_orchestrator(
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

    conn = post_responses(%{"model" => "stub-tool-model@v1", "input" => "hello"})

    assert conn.status == 500
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "api_error"
    assert body["error"]["code"] == "internal_error"
    assert body["error"]["message"] == "Internal error"
  end

  test "queue admission enabled queues overlapping same-model responses requests", %{
    bundle: bundle
  } do
    put_queue_admission_config!()
    put_blocking_runtime_adapter!(self())
    create_queue_model!(bundle, "responses-queue-overlap-model")

    %{token: token} = create_api_key_with_token!("responses-queue-overlap")

    params = %{
      "model" => "responses-queue-overlap-model@v1",
      "input" => "hello"
    }

    first = Task.async(fn -> post_responses(params, token) end)

    assert_receive {:queue_admission_runtime_started, first_pid, first_request_id,
                    "responses-queue-overlap-model"},
                   2_000

    second = Task.async(fn -> post_responses(params, token) end)

    assert wait_for_queued_request("responses-queue-overlap-model@v1")

    send(first_pid, :queue_admission_runtime_release)
    first_conn = Task.await(first, 5_000)

    assert_receive {:queue_admission_runtime_started, second_pid, second_request_id,
                    "responses-queue-overlap-model"},
                   2_000

    refute second_request_id == first_request_id

    send(second_pid, :queue_admission_runtime_release)
    second_conn = Task.await(second, 5_000)

    assert first_conn.status == 200
    assert second_conn.status == 200

    immediate = request_with_queue_result!("responses-queue-overlap-model@v1", "immediate")
    queued = request_with_queue_result!("responses-queue-overlap-model@v1", "queued")

    assert_queue_metadata(immediate, "immediate", granted?: true)
    assert_queue_metadata(queued, "queued", queued?: true, granted?: true)
  end

  test "SPEC.md §5.2/§5.4/§7.5 queue admission capacity two exposes WorkerProcess telemetry over gRPC",
       %{
         bundle: bundle
       } do
    put_queue_admission_config!(capacity: 2, max_wait_ms: 2_000)
    put_blocking_runtime_adapter!(self(), max_concurrent_requests: 2)
    create_queue_model!(bundle, "responses-queue-capacity2-model")

    %{token: token} = create_api_key_with_token!("responses-queue-capacity2")

    params = %{
      "model" => "responses-queue-capacity2-model@v1",
      "input" => "hello"
    }

    Process.put(:queue_admission_runtime_pids, [])
    tasks = Enum.map(1..3, fn _index -> Task.async(fn -> post_responses(params, token) end) end)

    try do
      {first_pid, first_request_id} = runtime_start_message("responses-queue-capacity2-model")
      remember_runtime_pid(first_pid)
      {second_pid, second_request_id} = runtime_start_message("responses-queue-capacity2-model")
      remember_runtime_pid(second_pid)

      refute second_request_id == first_request_id

      status = grpc_status_snapshot()
      placement = runtime_model_placement!(status, "responses-queue-capacity2-model", "v1")
      assert status.active_request_count == 2
      assert placement.active_request_count == 2
      assert placement.max_concurrency == 2

      assert wait_for_queued_request("responses-queue-capacity2-model@v1")

      refute_receive {:queue_admission_runtime_started, _pid, _request_id,
                      "responses-queue-capacity2-model"},
                     100

      send(first_pid, :queue_admission_runtime_release)

      {third_pid, third_request_id} = runtime_start_message("responses-queue-capacity2-model")
      remember_runtime_pid(third_pid)

      refute third_request_id in [first_request_id, second_request_id]

      send(second_pid, :queue_admission_runtime_release)
      send(third_pid, :queue_admission_runtime_release)

      conns = Enum.map(tasks, &Task.await(&1, 5_000))
      assert Enum.map(conns, & &1.status) == [200, 200, 200]
      assert wait_until(fn -> grpc_status_snapshot().active_request_count == 0 end)

      assert_queue_result_count!("responses-queue-capacity2-model@v1", "immediate", 2)
      assert_queue_result_count!("responses-queue-capacity2-model@v1", "queued", 1)

      Enum.each(
        requests_with_queue_result!("responses-queue-capacity2-model@v1", "immediate"),
        &assert_queue_metadata(&1, "immediate", granted?: true)
      )

      [queued] = requests_with_queue_result!("responses-queue-capacity2-model@v1", "queued")
      assert_queue_metadata(queued, "queued", queued?: true, granted?: true)
    after
      Enum.each(Process.get(:queue_admission_runtime_pids, []), fn pid ->
        send(pid, :queue_admission_runtime_release)
      end)

      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      Process.delete(:queue_admission_runtime_pids)
    end
  end

  test "SPEC.md §5.4 tenant active cap queues same-tenant responses requests despite lane capacity",
       %{bundle: bundle} do
    put_queue_admission_config!(capacity: 2, max_active_per_tenant: 1)

    put_blocking_runtime_adapter!(self(),
      worker_generation_mode: "batch",
      worker_max_concurrent_requests_per_model: 2,
      test_only_allow_batch_admission_for_non_worker_adapters?: true
    )

    create_queue_model!(bundle, "responses-queue-tenant-active-cap-model")

    %{token: token} = create_api_key_with_token!("responses-queue-tenant-active-cap")

    params = %{
      "model" => "responses-queue-tenant-active-cap-model@v1",
      "input" => "hello"
    }

    first = Task.async(fn -> post_responses(params, token) end)

    assert_receive {:queue_admission_runtime_started, first_pid, first_request_id,
                    "responses-queue-tenant-active-cap-model"},
                   2_000

    second = Task.async(fn -> post_responses(params, token) end)

    assert wait_for_queued_request("responses-queue-tenant-active-cap-model@v1")

    refute_receive {:queue_admission_runtime_started, _pid, _request_id,
                    "responses-queue-tenant-active-cap-model"},
                   100

    send(first_pid, :queue_admission_runtime_release)
    first_conn = Task.await(first, 5_000)

    assert_receive {:queue_admission_runtime_started, second_pid, second_request_id,
                    "responses-queue-tenant-active-cap-model"},
                   2_000

    assert first_conn.status == 200
    refute second_request_id == first_request_id

    send(second_pid, :queue_admission_runtime_release)
    second_conn = Task.await(second, 5_000)

    assert second_conn.status == 200

    immediate =
      request_with_queue_result!("responses-queue-tenant-active-cap-model@v1", "immediate")

    queued = request_with_queue_result!("responses-queue-tenant-active-cap-model@v1", "queued")

    assert_queue_metadata(immediate, "immediate", granted?: true)
    assert_queue_metadata(queued, "queued", queued?: true, granted?: true)
  end

  test "SPEC.md §7.2.7 returns top-level sync responses envelopes for busy and queue execute errors" do
    cases = [
      {:model_busy, 503, "server_error", "model_busy"},
      {:queue_full, 429, "rate_limit_error", "queue_full"},
      {:queue_timeout, 504, "server_error", "queue_timeout"},
      {:request_caller_disconnect, 499, "server_error", "request_cancelled"}
    ]

    for {reason, status, type, code} <- cases do
      stub_responses_orchestrator(
        prepare: {:ok, stub_responses_canonical(false), %{}},
        execute: {:error, reason}
      )

      conn = post_responses(%{"model" => "stub-tool-model@v1", "input" => "hello"})

      assert conn.status == status
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["type"] == type
      assert body["error"]["code"] == code
      refute Map.has_key?(body, "response")
    end
  end

  test "node-agent load deadline returns a gateway timeout with load_timeout" do
    failure = ModelLoadFailure.from_transport_reason(:node_timeout)

    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(false), %{}},
      execute: {:error, {:model_load_failed, failure}}
    )

    conn = post_responses(%{"model" => "stub-tool-model@v1", "input" => "hello"})

    assert conn.status == 504

    assert Jason.decode!(conn.resp_body)["error"] == %{
             "type" => "server_error",
             "code" => "load_timeout",
             "message" => "model load timed out",
             "param" => nil
           }
  end

  test "metadata capture fails closed when idempotency replay content is unavailable", %{
    bundle: bundle
  } do
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

    grant_active_models!(tenant)

    params = %{"model" => "responses-replay-model@v1", "input" => "hello"}

    conn_a = post_responses(params, token, [{"idempotency-key", "responses-replay"}])
    conn_b = post_responses(params, token, [{"idempotency-key", "responses-replay"}])

    assert conn_a.status == 200
    assert conn_b.status == 409
    assert Jason.decode!(conn_b.resp_body)["error"]["code"] == "idempotency_not_replayable"

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

  # -- Streaming tests -------------------------------------------------------

  for accept <- ["text/event-stream", "application/json"] do
    @tag :live
    test "successful stream emits typed events in correct order with Accept: #{accept}", %{
      bundle: bundle
    } do
      %{token: token, tenant: tenant} =
        create_api_key_with_token!("responses-stream-success")

      tenant
      |> Tenant.changeset(%{request_body_capture_mode: :full})
      |> Repo.update!()

      model =
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

      grant_active_models!(tenant)

      {:ok, policy} =
        %RoutingPolicy{}
        |> RoutingPolicy.changeset(%{
          tenant_id: tenant.id,
          name: "responses-cold-deadline",
          residency_preference: :allow_cold_load,
          max_cold_start_ms: 180_000,
          max_queue_wait_ms: 3_000
        })
        |> Repo.insert()

      assert {:ok, _result} = ModelAccess.grant_model_access(tenant, model, policy.id)

      conn =
        post_responses_endpoint(
          %{
            "model" => "responses-stream-model@v1",
            "input" => "hello",
            "stream" => true,
            "metadata" => %{"trace" => "stream-test"}
          },
          token,
          unquote(accept)
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
      [first_delta | _rest] = delta_events
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

      persisted_timeout_ms =
        DateTime.diff(request.timeout_at, request.inserted_at, :millisecond)

      configured_timeout_ms = Orchard.Inference.request_timeout_ms() + 3_000 + 180_000

      assert persisted_timeout_ms in (configured_timeout_ms - 1_000)..configured_timeout_ms

      # first_token_at must be persisted for successful streaming requests
      response_id = terminal.data["response"]["id"]
      request = Requests.get_request_by_public_id(response_id)
      assert_text_commitment!(request)
      assert request.payload_capture_mode == :full
      assert request.canonical_request["stream"] == true
      assert request.response_payload == terminal.data["response"]

      request_events = Requests.list_request_events(request)
      refute Enum.any?(request_events, &(&1.event_type == "response.output_text.delta"))

      assert Sentry.Context.get_all().extra == %{}
      assert Sentry.Context.get_all().breadcrumbs == []
    end
  end

  test "streaming empty-string text delta still emits output_text.done before terminal" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        InferenceEvent.output_text_delta(""),
        InferenceEvent.completed(:finish_reason_stop, nil)
      ],
      execute: {:ok, stub_responses_canonical(true), []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)

    assert Enum.map(events, & &1.type) == [
             "response.created",
             "response.output_text.delta",
             "response.output_text.done",
             "response.completed"
           ]

    assert Enum.at(events, 1).data["delta"] == ""
    assert Enum.at(events, 2).data["text"] == ""
  end

  @tag :live
  @tag :pre_acceptance_refusal
  test "SPEC 5.9 and 5.10: Responses preserves pre-acceptance busy without acceptance or retry",
       %{
         bundle: bundle
       } do
    create_queue_model!(bundle, "responses-preacceptance-refusal")

    %{token: token, tenant: tenant} =
      create_api_key_with_token!("responses-preacceptance-refusal")

    grant_active_models!(tenant)

    for stream? <- [false, true] do
      nodes =
        configure_retry_nodes!(
          [[InferenceEvent.failed("model_busy", "capacity exhausted", false)]],
          accepted?: false
        )

      conn =
        post_responses_endpoint(
          %{
            "model" => "responses-preacceptance-refusal@v1",
            "input" => "hello",
            "stream" => stream?
          },
          token,
          if(stream?, do: "text/event-stream", else: "application/json")
        )

      if stream? do
        assert conn.status == 200
        events = parse_typed_sse_events(conn)
        assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]
        assert List.last(events).data["response"]["error"]["code"] == "model_busy"
      else
        assert conn.status == 503
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "model_busy"
      end

      request = latest_request!("responses-preacceptance-refusal@v1", stream?)
      assert_preacceptance_capacity_refusal!(request, nodes)
    end
  end

  @tag :live
  test "SPEC.md M4 retries one uncommitted attempt across JSON and typed SSE", %{bundle: bundle} do
    create_queue_model!(bundle, "responses-bounded-retry")
    %{token: token, tenant: tenant} = create_api_key_with_token!("responses-bounded-retry")
    grant_active_models!(tenant)

    for stream? <- [false, true] do
      idempotency_key = "responses-bounded-retry-#{stream?}"

      nodes = configure_retry_nodes!(successful_retry_events())

      Process.put(:orchard_retry_started_probe, fn request ->
        send(self(), {:retry_api_reservation_at_attempt_two, request.reserved_output_tokens})
      end)

      conn =
        post_responses_endpoint(
          %{
            "model" => "responses-bounded-retry@v1",
            "input" => "hello",
            "max_output_tokens" => 7,
            "stream" => stream?
          },
          token,
          if(stream?, do: "text/event-stream", else: "application/json"),
          [{"idempotency-key", idempotency_key}]
        )

      assert conn.status == 200

      public_id =
        if stream? do
          events = parse_typed_sse_events(conn)

          assert Enum.map(events, & &1.type) == [
                   "response.created",
                   "response.output_text.delta",
                   "response.output_text.done",
                   "response.completed"
                 ]

          assert Enum.map_join(events, "", &Map.get(&1.data, "delta", "")) ==
                   "attempt-two-only"

          assert List.last(events).type == "response.completed"
          refute collect_chunked_body(conn) =~ "attempt-one-only"
          get_in(List.last(events).data, ["response", "id"])
        else
          body = Jason.decode!(conn.resp_body)
          assert body["output_text"] == "attempt-two-only"
          refute conn.resp_body =~ "attempt-one-only"
          body["id"]
        end

      request = Requests.get_request_by_public_id(public_id)
      assert request.stream == stream?
      assert_receive {:retry_api_reservation_at_attempt_two, 7}
      assert request.reserved_output_tokens == 0
      assert_logical_identity!(request, idempotency_key, :metadata)
      assert_successful_retry!(request, nodes)
    end
  end

  @tag :live
  test "SPEC.md M4 exposes attempt 2 failure without a third Responses attempt", %{
    bundle: bundle
  } do
    create_queue_model!(bundle, "responses-bounded-retry-failure")

    %{token: token, tenant: tenant} =
      create_api_key_with_token!("responses-bounded-retry-failure")

    grant_active_models!(tenant)

    for stream? <- [false, true] do
      nodes = configure_retry_nodes!(exhausted_retry_events())

      conn =
        post_responses_endpoint(
          %{
            "model" => "responses-bounded-retry-failure@v1",
            "input" => "hello",
            "stream" => stream?
          },
          token,
          if(stream?, do: "text/event-stream", else: "application/json")
        )

      if stream? do
        assert conn.status == 200
        terminal = conn |> parse_typed_sse_events() |> List.last()
        assert terminal.type == "response.failed"
        assert terminal.data["response"]["error"]["code"] == "runtime_unavailable"
      else
        assert conn.status == 500
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "internal_error"
      end

      request = latest_request!("responses-bounded-retry-failure@v1", stream?)
      assert request.reserved_output_tokens == 0
      assert_failed_retry!(request, nodes)
    end
  end

  @tag :live
  test "SPEC.md M4 blocks Responses retry after text or tool identity commitment", %{
    bundle: bundle
  } do
    for {kind, commitment_event} <- commitment_cases() do
      model_id = "responses-bounded-retry-committed-#{kind}"
      create_queue_model!(bundle, model_id)
      %{token: token, tenant: tenant} = create_api_key_with_token!(model_id)
      grant_active_models!(tenant)

      for stream? <- [false, true] do
        nodes =
          configure_retry_nodes!(
            [
              [
                commitment_event,
                InferenceEvent.failed("worker_down", "committed attempt failed", true)
              ]
            ],
            node_count: 1
          )

        conn =
          post_responses_endpoint(
            %{
              "model" => "#{model_id}@v1",
              "input" => "hello",
              "stream" => stream?
            },
            token,
            if(stream?, do: "text/event-stream", else: "application/json")
          )

        if stream? do
          assert conn.status == 200
          terminal = conn |> parse_typed_sse_events() |> List.last()
          assert terminal.type == "response.failed"
          assert terminal.data["response"]["error"]["code"] == "worker_down"
        else
          assert conn.status == 500
          assert Jason.decode!(conn.resp_body)["error"]["code"] == "internal_error"
        end

        request = latest_request!("#{model_id}@v1", stream?)
        assert_declined_retry!(request, nodes, "output_committed", "worker_or_node_loss", kind)
      end
    end
  end

  @tag :live
  test "SPEC.md M4 preserves Responses attempt 1 when no safe alternate exists", %{
    bundle: bundle
  } do
    for {suffix, selection_mode, retry_decision} <- alternate_refusal_cases() do
      model_id = "responses-bounded-retry-#{suffix}"
      create_queue_model!(bundle, model_id)
      %{token: token, tenant: tenant} = create_api_key_with_token!(model_id)
      grant_active_models!(tenant)

      for stream? <- [false, true] do
        nodes =
          configure_retry_nodes!(
            [[InferenceEvent.failed("worker_down", "attempt one failed", true)]],
            selection_mode: selection_mode,
            node_count: 1
          )

        conn =
          post_responses_endpoint(
            %{
              "model" => "#{model_id}@v1",
              "input" => "hello",
              "stream" => stream?
            },
            token,
            if(stream?, do: "text/event-stream", else: "application/json")
          )

        if stream? do
          terminal = conn |> parse_typed_sse_events() |> List.last()
          assert terminal.type == "response.failed"
          assert terminal.data["response"]["error"]["code"] == "worker_down"
        else
          assert conn.status == 500
          assert Jason.decode!(conn.resp_body)["error"]["code"] == "internal_error"
        end

        request = latest_request!("#{model_id}@v1", stream?)
        assert request.error_code == "worker_down"
        assert_declined_retry!(request, nodes, retry_decision, "worker_or_node_loss")
      end
    end
  end

  @tag :live
  test "SPEC.md M4 keeps Responses terminal-conformance failures non-retryable", %{
    bundle: bundle
  } do
    create_queue_model!(bundle, "responses-bounded-retry-conformance")

    %{token: token, tenant: tenant} =
      create_api_key_with_token!("responses-bounded-retry-conformance")

    grant_active_models!(tenant)

    for stream? <- [false, true] do
      nodes = configure_retry_nodes!([[]], node_count: 1)

      conn =
        post_responses_endpoint(
          %{
            "model" => "responses-bounded-retry-conformance@v1",
            "input" => "hello",
            "stream" => stream?
          },
          token,
          if(stream?, do: "text/event-stream", else: "application/json")
        )

      if stream? do
        terminal = conn |> parse_typed_sse_events() |> List.last()
        assert terminal.type == "response.failed"
        assert terminal.data["response"]["error"]["code"] == "internal_error"
      else
        assert conn.status == 500
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "internal_error"
      end

      request = latest_request!("responses-bounded-retry-conformance@v1", stream?)
      assert_declined_retry!(request, nodes, "not_retryable", "terminal_conformance")
    end
  end

  test "streaming terminal includes assembled function_call items without new SSE event types" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
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
      ],
      execute: {:ok, stub_responses_canonical(true), []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)

    assert Enum.map(events, & &1.type) == [
             "response.created",
             "response.completed"
           ]

    terminal = List.last(events)
    assert terminal.data["response"]["status"] == "completed"
    assert terminal.data["response"]["output_text"] == ""

    assert terminal.data["response"]["output"] == [
             %{
               "type" => "function_call",
               "id" => "call_0",
               "call_id" => "call_0",
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Singapore\"}",
               "status" => "completed"
             }
           ]
  end

  test "streaming cancelled partial tool calls are marked incomplete in the terminal payload" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        tool_call_event("call_0", %{
          index: 0,
          type: "function",
          function: %{name: "lookup_weather", arguments_delta: "{\"city\":\"Sing"}
        }),
        InferenceEvent.failed("request_cancelled", "request was cancelled upstream", false)
      ],
      execute: {:ok, stub_responses_canonical(true), []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)
    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "incomplete"

    assert terminal.data["response"]["output"] == [
             %{
               "type" => "function_call",
               "id" => "call_0",
               "call_id" => "call_0",
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Sing",
               "status" => "incomplete"
             }
           ]
  end

  test "SPEC.md §7.2.7 streaming caller disconnect uses cancellation with incomplete output" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        tool_call_event("call_0", %{
          index: 0,
          type: "function",
          function: %{name: "lookup_weather", arguments_delta: "{\"city\":\"Sing"}
        }),
        InferenceEvent.failed("request_caller_disconnect", "caller exited", false)
      ],
      execute: {:ok, stub_responses_canonical(true), []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)
    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "incomplete"

    assert terminal.data["response"]["error"] == %{
             "type" => "server_error",
             "code" => "request_cancelled",
             "message" => "Request was cancelled",
             "param" => nil
           }

    assert terminal.data["response"]["output"] == [
             %{
               "type" => "function_call",
               "id" => "call_0",
               "call_id" => "call_0",
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Sing",
               "status" => "incomplete"
             }
           ]
  end

  test "streaming tagged tool-outcome cancellation stays incomplete during fallback finalization" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        tool_call_event("call_0", %{
          index: 0,
          type: "function",
          function: %{name: "lookup_weather", arguments_delta: "{\"city\":\"Sing"}
        })
      ],
      execute: {:error, {:tool_execution_outcome, %{status: :cancelled}}}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)
    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "incomplete"
    assert terminal.data["response"]["error"]["code"] == "tool_execution_cancelled"
    assert terminal.data["response"]["error"]["message"] == "Tool execution was cancelled"

    assert terminal.data["response"]["output"] == [
             %{
               "type" => "function_call",
               "id" => "call_0",
               "call_id" => "call_0",
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Sing",
               "status" => "incomplete"
             }
           ]
  end

  test "streaming generic execute errors remain failed during fallback finalization even with partial tool calls" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        tool_call_event("call_0", %{
          index: 0,
          type: "function",
          function: %{name: "lookup_weather", arguments_delta: "{\"city\":\"Sing"}
        })
      ],
      execute: {:error, {:terminal_persist_failed, :boom}}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)
    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "failed"
    assert terminal.data["response"]["error"]["code"] == "internal_error"
    assert terminal.data["response"]["error"]["message"] == "Internal error"

    assert terminal.data["response"]["output"] == [
             %{
               "type" => "function_call",
               "id" => "call_0",
               "call_id" => "call_0",
               "name" => "lookup_weather",
               "arguments" => "{\"city\":\"Sing",
               "status" => "incomplete"
             }
           ]
  end

  test "SPEC.md §7.2.7 streaming busy and queue execute errors use nested response.error" do
    cases = [
      {:model_busy, "server_error", "model_busy"},
      {:queue_full, "rate_limit_error", "queue_full"},
      {:queue_timeout, "server_error", "queue_timeout"}
    ]

    for {reason, type, code} <- cases do
      stub_responses_orchestrator(
        prepare: {:ok, stub_responses_canonical(true), %{}},
        execute: {:error, reason}
      )

      conn =
        post_responses(%{
          "model" => "stub-tool-model@v1",
          "input" => "hello",
          "stream" => true
        })

      assert conn.status == 200
      events = parse_typed_sse_events(conn)
      assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

      terminal = List.last(events)
      assert terminal.data["error"] == nil
      assert terminal.data["response"]["status"] == "failed"
      assert terminal.data["response"]["error"]["type"] == type
      assert terminal.data["response"]["error"]["code"] == code
    end
  end

  test "malformed post-start tool-call delta emits typed response.failed and no output_text.done" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        InferenceEvent.tool_call_delta("call_0", "not-json"),
        InferenceEvent.completed(:finish_reason_tool_calls, nil)
      ],
      capture_handler_pid: self(),
      execute: {:ok, stub_responses_canonical(true), []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    assert resp_header(conn, "content-type") == ["text/event-stream"]

    events = parse_typed_sse_events(conn)
    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

    created = hd(events)
    assert created.data["response"]["status"] == "in_progress"

    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "failed"
    assert terminal.data["response"]["output_text"] == ""
    assert terminal.data["response"]["output"] == []
    assert terminal.data["response"]["error"]["type"] == "server_error"
    assert terminal.data["response"]["error"]["code"] == "internal_error"

    assert String.starts_with?(
             terminal.data["response"]["error"]["message"],
             "Malformed tool call delta:"
           )

    assert Enum.filter(events, &(&1.type == "response.output_text.done")) == []

    body = collect_chunked_body(conn)
    refute String.contains?(body, "[DONE]")

    assert_receive {:handler_result, :accepted, :ok}
    assert_receive {:handler_result, :tool_call_delta, {:error, :serializer_failed}}
    refute_receive {:handler_result, :completed, _result}
  end

  test "post-commit serializer failure keeps typed SSE shape and durable commitment",
       %{bundle: bundle} do
    put_queue_admission_config!()

    put_blocking_runtime_adapter!(self(),
      events: [
        InferenceEvent.tool_call_delta("call-stable", "not-json"),
        InferenceEvent.completed(:finish_reason_tool_calls, nil)
      ]
    )

    create_queue_model!(bundle, "responses-queue-overlap-model")
    %{token: token} = create_api_key_with_token!("responses-tool-serializer-failure")

    task =
      Task.async(fn ->
        post_responses(
          %{
            "model" => "responses-queue-overlap-model@v1",
            "input" => "call a tool",
            "stream" => true
          },
          token
        )
      end)

    assert_receive {:queue_admission_runtime_started, runtime_pid, request_id,
                    "responses-queue-overlap-model"},
                   2_000

    send(runtime_pid, :queue_admission_runtime_release)
    conn = Task.await(task, 5_000)
    events = parse_typed_sse_events(conn)

    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]
    assert hd(events).data["response"]["status"] == "in_progress"
    assert List.last(events).data["response"]["status"] == "failed"
    refute String.contains?(collect_chunked_body(conn), "[DONE]")

    request = Requests.get_request_by_public_id(request_id)
    assert request.state == :failed
    assert_tool_serializer_failure!(request)
  end

  test "SPEC 7.5.5 streaming terminal conformance failure emits response.failed" do
    stub_responses_orchestrator(
      prepare: {:ok, stub_responses_canonical(true), %{}},
      events: [
        InferenceEvent.accepted(1_710_000_123_000),
        InferenceEvent.failed(
          "runtime_endpoint_missing_terminal",
          "Runtime Endpoint stream ended without a terminal event",
          false
        )
      ],
      execute: {:ok, stub_responses_canonical(true), []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    events = parse_typed_sse_events(conn)
    assert Enum.map(events, & &1.type) == ["response.created", "response.failed"]

    terminal = List.last(events)
    assert terminal.data["response"]["status"] == "failed"
    assert terminal.data["response"]["error"]["type"] == "server_error"
    assert terminal.data["response"]["error"]["code"] == "internal_error"
    assert terminal.data["response"]["error"]["message"] == "Internal error"
    refute String.contains?(collect_chunked_body(conn), "[DONE]")
  end

  test "SPEC 5.3 response.failed does not serialize a cumulative lower bound as exact usage" do
    canonical = stub_responses_canonical(true)

    stub_responses_orchestrator(
      prepare: {:ok, canonical, %{}},
      events: [
        InferenceEvent.usage_update(%InferenceEvent.Usage{
          input_tokens: 3,
          output_tokens: 5,
          total_tokens: 8
        }),
        InferenceEvent.failed("cancelled", "request cancelled", false)
      ],
      execute: {:ok, canonical, []}
    )

    conn =
      post_responses(%{
        "model" => "stub-tool-model@v1",
        "input" => "hello",
        "stream" => true
      })

    assert conn.status == 200
    terminal = conn |> parse_typed_sse_events() |> List.last()
    assert terminal.type == "response.failed"

    assert terminal.data["response"]["usage"] == %{
             "input_tokens" => 0,
             "output_tokens" => 0,
             "total_tokens" => 0
           }
  end

  test "post-start failure emits response.created then response.failed with no [DONE]" do
    %{tenant: tenant, token: token} = create_api_key_with_token!("responses-stream-fail")

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

    grant_active_models!(tenant)

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

    # No response.output_text.done should be emitted before terminal when no text deltas were sent
    done_events = Enum.filter(events, &(&1.type == "response.output_text.done"))
    assert done_events == []

    # Must end with response.failed (terminal)
    terminal = List.last(events)
    assert terminal.type == "response.failed"
    assert terminal.data["response"]["status"] == "failed"
    assert terminal.data["response"]["error"] != nil
    assert terminal.data["response"]["error"]["type"] != nil

    # No [DONE] in stream
    body = collect_chunked_body(conn)
    refute String.contains?(body, "[DONE]")

    # first_token_at must be nil when failure occurs before any output delta
    response_id = terminal.data["response"]["id"]
    request = Requests.get_request_by_public_id(response_id)
    assert request != nil
    assert request.state == :failed
    assert request.first_token_at == nil
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

  test "streaming tool-calling request against a model without tool_calling capability returns JSON tooling_not_supported",
       %{bundle: bundle} do
    _model =
      create_model!(%{
        model_id: "responses-stream-tool-gate-model",
        version: "v1",
        display_name: "Responses Stream Tool Gate Model",
        artifact_uri: "file:///tmp/responses-stream-tool-gate-model",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file:///tmp/responses-stream-tool-gate-model",
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
      post_responses(%{
        "model" => "responses-stream-tool-gate-model@v1",
        "input" => "hello",
        "stream" => true,
        "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
        "tool_choice" => "auto"
      })

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "invalid_request_error"
    assert body["error"]["code"] == "tooling_not_supported"
    assert body["error"]["param"] == "model"
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

  defp stub_responses_orchestrator(config) do
    Application.put_env(
      :orchard_controller,
      :api_responses_orchestrator_impl,
      __MODULE__.StubResponsesOrchestrator
    )

    Process.put({__MODULE__, :stub_responses_orchestrator}, config)
  end

  defp clear_responses_stub_config do
    Process.delete({__MODULE__, :stub_responses_orchestrator})
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)

  defp stub_responses_canonical(stream?) do
    Orchard.CanonicalRequest.new(%{
      internal_id: Ecto.UUID.generate(),
      public_id: "resp_tool_stub",
      endpoint: :responses,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %{model_id: "stub-tool-model", version: "v1"},
      input_items: [%{"role" => "user", "content" => "hello"}],
      rendered_prompt: "hello",
      input_token_count: 3,
      stream?: stream?,
      metadata: %{}
    })
  end

  defp tool_call_event(tool_call_id, delta) do
    InferenceEvent.tool_call_delta(tool_call_id, Jason.encode!(delta))
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
          {"responses-stream-model", "v1"},
          {"responses-queue-overlap-model", "v1"},
          {"responses-queue-capacity2-model", "v1"},
          {"responses-queue-tenant-active-cap-model", "v1"}
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

  defmodule StubResponsesOrchestrator do
    alias Orchard.Inference.ResponsesOrchestrator

    def prepare(params, caller_context) do
      config =
        Process.get({Orchard.API.ResponsesControllerTest, :stub_responses_orchestrator}, %{})

      if Keyword.get(config, :prepare_real, false) do
        ResponsesOrchestrator.prepare(params, caller_context)
      else
        Keyword.fetch!(config, :prepare)
      end
    end

    def execute(canonical, model, opts) do
      config =
        Process.get({Orchard.API.ResponsesControllerTest, :stub_responses_orchestrator}, %{})

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

  defp remember_runtime_pid(pid) do
    pids = Process.get(:queue_admission_runtime_pids, [])
    Process.put(:queue_admission_runtime_pids, [pid | pids])
  end
end
