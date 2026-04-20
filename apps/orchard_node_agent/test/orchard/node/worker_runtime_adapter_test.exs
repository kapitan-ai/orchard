defmodule Orchard.Node.WorkerRuntimeAdapterTest do
  use ExUnit.Case, async: false

  alias GRPC.RPCError
  alias Orchard.Cluster.V1.{Ack, CancelInferenceRequest, ExecuteInferenceRequest, InferenceEvent}
  alias Orchard.Cluster.V1.OutputTextDelta, as: ProtoOutputTextDelta
  alias Orchard.Node.Worker.V1.{
    LoadModelRequest,
    WorkerRuntimeService,
    WorkerStatusRequest,
    WorkerStatusResponse
  }
  alias Orchard.Node.WorkerRuntimeAdapter
  alias Orchard.InferenceEvent, as: DomainInferenceEvent
  alias Orchard.InferenceEvent.OutputTextDelta

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

    assert_receive {:runtime_adapter_done, ^generation_ref, {:generation_task_failed, kind, _reason}},
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
      endpoint: endpoint,
      port: port,
      start_server: true,
      adapter_opts: [ip: {127, 0, 0, 1}]
    })

    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")

    try do
      wait_for_worker_service_ready(channel)
      fun.(channel)
    after
      _ = GRPC.Stub.disconnect(channel)
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
      {:ok, %WorkerStatusResponse{ready: true}} -> :ok
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

  defp flag_value(args, flag) do
    args
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _other -> nil
    end)
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

  test "worker_memory_budget_mode rejects unsupported enforce mode", %{
    previous_runtime: previous_runtime
  } do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, worker_memory_budget_mode: "enforce")
    )

    assert_raise RuntimeError, "worker_memory_budget_mode=enforce is not supported yet", fn ->
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
