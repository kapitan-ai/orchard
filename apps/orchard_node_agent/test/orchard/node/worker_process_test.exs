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

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
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
