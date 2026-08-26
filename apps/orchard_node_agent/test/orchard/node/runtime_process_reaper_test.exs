defmodule Orchard.Node.RuntimeProcessReaperTest do
  @moduledoc """
  Unit tests for the runtime process reaper.

  The reaper must kill the OS-level worker child when its owning WorkerProcess
  dies, even if the WorkerProcess was blocked in a long-running load and never
  ran terminate/2.
  """

  use ExUnit.Case, async: false

  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle

  @short_timeout_ms 200
  @stale_identity "0 Thu Jan 1 00:00:00 1970"

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

    {:ok, _ref} =
      RuntimeProcessReaper.watch(owner_pid, os_pid, %{
        shutdown_timeout_ms: @short_timeout_ms,
        model_ref: nil,
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

    {:ok, ref} =
      RuntimeProcessReaper.watch(owner_pid, os_pid, %{
        shutdown_timeout_ms: @short_timeout_ms,
        model_ref: nil,
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
    base = %{
      shutdown_timeout_ms: @short_timeout_ms,
      model_ref: nil,
      phase: :loaded
    }

    RuntimeProcessReaper.watch(self(), os_pid, Map.merge(base, Map.new(meta)))
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
