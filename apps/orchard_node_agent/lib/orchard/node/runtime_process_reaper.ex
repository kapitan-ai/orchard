defmodule Orchard.Node.RuntimeProcessReaper do
  @moduledoc """
  Guarantees that an OS-level worker subprocess is reaped when its owning
  WorkerProcess dies.

  The reaper owns `{owner_pid -> os_pid}` leases. A lease is registered as soon
  as the port opens and before readiness polling starts, so a worker killed
  during a long model load is still cleaned up.

  Because the reaper is a separate, mailbox-light GenServer placed before
  `WorkerSupervisor` in the `:rest_for_one` tree, it survives worker death and
  performs escalation even when the owning WorkerProcess is killed abruptly by
  its supervisor. Its own `terminate/2` sweeps any remaining leases on node
  shutdown.

  A lease also carries the worker's socket path and an OS identity snapshot.
  `WorkerProcess` does not trap exits, so on orderly `Application.stop/1` it dies
  without running its adapter unload; the reaper is therefore the only component
  that can remove the owned socket without depending on worker cooperation. The
  shutdown sweep preserves each lease's remaining TERM grace before escalating,
  bounded by `@sweep_budget_ms` so it always fits the supervisor shutdown budget,
  and every signal is gated on the identity snapshot so a recycled PID belonging
  to an unrelated process is never targeted.
  """

  use GenServer

  alias Orchard.Node.WorkerProcessLifecycle
  require Logger

  @type lease_ref :: reference()

  @type lease_meta :: %{
          optional(:os_identity) => WorkerProcessLifecycle.custody_identity() | nil,
          optional(:socket_path) => String.t() | nil,
          shutdown_timeout_ms: pos_integer(),
          model_ref: term(),
          phase: :loading | :loaded | :unloading
        }

  @type lease :: %{
          owner_pid: pid(),
          owner_monitor_ref: reference(),
          os_pid: pos_integer(),
          os_identity: WorkerProcessLifecycle.custody_identity() | nil,
          model_ref: term(),
          phase: :loading | :loaded | :unloading,
          shutdown_timeout_ms: pos_integer(),
          socket_path: String.t() | nil,
          term_deadline: integer() | nil,
          timer_ref: reference() | nil
        }

  # Kept below the 5_000ms child_spec shutdown budget so the sweep can never be
  # cut short by a brutal kill from the supervisor.
  @sweep_budget_ms 4_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 5_000
    }
  end

  @spec watch(pid(), pos_integer(), lease_meta()) :: {:ok, lease_ref()} | {:error, atom()}
  def watch(owner_pid, os_pid, meta)
      when is_pid(owner_pid) and is_integer(os_pid) and os_pid > 0 do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:watch, owner_pid, os_pid, meta})
      catch
        :exit, _reason -> {:error, :reaper_unavailable}
      end
    else
      {:error, :reaper_unavailable}
    end
  end

  def watch(_, _, _), do: {:error, :invalid_lease}

  @spec release(lease_ref()) :: :ok
  def release(ref) do
    GenServer.cast(__MODULE__, {:release, ref})
  end

  @spec reap(lease_ref(), term()) :: :ok
  def reap(ref, reason) do
    GenServer.cast(__MODULE__, {:reap, ref, reason})
  end

  @impl true
  def init(_opts) do
    # The reaper itself must be resilient to supervisor exit signals; it is never
    # blocked on long-running work and only performs short OS calls.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       leases: %{},
       owner_monitors: %{}
     }}
  end

  @impl true
  def handle_call({:watch, owner_pid, os_pid, meta}, _from, state) do
    ref = make_ref()
    monitor_ref = Process.monitor(owner_pid)

    lease = %{
      owner_pid: owner_pid,
      owner_monitor_ref: monitor_ref,
      model_ref: Map.get(meta, :model_ref),
      phase: Map.get(meta, :phase, :loading),
      os_pid: os_pid,
      os_identity: lease_identity(meta, os_pid),
      shutdown_timeout_ms: Map.get(meta, :shutdown_timeout_ms, 1_000),
      socket_path: Map.get(meta, :socket_path),
      term_deadline: nil,
      timer_ref: nil
    }

    state =
      state
      |> put_in([Access.key(:leases), ref], lease)
      |> put_in([Access.key(:owner_monitors), monitor_ref], ref)

    {:reply, {:ok, ref}, state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    {:noreply, cleanup_lease(state, ref)}
  end

  def handle_cast({:reap, ref, reason}, state) do
    {:noreply, start_reaping(state, ref, {:requested, reason})}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    {ref, owner_monitors} = Map.pop(state.owner_monitors, monitor_ref)

    state =
      if is_nil(ref) do
        state
      else
        state = %{state | owner_monitors: owner_monitors}
        start_reaping(state, ref, {:owner_down, reason})
      end

    {:noreply, state}
  end

  def handle_info({:escalate, ref}, state) do
    case state.leases[ref] do
      nil ->
        {:noreply, state}

      %{os_pid: os_pid, os_identity: os_identity} = _lease ->
        if WorkerProcessLifecycle.os_process_alive?(os_pid) do
          _ = WorkerProcessLifecycle.kill_owned_process_tree(os_pid, os_identity)
        end

        {:noreply, cleanup_lease(state, ref)}
    end
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    sweep_deadline = System.monotonic_time(:millisecond) + @sweep_budget_ms

    Enum.each(state.leases, fn {_ref, lease} -> sweep_lease(lease, sweep_deadline) end)

    :ok
  end

  defp sweep_lease(lease, sweep_deadline) do
    _ = cleanup_socket(lease.socket_path)

    if WorkerProcessLifecycle.os_process_alive?(lease.os_pid) do
      grace_deadline = min(resolve_term_deadline(lease), sweep_deadline)
      grace_ms = max(0, grace_deadline - System.monotonic_time(:millisecond))

      case WorkerProcessLifecycle.await_exit(lease.os_pid, grace_ms) do
        :ok ->
          :ok

        {:error, :timeout} ->
          _ = WorkerProcessLifecycle.kill_owned_process_tree(lease.os_pid, lease.os_identity)
          :ok
      end
    else
      :ok
    end
  end

  defp resolve_term_deadline(%{term_deadline: nil} = lease) do
    _ = WorkerProcessLifecycle.signal_owned_process(lease.os_pid, lease.os_identity, "-TERM")
    System.monotonic_time(:millisecond) + lease.shutdown_timeout_ms
  end

  defp resolve_term_deadline(%{term_deadline: deadline}), do: deadline

  defp start_reaping(state, ref, reason) do
    case get_in(state.leases[ref]) do
      nil ->
        state

      %{os_pid: os_pid, shutdown_timeout_ms: timeout, timer_ref: nil} = lease ->
        log_orphan_reap(lease, reason)
        _ = cleanup_socket(lease.socket_path)

        if WorkerProcessLifecycle.os_process_alive?(os_pid) do
          _ = WorkerProcessLifecycle.signal_owned_process(os_pid, lease.os_identity, "-TERM")
          timer_ref = Process.send_after(self(), {:escalate, ref}, timeout)

          state
          |> put_in([Access.key(:leases), ref, :timer_ref], timer_ref)
          |> put_in(
            [Access.key(:leases), ref, :term_deadline],
            System.monotonic_time(:millisecond) + timeout
          )
        else
          cleanup_lease(state, ref)
        end

      _other ->
        state
    end
  end

  defp cleanup_lease(state, ref) do
    case Map.pop(state.leases, ref) do
      {nil, _} ->
        state

      {lease, leases} ->
        Process.demonitor(lease.owner_monitor_ref, [:flush])

        owner_monitors = Map.delete(state.owner_monitors, lease.owner_monitor_ref)

        if is_reference(lease.timer_ref) do
          Process.cancel_timer(lease.timer_ref, info: false)
        end

        %{state | leases: leases, owner_monitors: owner_monitors}
    end
  end

  defp log_orphan_reap(lease, {:owner_down, reason}) do
    Logger.warning(
      "reaping orphaned worker process " <>
        inspect(%{
          model_ref: lease.model_ref,
          os_pid: lease.os_pid,
          owner_reason: reason,
          phase: lease.phase
        })
    )
  end

  defp log_orphan_reap(_lease, _reason), do: :ok

  defp lease_identity(meta, os_pid) do
    case Map.get(meta, :os_identity) do
      identity when is_binary(identity) ->
        identity

      _other ->
        case WorkerProcessLifecycle.process_identity(os_pid) do
          {:ok, identity} -> identity
          {:error, :identity_unavailable} -> nil
        end
    end
  end

  defp cleanup_socket(nil), do: :ok

  defp cleanup_socket(socket_path) when is_binary(socket_path) do
    _ = File.rm(socket_path)
    :ok
  end
end
