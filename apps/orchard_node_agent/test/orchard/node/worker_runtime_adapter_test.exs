defmodule Orchard.Node.WorkerRuntimeAdapterTest do
  use ExUnit.Case, async: false

  alias Orchard.Node.WorkerRuntimeAdapter

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

  test "effective_worker_request_limit keeps WorkerRuntimeAdapter single-flight in batch mode", %{
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

    assert Node.effective_worker_request_limit() == 1
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

  test "test-only non-worker batch flag is ignored for real WorkerRuntimeAdapter", %{
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

    assert Node.effective_worker_request_limit() == 1
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
