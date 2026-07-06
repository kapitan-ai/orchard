defmodule Orchard.Node.WorkerRuntimeAdapterTest do
  use ExUnit.Case, async: false

  alias GRPC.Client.Connection
  alias GRPC.RPCError

  alias Orchard.Cluster.V1.{
    Ack,
    CancelInferenceRequest,
    ExecuteInferenceRequest,
    InferenceEvent,
    ModelRef,
    ScorePrefixCacheRequest,
    ScorePrefixCacheResponse
  }

  alias Orchard.Cluster.V1.OutputTextDelta, as: ProtoOutputTextDelta

  alias Orchard.Node.Worker.V1.{
    LoadModelRequest,
    WorkerMemoryBudgetStatus,
    WorkerPrefixCacheStatus,
    WorkerRuntimeService,
    WorkerStatusRequest,
    WorkerStatusResponse
  }

  alias Orchard.InferenceEvent, as: DomainInferenceEvent
  alias Orchard.InferenceEvent.OutputTextDelta
  alias Orchard.Node.WorkerRuntimeAdapter

  defmodule OpenUnavailableWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    def get_status(%WorkerStatusRequest{}, _stream), do: %WorkerStatusResponse{ready: true}
    def load_model(%LoadModelRequest{}, _stream), do: %Ack{ok: true}
    def unload_model(_request, _stream), do: %Ack{ok: true}
    def cancel(%CancelInferenceRequest{}, _stream), do: %Ack{ok: true}

    def generate(%ExecuteInferenceRequest{}, _stream) do
      raise RPCError, status: :unavailable, message: "worker unavailable"
    end
  end

  defmodule OpenUnavailableEndpoint do
    use GRPC.Endpoint

    run(OpenUnavailableWorkerService)
  end

  defmodule MidStreamUnavailableWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    def get_status(%WorkerStatusRequest{}, _stream), do: %WorkerStatusResponse{ready: true}
    def load_model(%LoadModelRequest{}, _stream), do: %Ack{ok: true}
    def unload_model(_request, _stream), do: %Ack{ok: true}
    def cancel(%CancelInferenceRequest{}, _stream), do: %Ack{ok: true}

    def generate(%ExecuteInferenceRequest{}, stream) do
      GRPC.Server.send_reply(
        stream,
        %InferenceEvent{event: {:output_text_delta, %ProtoOutputTextDelta{delta: "partial"}}}
      )

      raise RPCError, status: :unavailable, message: "worker unavailable"
    end
  end

  defmodule MidStreamUnavailableEndpoint do
    use GRPC.Endpoint

    run(MidStreamUnavailableWorkerService)
  end

  defmodule MemoryBudgetWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    @fingerprint_a "hmac-sha256:" <> String.duplicate("a", 64)
    @fingerprint_b "hmac-sha256:" <> String.duplicate("b", 64)

    def get_status(%WorkerStatusRequest{}, _stream) do
      %WorkerStatusResponse{
        ready: true,
        health_code: "",
        health_message: "",
        max_concurrency: 2,
        memory_budget: %WorkerMemoryBudgetStatus{
          mode: "observe",
          budget_available: true,
          headroom_available: true,
          status_code: "ok",
          status_message: "",
          source: "mlx.core.device_info.max_recommended_working_set_size",
          max_recommended_working_set_size_bytes: 8_000_000_000,
          utilization: 0.75,
          target_working_set_bytes: 6_000_000_000,
          overhead_bytes: 268_435_456,
          resident_memory_bytes: 2_048_000,
          estimated_headroom_bytes: 5_731_516_544,
          kv_cache_bytes_per_token: 16_384,
          prefill_workspace_bytes_per_token: 2_048,
          recommended_context_tokens: 131_072
        },
        prefix_cache: %WorkerPrefixCacheStatus{
          implementation: "kv",
          enabled: true,
          entry_count: 2,
          total_bytes: 32_768,
          hits: 12,
          misses: 4,
          failures: 1,
          stores: 8,
          evictions: 3,
          configured_max_entries: 64,
          configured_max_bytes: 1_048_576,
          status_code: "ok",
          status_message: "",
          session_started_unix_ms: 1_713_726_400_000,
          prefix_cache_fingerprints: [
            @fingerprint_a,
            "hmac-sha256:" <> String.duplicate("A", 64),
            @fingerprint_b,
            "not-a-fingerprint"
          ]
        }
      }
    end

    def load_model(%LoadModelRequest{}, _stream), do: %Ack{ok: true}
    def unload_model(_request, _stream), do: %Ack{ok: true}
    def cancel(%CancelInferenceRequest{}, _stream), do: %Ack{ok: true}
    def generate(%ExecuteInferenceRequest{}, _stream), do: raise("not used")
  end

  defmodule MemoryBudgetEndpoint do
    use GRPC.Endpoint

    run(MemoryBudgetWorkerService)
  end

  defmodule PromptTokenIdsSupportWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    def get_status(%WorkerStatusRequest{}, _stream) do
      %WorkerStatusResponse{ready: true, supports_prompt_token_ids: true}
    end

    def load_model(%LoadModelRequest{}, _stream), do: %Ack{ok: true}
    def unload_model(_request, _stream), do: %Ack{ok: true}
    def cancel(%CancelInferenceRequest{}, _stream), do: %Ack{ok: true}
    def generate(%ExecuteInferenceRequest{}, _stream), do: raise("not used")
  end

  defmodule PromptTokenIdsSupportEndpoint do
    use GRPC.Endpoint

    run(PromptTokenIdsSupportWorkerService)
  end

  defmodule LegacyPromptTokenIdsWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    def get_status(%WorkerStatusRequest{}, _stream), do: %WorkerStatusResponse{ready: true}
    def load_model(%LoadModelRequest{}, _stream), do: %Ack{ok: true}
    def unload_model(_request, _stream), do: %Ack{ok: true}
    def cancel(%CancelInferenceRequest{}, _stream), do: %Ack{ok: true}
    def generate(%ExecuteInferenceRequest{}, _stream), do: raise("not used")
  end

  defmodule LegacyPromptTokenIdsEndpoint do
    use GRPC.Endpoint

    run(LegacyPromptTokenIdsWorkerService)
  end

  defmodule ScorePrefixCacheWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    def get_status(%WorkerStatusRequest{}, _stream), do: %WorkerStatusResponse{ready: true}
    def load_model(%LoadModelRequest{}, _stream), do: %Ack{ok: true}
    def unload_model(_request, _stream), do: %Ack{ok: true}
    def cancel(%CancelInferenceRequest{}, _stream), do: %Ack{ok: true}
    def generate(%ExecuteInferenceRequest{}, _stream), do: raise("not used")

    def score_prefix_cache(%ScorePrefixCacheRequest{request_id: "ok"}, _stream) do
      %ScorePrefixCacheResponse{
        status_code: "ok",
        status_message: "scored",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 1_713_726_400_000
      }
    end

    def score_prefix_cache(%ScorePrefixCacheRequest{request_id: "unknown"}, _stream) do
      %ScorePrefixCacheResponse{
        status_code: "not_allowed",
        status_message: "bad",
        resident_fingerprint_match: true,
        score_tier: "not_a_tier",
        session_started_unix_ms: 0
      }
    end

    def score_prefix_cache(%ScorePrefixCacheRequest{request_id: "contradictory_timeout"}, _stream) do
      %ScorePrefixCacheResponse{
        status_code: "timeout",
        status_message: "too slow",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 1_713_726_400_000
      }
    end

    def score_prefix_cache(%ScorePrefixCacheRequest{request_id: "timeout"}, _stream) do
      raise RPCError, status: :deadline_exceeded, message: "too slow"
    end

    def score_prefix_cache(%ScorePrefixCacheRequest{request_id: "unimplemented"}, _stream) do
      raise RPCError, status: :unimplemented, message: "missing"
    end
  end

  defmodule ScorePrefixCacheEndpoint do
    use GRPC.Endpoint

    run(ScorePrefixCacheWorkerService)
  end

  test "worker_cli_args omits generation and memory flags for default-compatible values" do
    args =
      WorkerRuntimeAdapter.worker_cli_args(
        socket_path: "/tmp/worker.sock",
        backend: "stub",
        log_path: "/tmp/worker.log"
      )

    assert args == [
             "--socket-path",
             "/tmp/worker.sock",
             "--backend",
             "stub",
             "--log-file",
             "/tmp/worker.log",
             "--prefix-cache-mode",
             "kv",
             "--prefix-cache-max-entries",
             "8",
             "--prefix-cache-max-bytes",
             "0"
           ]

    refute "--generation-mode" in args
    refute "--memory-budget-mode" in args
  end

  test "worker_cli_args serializes extended generation and memory flags with compact utilization" do
    args =
      WorkerRuntimeAdapter.worker_cli_args(
        socket_path: "/tmp/worker.sock",
        backend: "mlx",
        log_path: "/tmp/worker.log",
        generation_mode: "batch",
        max_concurrent_generations: 3,
        memory_budget_mode: "disabled",
        memory_budget_utilization: 0.7500,
        memory_budget_overhead_bytes: 268_435_456
      )

    assert flag_value(args, "--generation-mode") == "batch"
    assert flag_value(args, "--max-concurrent-generations") == "3"
    assert flag_value(args, "--auto-max-concurrent-generations") == "3"
    assert flag_value(args, "--memory-budget-mode") == "disabled"
    assert flag_value(args, "--memory-budget-utilization") == "0.75"
    assert flag_value(args, "--memory-budget-overhead-bytes") == "268435456"
  end

  test "worker_cli_args normalizes integer memory_budget_utilization for serialization" do
    args =
      WorkerRuntimeAdapter.worker_cli_args(
        socket_path: "/tmp/worker.sock",
        backend: "mlx",
        log_path: "/tmp/worker.log",
        memory_budget_mode: "disabled",
        memory_budget_utilization: 1,
        memory_budget_overhead_bytes: 0
      )

    assert flag_value(args, "--memory-budget-utilization") in ["1", "1.0"]
  end

  test "worker_cli_args raises for non-numeric memory_budget_utilization" do
    assert_raise ArgumentError,
                 ~r/memory_budget_utilization must be an integer or float/,
                 fn ->
                   WorkerRuntimeAdapter.worker_cli_args(
                     socket_path: "/tmp/worker.sock",
                     backend: "mlx",
                     log_path: "/tmp/worker.log",
                     memory_budget_mode: "disabled",
                     memory_budget_utilization: "0.9",
                     memory_budget_overhead_bytes: 0
                   )
                 end

    assert_raise ArgumentError,
                 ~r/memory_budget_utilization must be an integer or float/,
                 fn ->
                   WorkerRuntimeAdapter.worker_cli_args(
                     socket_path: "/tmp/worker.sock",
                     backend: "mlx",
                     log_path: "/tmp/worker.log",
                     memory_budget_mode: "disabled",
                     memory_budget_utilization: false,
                     memory_budget_overhead_bytes: 0
                   )
                 end
  end

  test "get_status maps prompt token id support from worker status proto" do
    with_worker_runtime_server(PromptTokenIdsSupportEndpoint, fn channel ->
      assert {:ok, status} = WorkerRuntimeAdapter.get_status(%{channel: channel}, timeout_ms: 500)

      assert status.supports_prompt_token_ids == true
    end)
  end

  test "get_status defaults prompt token id support to false for legacy worker status" do
    with_worker_runtime_server(LegacyPromptTokenIdsEndpoint, fn channel ->
      assert {:ok, status} = WorkerRuntimeAdapter.get_status(%{channel: channel}, timeout_ms: 500)

      assert status.supports_prompt_token_ids == false
    end)
  end

  test "get_status maps memory budget fields from worker status proto" do
    with_worker_runtime_server(MemoryBudgetEndpoint, fn channel ->
      assert {:ok, status} = WorkerRuntimeAdapter.get_status(%{channel: channel}, timeout_ms: 500)

      assert status.ready == true
      assert status.health_code == ""
      assert status.max_concurrency == 2
      assert status.memory_budget.mode == "observe"
      assert status.memory_budget.budget_available == true
      assert status.memory_budget.status_code == "ok"
      assert status.memory_budget.target_working_set_bytes == 6_000_000_000
      assert status.memory_budget.estimated_headroom_bytes == 5_731_516_544
      assert status.memory_budget.recommended_context_tokens == 131_072
      assert status.prefix_cache_status.implementation == "kv"
      assert status.prefix_cache_status.enabled == true
      assert status.prefix_cache_status.entry_count == 2
      assert status.prefix_cache_status.total_bytes == 32_768
      assert status.prefix_cache_status.status_code == "ok"
      assert status.prefix_cache_status.session_started_unix_ms == 1_713_726_400_000

      assert status.prefix_cache_status.prefix_cache_fingerprints == [
               "hmac-sha256:" <> String.duplicate("a", 64),
               "hmac-sha256:" <> String.duplicate("b", 64)
             ]
    end)
  end

  test "connect_worker_socket uses a direct UDS channel without connection supervisor refresh" do
    with_worker_runtime_unix_server(MemoryBudgetEndpoint, fn channel, socket_path ->
      assert %GRPC.Channel{
               host: {:local, host_path},
               port: 0,
               scheme: "unix",
               adapter_payload: %{conn_pid: conn_pid}
             } = channel

      assert host_path == String.to_charlist(socket_path)
      assert is_pid(conn_pid)
      assert {:error, :no_connection} = Connection.pick_channel(channel)

      assert {:ok, status} = WorkerRuntimeAdapter.get_status(%{channel: channel}, timeout_ms: 500)
      assert status.ready == true
    end)
  end

  test "score_prefix_cache normalizes successful worker responses" do
    with_worker_runtime_server(ScorePrefixCacheEndpoint, fn channel ->
      assert {:ok, response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_prefix_cache_request(),
                 timeout_ms: 500
               )

      assert response.status_code == "ok"
      assert response.resident_fingerprint_match == true
      assert response.score_tier == "resident_fingerprint"
      assert response.session_started_unix_ms == 1_713_726_400_000
    end)
  end

  test "score_prefix_cache maps expired local timeout to timeout without RPC" do
    assert {:ok, response} =
             WorkerRuntimeAdapter.score_prefix_cache(
               %{channel: :not_used},
               score_prefix_cache_request(),
               timeout_ms: 0
             )

    assert response.status_code == "timeout"
    assert response.score_tier == "unknown"
  end

  test "score_prefix_cache maps worker UNIMPLEMENTED to unsupported_version" do
    with_worker_runtime_server(ScorePrefixCacheEndpoint, fn channel ->
      assert {:ok, response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_request("unimplemented"),
                 timeout_ms: 500
               )

      assert response.status_code == "unsupported_version"
      assert response.score_tier == "unknown"
      assert response.resident_fingerprint_match == false
    end)
  end

  test "normalize_score clamps unknown status and tier values" do
    normalized =
      WorkerRuntimeAdapter.normalize_score(%{
        status_code: "surprise",
        status_message: "ok",
        resident_fingerprint_match: true,
        score_tier: "bad-tier",
        session_started_unix_ms: -1
      })

    assert normalized.status_code == "error"
    assert normalized.score_tier == "unknown"
    assert normalized.resident_fingerprint_match == false
    assert normalized.session_started_unix_ms == 0
  end

  test "normalize_score enforces ScorePrefixCache diagnostic invariants" do
    cases = [
      {%{
         status_code: "timeout",
         resident_fingerprint_match: true,
         score_tier: "resident_fingerprint"
       }, "timeout", false, "unknown"},
      {%{
         status_code: "ok",
         resident_fingerprint_match: false,
         score_tier: "resident_fingerprint"
       }, "ok", false, "unknown"},
      {%{status_code: "ok", resident_fingerprint_match: true, score_tier: "no_match"}, "ok",
       false, "unknown"},
      {%{
         status_code: "ok",
         resident_fingerprint_match: false,
         score_tier: "recent_fingerprint_only"
       }, "ok", false, "recent_fingerprint_only"}
    ]

    for {input, status_code, resident?, score_tier} <- cases do
      response = WorkerRuntimeAdapter.normalize_score(input)

      assert response.status_code == status_code
      assert response.resident_fingerprint_match == resident?
      assert response.score_tier == score_tier
    end
  end

  test "score_prefix_cache returns unavailable when adapter state lacks a channel" do
    assert {:ok, response} =
             WorkerRuntimeAdapter.score_prefix_cache(%{}, score_prefix_cache_request(),
               timeout_ms: 500
             )

    assert response.status_code == "unavailable"
  end

  test "score_prefix_cache normalizes worker success and malformed values" do
    with_worker_runtime_server(ScorePrefixCacheEndpoint, fn channel ->
      assert {:ok, ok_response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_request("ok"),
                 timeout_ms: 300
               )

      assert ok_response.status_code == "ok"
      assert ok_response.score_tier == "resident_fingerprint"
      assert ok_response.resident_fingerprint_match == true

      assert {:ok, malformed_response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_request("unknown"),
                 timeout_ms: 300
               )

      assert malformed_response.status_code == "error"
      assert malformed_response.score_tier == "unknown"
      assert malformed_response.session_started_unix_ms == 0

      assert {:ok, contradictory_response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_request("contradictory_timeout"),
                 timeout_ms: 300
               )

      assert contradictory_response.status_code == "timeout"
      assert contradictory_response.score_tier == "unknown"
      assert contradictory_response.resident_fingerprint_match == false
    end)
  end

  test "score_prefix_cache maps timeout and unimplemented transport statuses" do
    with_worker_runtime_server(ScorePrefixCacheEndpoint, fn channel ->
      assert {:ok, timeout_response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_request("timeout"),
                 timeout_ms: 300
               )

      assert timeout_response.status_code == "timeout"
      assert timeout_response.score_tier == "unknown"

      assert {:ok, unsupported_response} =
               WorkerRuntimeAdapter.score_prefix_cache(
                 %{channel: channel},
                 score_request("unimplemented"),
                 timeout_ms: 300
               )

      assert unsupported_response.status_code == "unsupported_version"
      assert unsupported_response.score_tier == "unknown"
    end)
  end

  test "score_prefix_cache returns unavailable when adapter state has no channel" do
    assert {:ok, response} =
             WorkerRuntimeAdapter.score_prefix_cache(
               %{},
               score_request("ok"),
               timeout_ms: 300
             )

    assert response.status_code == "unavailable"
    assert response.score_tier == "unknown"
  end

  test "start_generation sends runtime_adapter_done when stream open returns worker_unavailable" do
    with_worker_runtime_server(OpenUnavailableEndpoint, fn channel ->
      state = adapter_stream_state(channel)
      request = execute_request("req-open-unavailable")

      {:ok, generation_ref, adapter_state} =
        WorkerRuntimeAdapter.start_generation(state, request, owner: self())

      assert Map.has_key?(adapter_state.generations, generation_ref)
      assert adapter_state.generations[generation_ref].request_id == request.request_id
      assert_receive {:runtime_adapter_done, ^generation_ref, :worker_unavailable}, 1_000
      refute_receive {:runtime_adapter_event, ^generation_ref, _event}, 100

      cleaned_state = WorkerRuntimeAdapter.finish_generation(adapter_state, generation_ref, [])
      refute Map.has_key?(cleaned_state.generations, generation_ref)
    end)
  end

  test "start_generation sends runtime_adapter_done when stream becomes unavailable after non-terminal event" do
    with_worker_runtime_server(MidStreamUnavailableEndpoint, fn channel ->
      state = adapter_stream_state(channel)
      request = execute_request("req-mid-stream-unavailable")

      {:ok, generation_ref, adapter_state} =
        WorkerRuntimeAdapter.start_generation(state, request, owner: self())

      assert_receive {
                       :runtime_adapter_event,
                       ^generation_ref,
                       %DomainInferenceEvent{event: %OutputTextDelta{delta: "partial"}}
                     },
                     1_000

      assert_receive {:runtime_adapter_done, ^generation_ref, :worker_unavailable}, 1_000
      refute_receive {:runtime_adapter_event, ^generation_ref, _event}, 100

      cleaned_state = WorkerRuntimeAdapter.finish_generation(adapter_state, generation_ref, [])
      refute Map.has_key?(cleaned_state.generations, generation_ref)
    end)
  end

  test "start_generation sends generation_task_failed when the stream task crashes unexpectedly" do
    state = adapter_stream_state(:invalid_channel)
    request = execute_request("req-task-crash")

    {:ok, generation_ref, adapter_state} =
      WorkerRuntimeAdapter.start_generation(state, request, owner: self())

    assert_receive {:runtime_adapter_done, ^generation_ref,
                    {:generation_task_failed, kind, _reason}},
                   1_000

    assert kind in [:error, :exit]

    cleaned_state = WorkerRuntimeAdapter.finish_generation(adapter_state, generation_ref, [])
    refute Map.has_key?(cleaned_state.generations, generation_ref)
  end

  defp with_worker_runtime_server(endpoint, fun)
       when is_atom(endpoint) and is_function(fun, 1) do
    port = free_tcp_port()

    start_supervised!({
      GRPC.Server.Supervisor,
      endpoint: endpoint, port: port, start_server: true, adapter_opts: [ip: {127, 0, 0, 1}]
    })

    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")

    try do
      wait_for_worker_service_ready(channel)
      fun.(channel)
    after
      _ = GRPC.Stub.disconnect(channel)
    end
  end

  defp with_worker_runtime_unix_server(endpoint, fun)
       when is_atom(endpoint) and is_function(fun, 2) do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-worker-runtime-adapter-#{System.unique_integer([:positive])}.sock"
      )

    File.rm(socket_path)

    start_supervised!({
      GRPC.Server.Supervisor,
      endpoint: endpoint, port: 0, start_server: true, adapter_opts: [ip: {:local, socket_path}]
    })

    {:ok, channel} = WorkerRuntimeAdapter.connect_worker_socket(socket_path)

    try do
      wait_for_worker_service_ready(channel)
      fun.(channel, socket_path)
    after
      _ = channel.adapter.disconnect(channel)
      File.rm(socket_path)
    end
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_worker_service_ready(channel, attempts \\ 20)

  defp wait_for_worker_service_ready(_channel, 0) do
    flunk("worker runtime test server did not become ready")
  end

  defp wait_for_worker_service_ready(channel, attempts) do
    case WorkerRuntimeService.Stub.get_status(channel, %WorkerStatusRequest{}, timeout: 500) do
      {:ok, %WorkerStatusResponse{ready: true}} ->
        :ok

      _other ->
        Process.sleep(25)
        wait_for_worker_service_ready(channel, attempts - 1)
    end
  end

  defp adapter_stream_state(channel), do: %{channel: channel, generations: %{}}

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "worker-runtime-adapter-test",
      model_id: "test/unavailable-stream",
      version: "v1",
      rendered_prompt_utf8: "hello",
      input_tokens: 1,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }
  end

  defp score_prefix_cache_request do
    %ScorePrefixCacheRequest{
      request_id: "ok",
      controller_session_id: "worker-runtime-adapter-test",
      model_ref: %ModelRef{model_id: "test/unavailable-stream", version: "v1"},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }
  end

  defp flag_value(args, flag) do
    args
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _other -> nil
    end)
  end

  defp score_request(request_id) do
    %ScorePrefixCacheRequest{
      request_id: request_id,
      controller_session_id: "worker-runtime-adapter-test",
      model_ref: %ModelRef{model_id: "test/model", version: "v1"},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 1_000
    }
  end
end

defmodule Orchard.NodeTest do
  use ExUnit.Case, async: false

  alias Orchard.Node

  setup do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end)

    %{previous_runtime: previous_runtime}
  end

  test "effective_worker_request_limit allows WorkerRuntimeAdapter batch admission", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime,
        runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 3
      )
    )

    assert Node.effective_worker_request_limit() == 3
  end

  test "effective_worker_request_limit uses auto upper bound for WorkerRuntimeAdapter batch admission",
       %{
         previous_runtime: previous_runtime
       } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime,
        runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: "auto",
        worker_auto_max_concurrent_requests_per_model: 4
      )
    )

    assert Node.effective_worker_request_limit() == 4
  end

  test "effective_worker_request_limit keeps non-worker adapters single-flight without explicit opt-in",
       %{
         previous_runtime: previous_runtime
       } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime,
        runtime_adapter_impl: Orchard.Node.FakeRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 3
      )
    )

    assert Node.effective_worker_request_limit() == 1
  end

  test "effective_worker_request_limit allows batch for test adapters only with explicit opt-in",
       %{
         previous_runtime: previous_runtime
       } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime,
        runtime_adapter_impl: Orchard.Node.FakeRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 3,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      )
    )

    assert Node.effective_worker_request_limit() == 3
  end

  test "worker_memory_budget_mode accepts enforce mode and rejects unknown modes", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_memory_budget_mode: "enforce")
    )

    assert Node.worker_memory_budget_mode() == "enforce"

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_memory_budget_mode: "aggressive")
    )

    assert_raise RuntimeError, ~r/invalid worker_memory_budget_mode/, fn ->
      Node.worker_memory_budget_mode()
    end
  end

  test "worker_memory_budget_utilization normalizes integer values", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_memory_budget_utilization: 1)
    )

    assert Node.worker_memory_budget_utilization() == 1.0
  end

  test "worker_generation_mode fails fast on invalid values", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_generation_mode: "invalid")
    )

    assert_raise RuntimeError, ~r/invalid worker_generation_mode/, fn ->
      Node.worker_generation_mode()
    end
  end

  test "worker_max_concurrent_requests_per_model fails fast on invalid values", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_max_concurrent_requests_per_model: 0)
    )

    assert_raise RuntimeError, ~r/invalid worker_max_concurrent_requests_per_model/, fn ->
      Node.worker_max_concurrent_requests_per_model()
    end
  end

  test "worker_auto_max_concurrent_requests_per_model fails fast on invalid values", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_auto_max_concurrent_requests_per_model: 0)
    )

    assert_raise RuntimeError, ~r/invalid worker_auto_max_concurrent_requests_per_model/, fn ->
      Node.worker_auto_max_concurrent_requests_per_model()
    end
  end

  test "worker_memory_budget_utilization fails fast on invalid values", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_memory_budget_utilization: 1.5)
    )

    assert_raise RuntimeError, ~r/invalid worker_memory_budget_utilization/, fn ->
      Node.worker_memory_budget_utilization()
    end
  end

  test "worker_memory_budget_overhead_bytes fails fast on invalid values", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_memory_budget_overhead_bytes: -1)
    )

    assert_raise RuntimeError, ~r/invalid worker_memory_budget_overhead_bytes/, fn ->
      Node.worker_memory_budget_overhead_bytes()
    end
  end

  test "WorkerRuntimeAdapter batch admission does not depend on test-only non-worker flag", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime,
        runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 3,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      )
    )

    assert Node.effective_worker_request_limit() == 3
  end

  test "false values fail fast for worker config keys instead of defaulting", %{
    previous_runtime: previous_runtime
  } do
    assert_false_fails_fast(
      previous_runtime,
      :worker_prefix_cache_mode,
      &Node.worker_prefix_cache_mode/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_prefix_cache_max_entries,
      &Node.worker_prefix_cache_max_entries/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_prefix_cache_max_bytes,
      &Node.worker_prefix_cache_max_bytes/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_generation_mode,
      &Node.worker_generation_mode/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_max_concurrent_requests_per_model,
      &Node.worker_max_concurrent_requests_per_model/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_memory_budget_mode,
      &Node.worker_memory_budget_mode/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_memory_budget_utilization,
      &Node.worker_memory_budget_utilization/0
    )

    assert_false_fails_fast(
      previous_runtime,
      :worker_memory_budget_overhead_bytes,
      &Node.worker_memory_budget_overhead_bytes/0
    )
  end

  defp assert_false_fails_fast(previous_runtime, key, accessor) when is_function(accessor, 0) do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, [{key, false}])
    )

    assert_raise RuntimeError, fn -> accessor.() end
  end
end
