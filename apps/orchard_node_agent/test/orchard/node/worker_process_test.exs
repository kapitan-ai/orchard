defmodule Orchard.Node.WorkerProcessTest do
  @moduledoc """
  Focused unit tests for WorkerProcess port line-buffering behavior.

  These tests exercise the {:noeol, partial} / {:eol, line} accumulation
  logic and the terminate/2 flush path by injecting synthetic port messages
  directly into a WorkerProcess GenServer, without spawning a real Python
  worker or the full node-agent stack.
  """

  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Node.WorkerProcess

  require Logger

  defmodule ConcurrentRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.Cluster.V1.ScorePrefixCacheResponse

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         memory_budget: memory_budget_status(),
         prefix_cache_status: prefix_cache_status()
       }}
    end

    defp memory_budget_status do
      %{
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
        prefill_workspace_bytes_per_token: 2_048
      }
    end

    defp prefix_cache_status do
      %{
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
        session_started_unix_ms: 1_713_726_400_000
      }
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, _opts) do
      generation_ref = make_ref()

      generations =
        Map.put(adapter_state.generations, generation_ref, %{request_id: request.request_id})

      {:ok, generation_ref, %{adapter_state | generations: generations}}
    end

    @impl true
    def cancel_generation(adapter_state, generation_ref, _opts) do
      {:ok, %{adapter_state | generations: Map.delete(adapter_state.generations, generation_ref)}}
    end

    @impl true
    def finish_generation(adapter_state, generation_ref, _opts) do
      %{adapter_state | generations: Map.delete(adapter_state.generations, generation_ref)}
    end

    def score_prefix_cache(_adapter_state, _request, _opts) do
      mode =
        Application.fetch_env!(:orchard_node_agent, :runtime)
        |> Keyword.get(:test_worker_process_score_mode, :ok)

      case mode do
        :contradictory_timeout ->
          {:ok,
           %ScorePrefixCacheResponse{
             status_code: "timeout",
             status_message: "timed out",
             resident_fingerprint_match: true,
             score_tier: "resident_fingerprint",
             session_started_unix_ms: 1_713_726_400_000
           }}

        :timeout ->
          {:error, :timeout}

        :ok ->
          {:ok,
           %ScorePrefixCacheResponse{
             status_code: "ok",
             resident_fingerprint_match: true,
             score_tier: "resident_fingerprint",
             session_started_unix_ms: 1_713_726_400_000
           }}
      end
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp start_worker_process! do
    model_ref = %ModelRef{model_id: "test/buffer-model", version: "v1"}

    {:ok, pid} =
      WorkerProcess.start_link(
        model_ref: model_ref,
        manager: self()
      )

    pid
  end

  defp ensure_load_request do
    %EnsureModelLoadedRequest{model_id: "test/buffer-model", version: "v1"}
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      model_id: "test/buffer-model",
      version: "v1"
    }
  end

  defp score_prefix_cache_request do
    %Orchard.Cluster.V1.ScorePrefixCacheRequest{
      request_id: "score-1",
      model_ref: %ModelRef{model_id: "test/buffer-model", version: "v1"},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }
  end

  defp with_runtime_config(overrides, fun) when is_list(overrides) and is_function(fun, 0) do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    Application.put_env(:orchard_node_agent, :runtime, Keyword.merge(previous_runtime, overrides))

    try do
      fun.()
    after
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end
  end

  defp open_test_port! do
    cat = System.find_executable("cat") || raise "cat not found on PATH"

    Port.open({:spawn_executable, String.to_charlist(cat)}, [
      :binary,
      :exit_status,
      {:line, 4096}
    ])
  end

  defp inject_adapter_state(pid, port) do
    :sys.replace_state(pid, fn state ->
      %{state | adapter_state: %{port: port}}
    end)
  end

  defp clear_adapter_state(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | adapter_state: nil}
    end)
  end

  defp inject_port_log_buffer(pid, buffer) do
    :sys.replace_state(pid, fn state ->
      %{state | port_log_buffer: buffer}
    end)
  end

  defp get_port_log_buffer(pid) do
    :sys.get_state(pid).port_log_buffer
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    unless fun.() do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      end

      Process.sleep(10)
      wait_until(fun, max(0, deadline - System.monotonic_time(:millisecond)))
    end
  end

  # -- Tests -----------------------------------------------------------------

  # test.exs sets Logger to :warning; these tests need :info to exercise
  # the forwarding path. Use try/after for crash-safe restoration.
  defp with_info_logger(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end

  test "noeol fragments are joined with subsequent eol into a single log line" do
    pid = start_worker_process!()
    port = open_test_port!()

    try do
      inject_adapter_state(pid, port)

      with_info_logger(fn ->
        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            # Send a partial line (noeol)
            send(pid, {port, {:data, {:noeol, "[INFO] test.join FIRST_"}}})
            wait_until(fn -> get_port_log_buffer(pid) == "[INFO] test.join FIRST_" end)

            # Send the rest (eol) — should join and log the full line
            send(pid, {port, {:data, {:eol, "SECOND_PART"}}})
            wait_until(fn -> get_port_log_buffer(pid) == <<>> end)
          end)

        # The joined line should appear exactly once in captured logs
        assert log =~ "FIRST_SECOND_PART"
        # Buffer should be cleared after eol
        assert get_port_log_buffer(pid) == <<>>
      end)
    after
      clear_adapter_state(pid)
      Port.close(port)
      GenServer.stop(pid, :normal, 1_000)
    end
  end

  test "score_prefix_cache returns model_not_loaded before worker load" do
    pid = start_worker_process!()

    response = WorkerProcess.score_prefix_cache(pid, score_prefix_cache_request())

    assert response.status_code == "model_not_loaded"
    assert response.score_tier == "unknown"
    assert response.resident_fingerprint_match == false
  end

  test "score_prefix_cache returns unsupported_version when adapter has no score hook" do
    with_runtime_config([runtime_adapter_impl: Orchard.Node.FakeRuntimeAdapter], fn ->
      pid = start_worker_process!()
      assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

      response = WorkerProcess.score_prefix_cache(pid, score_prefix_cache_request())

      assert response.status_code == "unsupported_version"
      assert response.score_tier == "unknown"
      assert response.resident_fingerprint_match == false
    end)
  end

  test "score_prefix_cache normalizes timeout responses from adapter" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        test_worker_process_score_mode: :timeout
      ],
      fn ->
        pid = start_worker_process!()
        assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

        response = WorkerProcess.score_prefix_cache(pid, score_prefix_cache_request())

        assert response.status_code == "timeout"
        assert response.score_tier == "unknown"
        assert response.resident_fingerprint_match == false
      end
    )
  end

  test "score_prefix_cache normalizes contradictory adapter response invariants" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        test_worker_process_score_mode: :contradictory_timeout
      ],
      fn ->
        pid = start_worker_process!()
        assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

        response = WorkerProcess.score_prefix_cache(pid, score_prefix_cache_request())

        assert response.status_code == "timeout"
        assert response.score_tier == "unknown"
        assert response.resident_fingerprint_match == false
      end
    )
  end

  test "terminate flushes trailing partial line from port_log_buffer" do
    pid = start_worker_process!()

    try do
      # Inject a non-empty buffer directly (no port needed — adapter_state stays nil
      # so terminate/2 skips the adapter unload path).
      inject_port_log_buffer(pid, "[INFO] test.flush TRAILING_PARTIAL")

      with_info_logger(fn ->
        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            # Stopping the GenServer triggers terminate/2 → flush_port_log_buffer/1
            GenServer.stop(pid, :normal, 1_000)
          end)

        assert log =~ "TRAILING_PARTIAL"
      end)
    catch
      :exit, _ -> :ok
    end
  end

  test "stream mode keeps worker single-flight even when configured max is higher" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        worker_generation_mode: "stream",
        worker_max_concurrent_requests_per_model: 2
      ],
      fn ->
        pid = start_worker_process!()

        try do
          assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

          assert :ok =
                   WorkerProcess.start_request(pid, "req-1", execute_request("req-1"),
                     subscriber: self()
                   )

          assert {:error, :model_busy} =
                   WorkerProcess.start_request(pid, "req-2", execute_request("req-2"),
                     subscriber: self()
                   )

          assert {:ok, %{active_request_count: 1}} = WorkerProcess.status(pid)
        after
          GenServer.stop(pid, :normal, 1_000)
        end
      end
    )
  end

  test "batch mode allows requests up to the configured limit" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 2,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      ],
      fn ->
        pid = start_worker_process!()

        try do
          assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

          assert :ok =
                   WorkerProcess.start_request(pid, "req-1", execute_request("req-1"),
                     subscriber: self()
                   )

          assert :ok =
                   WorkerProcess.start_request(pid, "req-2", execute_request("req-2"),
                     subscriber: self()
                   )

          assert {:error, :model_busy} =
                   WorkerProcess.start_request(pid, "req-3", execute_request("req-3"),
                     subscriber: self()
                   )

          assert {:ok, %{active_request_count: 2}} = WorkerProcess.status(pid)
        after
          GenServer.stop(pid, :normal, 1_000)
        end
      end
    )
  end

  test "status includes adapter memory budget when loaded" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        worker_generation_mode: "stream"
      ],
      fn ->
        pid = start_worker_process!()

        try do
          assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())
          assert {:ok, status} = WorkerProcess.status(pid)
          assert status.ready == true
          assert status.memory_budget.mode == "observe"
          assert status.memory_budget.budget_available == true
          assert status.memory_budget.status_code == "ok"
          assert status.memory_budget.estimated_headroom_bytes == 5_731_516_544
          assert status.prefix_cache_status.implementation == "kv"
          assert status.prefix_cache_status.enabled == true
          assert status.prefix_cache_status.entry_count == 2
          assert status.prefix_cache_status.total_bytes == 32_768
          assert status.prefix_cache_status.status_code == "ok"
        after
          GenServer.stop(pid, :normal, 1_000)
        end
      end
    )
  end

  test "runtime_adapter_done releases request state and notifies manager" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        worker_generation_mode: "stream"
      ],
      fn ->
        pid = start_worker_process!()

        try do
          assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

          assert :ok =
                   WorkerProcess.start_request(pid, "req-done", execute_request("req-done"),
                     subscriber: self()
                   )

          generation_ref =
            pid
            |> :sys.get_state()
            |> Map.fetch!(:requests)
            |> Map.fetch!("req-done")
            |> Map.fetch!(:generation_ref)

          send(pid, {:runtime_adapter_done, generation_ref})

          assert_receive {:node_runtime_event, "req-done",
                          %Orchard.InferenceEvent{event: %{code: "runtime_stream_ended"}}},
                         1_000

          assert_receive {:worker_request_finished, ^pid, "req-done"}, 1_000

          wait_until(fn ->
            {:ok, %{active_request_count: 0}} = WorkerProcess.status(pid)
          end)
        after
          GenServer.stop(pid, :normal, 1_000)
        end
      end
    )
  end

  test "runtime_adapter_done with generation_task_failed emits deterministic failure" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        worker_generation_mode: "stream"
      ],
      fn ->
        pid = start_worker_process!()

        try do
          assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

          assert :ok =
                   WorkerProcess.start_request(
                     pid,
                     "req-task-failed",
                     execute_request("req-task-failed"),
                     subscriber: self()
                   )

          generation_ref =
            pid
            |> :sys.get_state()
            |> Map.fetch!(:requests)
            |> Map.fetch!("req-task-failed")
            |> Map.fetch!(:generation_ref)

          send(
            pid,
            {:runtime_adapter_done, generation_ref, {:generation_task_failed, :error, :boom}}
          )

          assert_receive {:node_runtime_event, "req-task-failed",
                          %Orchard.InferenceEvent{
                            event: %{code: "runtime_generation_task_failed"}
                          }},
                         1_000

          assert_receive {:worker_request_finished, ^pid, "req-task-failed"}, 1_000

          wait_until(fn ->
            {:ok, %{active_request_count: 0}} = WorkerProcess.status(pid)
          end)
        after
          GenServer.stop(pid, :normal, 1_000)
        end
      end
    )
  end

  test "runtime_adapter_done with worker_unavailable stops the worker process" do
    with_runtime_config(
      [
        runtime_adapter_impl: ConcurrentRuntimeAdapter,
        worker_generation_mode: "stream"
      ],
      fn ->
        previous_trap_exit = Process.flag(:trap_exit, true)
        pid = start_worker_process!()
        monitor_ref = Process.monitor(pid)

        try do
          assert :loaded = WorkerProcess.ensure_loaded(pid, ensure_load_request())

          assert :ok =
                   WorkerProcess.start_request(
                     pid,
                     "req-unavailable",
                     execute_request("req-unavailable"),
                     subscriber: self()
                   )

          generation_ref =
            pid
            |> :sys.get_state()
            |> Map.fetch!(:requests)
            |> Map.fetch!("req-unavailable")
            |> Map.fetch!(:generation_ref)

          send(pid, {:runtime_adapter_done, generation_ref, :worker_unavailable})

          assert_receive {:EXIT, ^pid, :runtime_worker_unavailable}, 1_000
          assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :runtime_worker_unavailable}, 1_000
        after
          Process.flag(:trap_exit, previous_trap_exit)
          Process.demonitor(monitor_ref, [:flush])
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
        end
      end
    )
  end

  test "multiple noeol fragments accumulate before eol flushes" do
    pid = start_worker_process!()
    port = open_test_port!()

    try do
      inject_adapter_state(pid, port)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          send(pid, {port, {:data, {:noeol, "[WARNING] "}}})
          wait_until(fn -> get_port_log_buffer(pid) == "[WARNING] " end)

          send(pid, {port, {:data, {:noeol, "multi.frag CHUNK_A_"}}})
          wait_until(fn -> get_port_log_buffer(pid) == "[WARNING] multi.frag CHUNK_A_" end)

          send(pid, {port, {:data, {:eol, "CHUNK_B"}}})
          wait_until(fn -> get_port_log_buffer(pid) == <<>> end)
        end)

      # All fragments joined into one log line
      assert log =~ "CHUNK_A_CHUNK_B"
      # Parsed as warning level from the [WARNING] prefix
      assert log =~ "[WARNING]"
    after
      clear_adapter_state(pid)
      Port.close(port)
      GenServer.stop(pid, :normal, 1_000)
    end
  end
end
