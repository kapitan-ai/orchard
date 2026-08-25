defmodule Orchard.Node.WorkerProcessLifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.WorkerProcessLifecycle

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

  test "signaling a missing PID returns the stable failure reason" do
    missing_pid = 2_147_483_647

    log =
      capture_log(fn ->
        assert {:error, :signal_failed} =
                 WorkerProcessLifecycle.send_signal(missing_pid, "-TERM")
      end)

    assert log =~ "worker signal failed"
    assert log =~ "os_pid=#{missing_pid}"
    assert log =~ "signal=TERM"
    refute log =~ "No such process"
  end
end
