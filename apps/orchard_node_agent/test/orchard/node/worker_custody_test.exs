defmodule Orchard.Node.WorkerCustodyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcess
  alias Orchard.Node.WorkerProcessLifecycle
  alias Orchard.Node.WorkerRuntimeAdapter
  alias Orchard.Node.WorkerSupervisor

  @shutdown_timeout_ms 200
  @stale_identity "0 Thu Jan 1 00:00:00 1970"

  setup do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    CustodyTestHelpers.assert_reaper_empty!(1_000)

    root =
      Path.join(
        "/tmp",
        "oc-#{System.unique_integer([:positive, :monotonic])}"
      )

    models_root = Path.join(root, "models")
    model_ref = %ModelRef{model_id: "custody/test", version: "v1"}
    File.mkdir_p!(Path.join([models_root, model_ref.model_id, model_ref.version]))

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      log_path: Path.join(root, "worker.log"),
      model_ref: model_ref,
      models_root: models_root,
      root: root,
      socket_path: Path.join(root, "worker.sock")
    }
  end

  test "SPEC.md §4.9 explicit unload reaps the exact stub runtime PID and socket", context do
    state = load_stub_runtime!(context)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(state.port, state.os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert WorkerProcessLifecycle.os_process_alive?(state.os_pid)
    assert File.exists?(state.socket_path)
    assert :ok = WorkerRuntimeAdapter.unload_model(state, [])

    CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
    refute File.exists?(state.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)

    assert CustodyTestHelpers.wait_until(
             fn ->
               case File.read(state.log_path) do
                 {:ok, contents} -> String.contains?(contents, "worker stopping")
                 {:error, _reason} -> false
               end
             end,
             1_000
           )
  end

  test "SPEC.md §4.9 closed BEAM port still reaps its live recorded PID", context do
    state = load_stub_runtime!(context)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(state.port, state.os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    Port.close(state.port)
    assert is_nil(Port.info(state.port))
    assert WorkerProcessLifecycle.os_process_alive?(state.os_pid)

    assert :ok = WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)

    CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
    refute File.exists?(state.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 closed BEAM port refuses to signal a recycled PID", context do
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    File.write!(context.socket_path, "owned runtime artifact")

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_identity: @stale_identity,
      os_pid: control_pid,
      port: exited_port!(),
      reaper_ref: nil,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    }

    log =
      capture_log(fn ->
        assert :ok = WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
      end)

    assert log =~ "worker custody identity mismatch"
    assert log =~ "os_pid=#{control_pid}"
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    refute File.exists?(context.socket_path)
  end

  test "SPEC.md §4.9 noisy TERM-resistant shutdown reaches bounded KILL", context do
    marker_path = Path.join(context.root, "events.log")

    {port, os_pid} =
      CustodyTestHelpers.start_signal_child!(:chatty_resistant, marker_path)

    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert {:ok, reaper_ref} =
             RuntimeProcessReaper.watch(self(), os_pid, %{
               shutdown_timeout_ms: @shutdown_timeout_ms,
               model_ref: context.model_ref,
               phase: :loaded
             })

    File.write!(context.socket_path, "owned runtime artifact")

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_pid: os_pid,
      port: port,
      reaper_ref: reaper_ref,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    }

    task =
      Task.async(fn ->
        receive do
          :unload -> WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
        end
      end)

    assert true = Port.connect(port, task.pid)
    send(task.pid, :unload)

    result = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
    assert {:ok, :ok} = result

    assert CustodyTestHelpers.wait_until(
             fn ->
               case File.read(marker_path) do
                 {:ok, contents} -> String.contains?(contents, "term_ignored mode=resistant")
                 {:error, _reason} -> false
               end
             end,
             1_000
           )

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    refute File.exists?(context.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 Application.stop reaps the exact runtime PID and socket", context do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    stop_node_agent_app()

    runtime =
      Keyword.merge(previous_runtime,
        fake_runtime?: false,
        models_root: context.models_root,
        runtime_adapter_impl: WorkerRuntimeAdapter,
        worker_backend: "stub",
        worker_executable: worker_executable(),
        worker_log_dir: context.root,
        worker_shutdown_timeout_ms: @shutdown_timeout_ms,
        worker_socket_dir: context.root
      )

    Application.put_env(:orchard_node_agent, :runtime, runtime)

    on_exit(fn ->
      stop_node_agent_app()
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    end)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    assert {:ok, worker_pid} = WorkerSupervisor.start_worker(context.model_ref, manager: self())

    assert :loaded =
             WorkerProcess.ensure_loaded(worker_pid, %EnsureModelLoadedRequest{},
               load_timeout_ms: 5_000
             )

    %{adapter_state: state} = :sys.get_state(worker_pid)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(state.port, state.os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert WorkerProcessLifecycle.os_process_alive?(state.os_pid)
    assert File.exists?(state.socket_path)
    assert :ok = Application.stop(:orchard_node_agent)

    CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
    refute File.exists?(state.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  defp load_stub_runtime!(context) do
    assert {:ok, state} =
             WorkerRuntimeAdapter.load_model(context.model_ref,
               backend: "stub",
               executable: worker_executable(),
               load_timeout_ms: 5_000,
               log_path: context.log_path,
               models_root: context.models_root,
               owner: self(),
               ready_timeout_ms: 5_000,
               shutdown_timeout_ms: @shutdown_timeout_ms,
               socket_path: context.socket_path
             )

    state
  end

  defp exited_port! do
    true_executable = System.find_executable("true") || "/usr/bin/true"
    port = Port.open({:spawn_executable, true_executable}, [:exit_status])

    assert_receive {^port, {:exit_status, _status}}, 2_000

    assert CustodyTestHelpers.wait_until(fn -> is_nil(Port.info(port)) end, 1_000),
           "expected the fixture port to close after its program exited"

    port
  end

  defp worker_executable do
    Path.expand("../../../../../native/orchard_worker_mlx/bin/orchard-worker-mlx", __DIR__)
  end

  defp stop_node_agent_app do
    case Application.stop(:orchard_node_agent) do
      :ok -> :ok
      {:error, {:not_started, :orchard_node_agent}} -> :ok
    end
  end
end
