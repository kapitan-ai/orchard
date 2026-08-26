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

  test "custody-gated signals fall back to unguarded delivery without a snapshot" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    assert :ok = WorkerProcessLifecycle.signal_owned_process(os_pid, nil, "-TERM")
    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    assert {:error, :identity_unavailable} = WorkerProcessLifecycle.process_identity(@missing_pid)
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
