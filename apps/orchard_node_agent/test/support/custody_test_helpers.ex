defmodule Orchard.Node.CustodyTestHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle

  @poll_interval_ms 10

  @spec assert_os_pid_dead!(pos_integer(), pos_integer()) :: :ok
  def assert_os_pid_dead!(os_pid, timeout_ms) do
    assert wait_until(fn -> not WorkerProcessLifecycle.os_process_alive?(os_pid) end, timeout_ms),
           "expected OS process #{os_pid} to be dead within #{timeout_ms}ms"

    :ok
  end

  @spec assert_reaper_empty!(pos_integer()) :: :ok
  def assert_reaper_empty!(timeout_ms) do
    assert wait_until(
             fn ->
               state = :sys.get_state(RuntimeProcessReaper)
               state.leases == %{} and state.owner_monitors == %{}
             end,
             timeout_ms
           ),
           "expected runtime process reaper leases and owner monitors to be empty"

    :ok
  end

  @spec start_control_child!() :: {port(), pos_integer()}
  def start_control_child! do
    sleep = System.find_executable("sleep") || "/bin/sleep"
    port = Port.open({:spawn_executable, sleep}, args: ["3600"])
    os_pid = port |> Port.info() |> Keyword.fetch!(:os_pid)
    {port, os_pid}
  end

  @spec start_signal_child!(:cooperative | :resistant, Path.t()) :: {port(), pos_integer()}
  def start_signal_child!(mode, marker_path) when mode in [:cooperative, :resistant] do
    shell = System.find_executable("sh") || "/bin/sh"
    fixture = Path.join(__DIR__, "custody-signal-child")

    port =
      Port.open(
        {:spawn_executable, shell},
        [{:args, [fixture, Atom.to_string(mode), marker_path]}, :stderr_to_stdout]
      )

    os_pid = port |> Port.info() |> Keyword.fetch!(:os_pid)

    assert wait_until(fn -> File.exists?(marker_path <> ".ready") end, 1_000),
           "expected custody signal fixture to become ready"

    {port, os_pid}
  end

  @spec stop_child(port(), pos_integer()) :: :ok
  def stop_child(port, os_pid) do
    if WorkerProcessLifecycle.os_process_alive?(os_pid) do
      _ = WorkerProcessLifecycle.kill_process_tree(os_pid)
      _ = wait_until(fn -> not WorkerProcessLifecycle.os_process_alive?(os_pid) end, 1_000)
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end

  @spec wait_until((-> as_boolean(term())), non_neg_integer()) :: boolean()
  def wait_until(fun, timeout_ms) when is_function(fun, 0) and timeout_ms >= 0 do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_interval_ms)
        do_wait_until(fun, deadline)
    end
  end
end
