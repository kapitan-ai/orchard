defmodule Orchard.Node.RuntimeProcessReaperTest do
  @moduledoc """
  Unit tests for the runtime process reaper.

  The reaper must kill the OS-level worker child when its owning WorkerProcess
  dies, even if the WorkerProcess was blocked in a long-running load and never
  ran terminate/2.
  """

  use ExUnit.Case, async: false

  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle

  @short_timeout_ms 200

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
    {_port, os_pid} = start_sleeper_port!()

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
