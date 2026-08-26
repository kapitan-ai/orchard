defmodule Orchard.Node.WorkerProcessLifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.WorkerProcessLifecycle

  @missing_pid 2_147_483_647
  @stale_identity "0 Thu Jan 1 00:00:00 1970"

  test "TERM delivery succeeds for a live resistant child" do
    root = Path.join("/tmp", "oc-signal-#{System.unique_integer([:positive, :monotonic])}")
    marker_path = Path.join(root, "events.log")
    File.mkdir_p!(root)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      File.rm_rf!(root)
    end)

    assert :ok = WorkerProcessLifecycle.send_signal(os_pid, "-TERM")

    assert CustodyTestHelpers.wait_until(
             fn ->
               case File.read(marker_path) do
                 {:ok, contents} -> String.contains?(contents, "term_ignored mode=resistant")
                 {:error, _reason} -> false
               end
             end,
             1_000
           )

    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
  end

  test "signal command failures are observable with secret-safe stable fields" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()
    secret_signal = "-NOT-A-SIGNAL-/tmp/private/token-secret"

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    log =
      capture_log(fn ->
        assert {:error, :signal_failed} =
                 WorkerProcessLifecycle.send_signal(os_pid, secret_signal)
      end)

    assert log =~ "worker signal failed"
    assert log =~ "os_pid=#{os_pid}"
    assert log =~ "signal=unknown"
    assert log =~ "exit_status="
    refute log =~ secret_signal
    refute log =~ "/tmp/private"
    refute log =~ "token-secret"
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
  end

  test "custody-gated signals refuse a PID whose identity snapshot no longer matches" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    assert {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)
    assert {:ok, ^identity} = WorkerProcessLifecycle.process_identity(os_pid)

    log =
      capture_log(fn ->
        assert {:error, :identity_mismatch} =
                 WorkerProcessLifecycle.signal_owned_process(os_pid, @stale_identity, "-TERM")

        assert {:error, :identity_mismatch} =
                 WorkerProcessLifecycle.kill_owned_process_tree(os_pid, @stale_identity)
      end)

    assert log =~ "worker custody identity mismatch"
    assert log =~ "os_pid=#{os_pid}"
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)

    assert :ok = WorkerProcessLifecycle.signal_owned_process(os_pid, identity, "-TERM")
    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
  end

  test "custody-gated signals fail closed without a launch identity" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    log =
      capture_log(fn ->
        assert {:error, :identity_unavailable} =
                 WorkerProcessLifecycle.signal_owned_process(os_pid, nil, "-TERM")

        assert {:error, :identity_unavailable} =
                 WorkerProcessLifecycle.kill_owned_process_tree(os_pid, nil)
      end)

    assert log =~ "worker custody identity unavailable"
    assert log =~ "os_pid=#{os_pid}"
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
    assert {:error, :identity_unavailable} = WorkerProcessLifecycle.process_identity(@missing_pid)
  end

  test "custody refusal separates an already-exited target from a recycled PID" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    assert {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)
    CustodyTestHelpers.stop_child(port, os_pid)
    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)

    log =
      capture_log(fn ->
        assert {:error, :identity_unavailable} =
                 WorkerProcessLifecycle.signal_owned_process(os_pid, identity, "-TERM")

        assert {:error, :identity_unavailable} =
                 WorkerProcessLifecycle.kill_owned_process_tree(os_pid, identity)
      end)

    refute log =~ "worker custody identity mismatch"

    assert WorkerProcessLifecycle.custody_refused?({:error, :identity_unavailable})
    assert WorkerProcessLifecycle.custody_refused?({:error, :identity_mismatch})
    refute WorkerProcessLifecycle.custody_refused?({:error, :signal_failed})
    refute WorkerProcessLifecycle.custody_refused?(:ok)
  end

  test "escalate_owned_exit spends no grace past an already-elapsed TERM deadline" do
    root = Path.join("/tmp", "oc-escalate-#{System.unique_integer([:positive, :monotonic])}")
    marker_path = Path.join(root, "events.log")
    File.mkdir_p!(root)
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      File.rm_rf!(root)
    end)

    assert {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)

    started = System.monotonic_time(:millisecond)

    assert :ok =
             WorkerProcessLifecycle.escalate_owned_exit(
               os_pid,
               identity,
               started,
               started + 2_000
             )

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 500,
           "expected an elapsed TERM deadline to escalate immediately, spent #{elapsed}ms"

    refute WorkerProcessLifecycle.os_process_alive?(os_pid)
  end

  test "escalate_owned_exit refuses to kill a PID whose identity snapshot changed" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    now = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:error, :identity_mismatch} =
                 WorkerProcessLifecycle.escalate_owned_exit(
                   os_pid,
                   @stale_identity,
                   now,
                   now + 500
                 )
      end)

    assert log =~ "worker custody identity mismatch"
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
  end

  test "remove_owned_socket drops an owned path and tolerates a missing one" do
    root = Path.join("/tmp", "oc-socket-#{System.unique_integer([:positive, :monotonic])}")
    socket_path = Path.join(root, "worker.sock")
    File.mkdir_p!(root)
    File.write!(socket_path, "owned runtime artifact")

    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = WorkerProcessLifecycle.remove_owned_socket(socket_path)
    refute File.exists?(socket_path)
    assert :ok = WorkerProcessLifecycle.remove_owned_socket(socket_path)
    assert :ok = WorkerProcessLifecycle.remove_owned_socket(nil)
  end

  test "await_exit reports a bounded timeout while the child is still alive" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    assert {:error, :timeout} = WorkerProcessLifecycle.await_exit(os_pid, 50)
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)

    assert :ok = WorkerProcessLifecycle.send_signal(os_pid, "-TERM")
    assert :ok = WorkerProcessLifecycle.await_exit(os_pid, 2_000)
  end

  test "signaling a missing PID returns the stable failure reason" do
    log =
      capture_log(fn ->
        assert {:error, :signal_failed} =
                 WorkerProcessLifecycle.send_signal(@missing_pid, "-TERM")
      end)

    assert log =~ "worker signal failed"
    assert log =~ "os_pid=#{@missing_pid}"
    assert log =~ "signal=TERM"
    refute log =~ "No such process"
  end
end
