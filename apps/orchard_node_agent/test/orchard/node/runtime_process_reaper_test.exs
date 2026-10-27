defmodule Orchard.Node.RuntimeProcessReaperTest do
  @moduledoc """
  Unit tests for the runtime process reaper.

  The reaper must kill the OS-level worker child when its owning WorkerProcess
  dies, even if the WorkerProcess was blocked in a long-running load and never
  ran terminate/2.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle

  @short_timeout_ms 200
  @stale_identity "0 Thu Jan 1 00:00:00 1970"
  @sweep_grace_ms 1_000

  setup do
    # The node agent application starts the reaper under its supervisor.
    assert Process.whereis(RuntimeProcessReaper),
           "RuntimeProcessReaper must be running (start the orchard_node_agent app)"

    :ok
  end

  defp start_sleeper_port! do
    sleep = System.find_executable("sleep") || "/bin/sleep"
    port = Port.open({:spawn_executable, sleep}, args: ["3600"])
    os_pid = port |> Port.info() |> Keyword.fetch!(:os_pid)
    {port, os_pid}
  end

  defp wait_until_dead(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    cond do
      not WorkerProcessLifecycle.os_process_alive?(os_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected OS process #{os_pid} to be dead within #{timeout_ms}ms")

      true ->
        Process.sleep(10)
        wait_until_dead(os_pid, max(0, deadline - System.monotonic_time(:millisecond)))
    end
  end

  test "reaper kills the worker child when the owner process dies" do
    {port, os_pid} = start_sleeper_port!()
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    owner_pid =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    assert WorkerProcessLifecycle.os_process_alive?(os_pid)

    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    {:ok, _ref} =
      RuntimeProcessReaper.watch(owner_pid, os_pid, %{
        shutdown_timeout_ms: @short_timeout_ms,
        model_ref: nil,
        os_identity: os_identity,
        phase: :loading
      })

    Process.exit(owner_pid, :kill)

    # The reaper should SIGTERM immediately and SIGKILL after the timeout.
    assert wait_until_dead(os_pid, 2_000) == :ok

    # The lease should have been removed after escalation.
    assert wait_until(
             fn ->
               state = :sys.get_state(RuntimeProcessReaper)
               state.leases == %{} and state.owner_monitors == %{}
             end,
             500
           )

    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "SPEC §12.2 pre-watch non-existence proof records resolved production reaper custody" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert {:error, :process_not_alive} =
             RuntimeProcessReaper.watch(owner, 2_147_483_647, %{
               shutdown_timeout_ms: @short_timeout_ms,
               model_ref: "prewatch-nonexistence",
               os_identity: nil,
               phase: :loading
             })

    assert RuntimeProcessReaper.ownership_resolved?(owner)
    assert :sys.get_state(RuntimeProcessReaper).leases == %{}
  end

  test "SPEC §12.2 an ambiguous custody probe is never recorded as resolved ownership" do
    private_reaper = start_private_reaper!()
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    # PID 1 is launchd/init: owned by root, so `kill -0` reports EPERM rather
    # than "No such process", which is ambiguous rather than proof of exit.
    assert WorkerProcessLifecycle.os_process_status(1) == :unknown

    owner = self()

    for {os_pid, model_ref} <- [{1, "ambiguous"}, {control_pid, "alive"}] do
      assert {:ok, ref} =
               GenServer.call(
                 private_reaper,
                 {:watch, owner, os_pid,
                  %{
                    shutdown_timeout_ms: @short_timeout_ms,
                    model_ref: model_ref,
                    os_identity: @stale_identity,
                    phase: :loaded
                  }}
               )

      RuntimeProcessReaper.release(ref)
    end

    assert wait_until(fn -> :sys.get_state(private_reaper).leases == %{} end, 500)
    assert :sys.get_state(private_reaper).resolved_owners == %{}
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "SPEC §12.2 an unconfirmed exit retains custody evidence until that process exits" do
    private_reaper = start_private_reaper!()
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    owner = self()
    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    assert {:ok, ref} =
             GenServer.call(
               private_reaper,
               {:watch, owner, os_pid,
                %{
                  shutdown_timeout_ms: @short_timeout_ms,
                  model_ref: "unconfirmed-exit",
                  os_identity: os_identity,
                  phase: :loaded
                }}
             )

    RuntimeProcessReaper.release(ref)
    assert wait_until(fn -> :sys.get_state(private_reaper).leases == %{} end, 500)

    assert %{"unconfirmed-exit" => %{os_pid: ^os_pid, owner_pid: ^owner}} =
             :sys.get_state(private_reaper).pending_resolutions

    refute RuntimeProcessReaper.ownership_resolved?(owner)
    assert RuntimeProcessReaper.owner_custody(owner) == {:runtime_process, os_pid, os_identity}

    # SPEC §12.2.2 operator cleanup through host controls happens long after the
    # escalation budget, so the retained record is the only remaining evidence.
    CustodyTestHelpers.stop_child(port, os_pid)

    assert RuntimeProcessReaper.ownership_resolved?(owner)
    assert RuntimeProcessReaper.owner_custody(owner) == :resolved
    assert :sys.get_state(private_reaper).pending_resolutions == %{}
  end

  test "SPEC §12.2 a fresh lease supersedes retained custody evidence for its placement" do
    private_reaper = start_private_reaper!()
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    meta = %{
      shutdown_timeout_ms: @short_timeout_ms,
      model_ref: "superseded",
      os_identity: os_identity,
      phase: :loaded
    }

    assert {:ok, ref} = GenServer.call(private_reaper, {:watch, self(), os_pid, meta})
    RuntimeProcessReaper.release(ref)

    assert wait_until(
             fn ->
               Map.has_key?(:sys.get_state(private_reaper).pending_resolutions, "superseded")
             end,
             500
           )

    assert {:ok, _ref} = GenServer.call(private_reaper, {:watch, self(), os_pid, meta})
    assert :sys.get_state(private_reaper).pending_resolutions == %{}
  end

  test "SPEC.md §4.9 owner shutdown reap logs the current phase at info, not as an orphan" do
    {port, os_pid} = start_sleeper_port!()
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(owner_pid, :kill)
      CustodyTestHelpers.stop_child(port, os_pid)
    end)

    {:ok, ref} = watch_owner(owner_pid, os_pid)
    RuntimeProcessReaper.mark_phase(ref, :loaded)
    assert %{phase: :loaded} = :sys.get_state(RuntimeProcessReaper).leases[ref]

    log = capture_reap_log(fn -> Process.exit(owner_pid, :shutdown) end, os_pid)

    assert log =~ "[info] reaping worker process after its owner stopped"
    assert log =~ "phase: :loaded"
    refute log =~ "orphan"
  end

  test "SPEC.md §4.9 owner crash reap still warns about an orphaned worker" do
    {port, os_pid} = start_sleeper_port!()
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(owner_pid, :kill)
      CustodyTestHelpers.stop_child(port, os_pid)
    end)

    {:ok, _ref} = watch_owner(owner_pid, os_pid)

    log = capture_reap_log(fn -> Process.exit(owner_pid, :kill) end, os_pid)

    assert log =~ "[warning] reaping orphaned worker process"
    assert log =~ "phase: :loading"
  end

  test "watch returns an error when the reaper name is unavailable" do
    reaper_pid = Process.whereis(RuntimeProcessReaper)
    assert is_pid(reaper_pid)
    assert Process.unregister(RuntimeProcessReaper)

    on_exit(fn -> Process.register(reaper_pid, RuntimeProcessReaper) end)

    owner_pid = self()

    assert RuntimeProcessReaper.watch(owner_pid, 1, %{
             shutdown_timeout_ms: @short_timeout_ms,
             model_ref: nil,
             phase: :loading
           }) == {:error, :reaper_unavailable}
  end

  test "stray messages do not stop the reaper" do
    reaper_pid = Process.whereis(RuntimeProcessReaper)
    send(reaper_pid, :unexpected_message)
    Process.sleep(20)
    assert Process.alive?(reaper_pid)
  end

  test "release prevents the reaper from killing a still-alive owner" do
    {_port, os_pid} = start_sleeper_port!()

    owner_pid =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    {:ok, ref} =
      RuntimeProcessReaper.watch(owner_pid, os_pid, %{
        shutdown_timeout_ms: @short_timeout_ms,
        model_ref: nil,
        os_identity: os_identity,
        phase: :loading
      })

    RuntimeProcessReaper.release(ref)

    # Killing the owner after release should not kill the unrelated sleeper.
    Process.exit(owner_pid, :kill)
    Process.sleep(50)

    assert WorkerProcessLifecycle.os_process_alive?(os_pid)

    WorkerProcessLifecycle.kill_process_tree(os_pid)
  end

  test "requested reap records cooperative TERM and clears lease custody" do
    root = unique_root("cooperative")
    marker_path = Path.join(root, "events.log")
    File.mkdir_p!(root)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:cooperative, marker_path)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    {:ok, ref} = watch(os_pid)
    RuntimeProcessReaper.reap(ref, :custody_test)

    assert CustodyTestHelpers.wait_until(
             fn -> event_logged?(marker_path, "term_received mode=cooperative") end,
             1_000
           )

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 a runtime that exits within its TERM grace frees custody before the grace ends" do
    root = unique_root("grace-exit")
    marker_path = Path.join(root, "events.log")
    File.mkdir_p!(root)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:cooperative, marker_path)

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      File.rm_rf!(root)
    end)

    {:ok, ref} =
      watch(os_pid,
        shutdown_timeout_ms: 30_000,
        model_ref: %{model_id: "model/grace", version: "v1"}
      )

    RuntimeProcessReaper.reap(ref, :custody_test)

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    CustodyTestHelpers.assert_reaper_empty!(2_000)
    assert RuntimeProcessReaper.custody_model_keys() == {:ok, MapSet.new()}
  end

  test "requested reap records resistant TERM before bounded KILL escalation" do
    root = unique_root("resistant")
    marker_path = Path.join(root, "events.log")
    File.mkdir_p!(root)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    {:ok, ref} = watch(os_pid)
    RuntimeProcessReaper.reap(ref, :custody_test)

    assert CustodyTestHelpers.wait_until(
             fn -> event_logged?(marker_path, "term_ignored mode=resistant") end,
             1_000
           )

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
    assert RuntimeProcessReaper.ownership_resolved?(self())
  end

  test "release cancels a pending resistant-process escalation and clears monitors" do
    root = unique_root("release")
    marker_path = Path.join(root, "events.log")
    File.mkdir_p!(root)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      File.rm_rf!(root)
    end)

    {:ok, ref} = watch(os_pid)
    RuntimeProcessReaper.reap(ref, :custody_test)

    assert CustodyTestHelpers.wait_until(
             fn ->
               event_logged?(marker_path, "term_ignored mode=resistant") and
                 match?(
                   %{timer_ref: timer_ref} when is_reference(timer_ref),
                   :sys.get_state(RuntimeProcessReaper).leases[ref]
                 )
             end,
             1_000
           )

    RuntimeProcessReaper.release(ref)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
    Process.sleep(@short_timeout_ms + 100)
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
  end

  test "reaper termination sweeps only its exact leased child" do
    private_reaper = start_private_reaper!()
    {leased_port, leased_pid} = CustodyTestHelpers.start_control_child!()
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(leased_port, leased_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert {:ok, _ref} = watch(leased_pid)
    assert WorkerProcessLifecycle.os_process_alive?(leased_pid)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)

    assert :ok = GenServer.stop(private_reaper, :shutdown)
    CustodyTestHelpers.assert_os_pid_dead!(leased_pid, 2_000)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "reaper termination preserves the TERM grace and removes the owned socket" do
    root = unique_root("sweep-grace")
    marker_path = Path.join(root, "events.log")
    socket_path = Path.join(root, "worker.sock")
    File.mkdir_p!(root)
    File.write!(socket_path, "owned runtime artifact")

    private_reaper = start_private_reaper!()
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:cooperative, marker_path)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, _ref} = watch(os_pid, socket_path: socket_path)
    assert :ok = GenServer.stop(private_reaper, :shutdown)

    # A cooperative child only writes this marker from its TERM trap, so the
    # marker proves the sweep delivered TERM instead of an immediate KILL.
    assert CustodyTestHelpers.wait_until(
             fn -> event_logged?(marker_path, "term_received mode=cooperative") end,
             500
           )

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    refute File.exists?(socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "reaper termination escalates a TERM-resistant lease to bounded KILL" do
    root = unique_root("sweep-kill")
    marker_path = Path.join(root, "events.log")
    socket_path = Path.join(root, "worker.sock")
    File.mkdir_p!(root)
    File.write!(socket_path, "owned runtime artifact")

    private_reaper = start_private_reaper!()
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, _ref} = watch(os_pid, socket_path: socket_path)
    assert :ok = GenServer.stop(private_reaper, :shutdown)

    assert event_logged?(marker_path, "term_ignored mode=resistant")
    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    refute File.exists?(socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "reaper termination signals every lease before it waits on any of them" do
    root = unique_root("sweep-broadcast")
    File.mkdir_p!(root)
    private_reaper = start_private_reaper!()
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    children =
      Enum.map(1..3, fn index ->
        marker_path = Path.join(root, "events-#{index}.log")
        {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)
        %{marker_path: marker_path, os_pid: os_pid, port: port}
      end)

    on_exit(fn ->
      Enum.each(children, &CustodyTestHelpers.stop_child(&1.port, &1.os_pid))
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    Enum.each(children, fn child ->
      assert {:ok, _ref} = watch(child.os_pid, shutdown_timeout_ms: @sweep_grace_ms)
    end)

    sweep = Task.async(fn -> GenServer.stop(private_reaper, :shutdown) end)

    # Every lease must record TERM well inside a single lease's grace window; a
    # sweep that waits per lease only reaches the last one after N grace windows.
    assert CustodyTestHelpers.wait_until(
             fn ->
               Enum.all?(children, &event_logged?(&1.marker_path, "term_ignored mode=resistant"))
             end,
             div(@sweep_grace_ms, 2)
           ),
           "expected the sweep to TERM every lease before awaiting any lease's exit"

    assert :ok = Task.await(sweep, 5_000)

    Enum.each(children, &CustodyTestHelpers.assert_os_pid_dead!(&1.os_pid, 2_000))
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "reaper termination refuses to signal a lease whose PID identity changed" do
    private_reaper = start_private_reaper!()
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    assert {:ok, _ref} = watch(control_pid, os_identity: @stale_identity)
    assert :ok = GenServer.stop(private_reaper, :shutdown)

    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "owner-down reaping refuses to signal a lease whose PID identity changed" do
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    {:ok, ref} = watch(control_pid, os_identity: @stale_identity)
    RuntimeProcessReaper.reap(ref, :custody_test)
    CustodyTestHelpers.assert_reaper_empty!(1_000)

    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "owner-down reaping without launch identity keeps the lease without signaling until the PID exits" do
    root = unique_root("owner-down-no-identity")
    socket_path = Path.join(root, "worker.sock")
    File.mkdir_p!(root)
    File.write!(socket_path, "owned runtime artifact")
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    owner_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, _ref} =
             RuntimeProcessReaper.watch(owner_pid, control_pid, %{
               shutdown_timeout_ms: @short_timeout_ms,
               model_ref: nil,
               os_identity: nil,
               phase: :loaded,
               socket_path: socket_path
             })

    Process.exit(owner_pid, :kill)

    # Without a launch identity the reaper cannot prove a live PID is still ours,
    # so it never signals it, and it cannot prove exit either: it keeps custody.
    Process.sleep(300)
    assert map_size(:sys.get_state(RuntimeProcessReaper).leases) == 1
    refute File.exists?(socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)

    CustodyTestHelpers.stop_child(control_port, control_pid)
    CustodyTestHelpers.assert_reaper_empty!(5_000)
  end

  test "an unreadable identity keeps custody and reports the model until exit is confirmed" do
    root = unique_root("unreadable-identity")
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(fake_bin, "ps"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
    {:ok, identity} = WorkerProcessLifecycle.process_identity(control_pid)
    previous_path = System.fetch_env!("PATH")
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, _ref} =
             RuntimeProcessReaper.watch(owner_pid, control_pid, %{
               shutdown_timeout_ms: @short_timeout_ms,
               model_ref: %{model_id: "model/custody", version: "v1"},
               os_identity: identity,
               phase: :loaded,
               socket_path: nil
             })

    # While `ps` fails the reaper cannot prove the PID is still ours: it must not
    # signal it, must not drop the lease, and must report the model as pending.
    System.put_env("PATH", fake_bin <> ":" <> previous_path)
    Process.exit(owner_pid, :kill)
    Process.sleep(600)

    assert map_size(:sys.get_state(RuntimeProcessReaper).leases) == 1

    assert RuntimeProcessReaper.custody_model_keys() ==
             {:ok, MapSet.new([{"model/custody", "v1"}])}

    assert WorkerProcessLifecycle.os_process_alive?(control_pid)

    # Once identity is readable again the reaper kills its own process, confirms
    # the exit, and only then releases the lease.
    System.put_env("PATH", previous_path)
    CustodyTestHelpers.assert_reaper_empty!(10_000)
    refute WorkerProcessLifecycle.os_process_alive?(control_pid)
    assert RuntimeProcessReaper.custody_model_keys() == {:ok, MapSet.new()}
  end

  test "SPEC.md §4.9 a runtime still gets TERM and its grace after a transient identity failure" do
    root = unique_root("identity-recovers")
    marker_path = Path.join(root, "events.log")
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(fake_bin, "ps"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:cooperative, marker_path)
    {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)
    previous_path = System.fetch_env!("PATH")
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      CustodyTestHelpers.stop_child(port, os_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, _ref} =
             RuntimeProcessReaper.watch(owner_pid, os_pid, %{
               shutdown_timeout_ms: 30_000,
               model_ref: nil,
               os_identity: identity,
               phase: :loaded,
               socket_path: nil
             })

    System.put_env("PATH", fake_bin <> ":" <> previous_path)
    Process.exit(owner_pid, :kill)
    Process.sleep(300)
    System.put_env("PATH", previous_path)

    # A KILL would end the child without the cooperative TERM handler running.
    assert CustodyTestHelpers.wait_until(
             fn -> event_logged?(marker_path, "term_received mode=cooperative") end,
             5_000
           )

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 5_000)
    CustodyTestHelpers.assert_reaper_empty!(5_000)
  end

  test "shutdown sweep without launch identity cleans socket without signaling" do
    root = unique_root("shutdown-no-identity")
    socket_path = Path.join(root, "worker.sock")
    File.mkdir_p!(root)
    File.write!(socket_path, "owned runtime artifact")
    private_reaper = start_private_reaper!()
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(control_port, control_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, _ref} = watch(control_pid, os_identity: nil, socket_path: socket_path)
    assert :ok = GenServer.stop(private_reaper, :shutdown)

    refute File.exists?(socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  defp start_private_reaper! do
    original_reaper = Process.whereis(RuntimeProcessReaper)
    assert Process.unregister(RuntimeProcessReaper)

    on_exit(fn ->
      case Process.whereis(RuntimeProcessReaper) do
        nil ->
          Process.register(original_reaper, RuntimeProcessReaper)

        ^original_reaper ->
          :ok

        other ->
          GenServer.stop(other, :shutdown)
          Process.register(original_reaper, RuntimeProcessReaper)
      end
    end)

    assert {:ok, private_reaper} = RuntimeProcessReaper.start_link()
    Process.unlink(private_reaper)
    private_reaper
  end

  defp watch(os_pid, meta \\ []) do
    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    base = %{
      shutdown_timeout_ms: @short_timeout_ms,
      model_ref: nil,
      os_identity: os_identity,
      phase: :loaded
    }

    RuntimeProcessReaper.watch(self(), os_pid, Map.merge(base, Map.new(meta)))
  end

  defp watch_owner(owner_pid, os_pid) do
    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    RuntimeProcessReaper.watch(owner_pid, os_pid, %{
      shutdown_timeout_ms: @short_timeout_ms,
      model_ref: nil,
      os_identity: os_identity,
      phase: :loading
    })
  end

  defp capture_reap_log(stop_owner, os_pid) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fn ->
        stop_owner.()
        assert wait_until_dead(os_pid, 2_000) == :ok
        CustodyTestHelpers.assert_reaper_empty!(1_000)
      end)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp unique_root(label) do
    Path.join(
      "/tmp",
      "oc-reaper-#{label}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp event_logged?(marker_path, event) do
    case File.read(marker_path) do
      {:ok, contents} -> String.contains?(contents, event)
      {:error, _reason} -> false
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, max(0, deadline - System.monotonic_time(:millisecond)))
    end
  end
end
