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
  shutdown sweep delivers TERM to every lease before it waits on any of them, so
  a single shared `@sweep_budget_ms` grace window runs concurrently across leases
  instead of being consumed by whichever lease the map happened to yield first.
  The budget always fits the supervisor shutdown budget, and every signal is
  gated on the identity snapshot so a recycled PID belonging to an unrelated
  process is never targeted.

  A kill the reaper cannot confirm within its escalation budget leaves a pending
  resolution record instead of discarding the lease evidence. Callers re-probe it
  through `ownership_resolved?/1` and `owner_custody/1`, so a runtime process that
  exits after the budget — or one an operator kills through host controls per
  SPEC §12.2.2 — still resolves custody for its placement.
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

  @type pending_resolution :: %{
          model_ref: term(),
          os_identity: WorkerProcessLifecycle.custody_identity(),
          os_pid: pos_integer(),
          owner_pid: pid()
        }

  @type owner_custody :: :resolved | :unknown | {:runtime_process, pos_integer()}

  # Kept below the 5_000ms child_spec shutdown budget so the sweep can never be
  # cut short by a brutal kill from the supervisor.
  @sweep_budget_ms 4_000

  # Cleanup records custody resolution only from a settled process, so the
  # escalation spends a bounded wait confirming the kill it just requested.
  @escalation_exit_budget_ms 1_000

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
    if Process.whereis(__MODULE__),
      do: watch_after_reaper_check(owner_pid, os_pid, meta),
      else: {:error, :reaper_unavailable}
  end

  def watch(_, _, _), do: {:error, :invalid_lease}

  @doc "Records a BEAM-only stub owner, which cannot create an OS subprocess."
  @spec watch_beam_only(pid(), term()) :: :ok
  def watch_beam_only(owner, key), do: GenServer.call(__MODULE__, {:watch_beam_only, owner, key})

  @spec release(lease_ref()) :: :ok
  def release(ref) do
    GenServer.cast(__MODULE__, {:release, ref})
  end

  @spec reap(lease_ref(), term()) :: :ok
  def reap(ref, reason) do
    GenServer.cast(__MODULE__, {:reap, ref, reason})
  end

  @doc """
  Reports affirmative cleanup of this runtime owner in the current reaper lifetime.

  Each call re-probes that owner's pending resolution records, so an exit the
  escalation budget could not confirm still resolves once it happens.
  """
  @spec ownership_resolved?(pid()) :: boolean()
  def ownership_resolved?(owner_pid) do
    GenServer.call(__MODULE__, {:ownership_resolved, owner_pid})
  catch
    :exit, _reason -> false
  end

  @doc """
  Reports the custody evidence this reaper holds for `owner_pid`.

  `:resolved` is affirmative exit proof, `{:runtime_process, os_pid}` names the
  runtime process whose exit is not proven yet, and `:unknown` means this reaper
  never held OS custody for that owner.
  """
  @spec owner_custody(pid()) :: owner_custody()
  def owner_custody(owner_pid) do
    GenServer.call(__MODULE__, {:owner_custody, owner_pid})
  catch
    :exit, _reason -> :unknown
  end

  @impl true
  def init(_opts) do
    # The reaper itself must be resilient to supervisor exit signals; it is never
    # blocked on long-running work and only performs short OS calls.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       leases: %{},
       owner_monitors: %{},
       pending_resolutions: %{},
       resolved_owners: %{},
       beam_owners: %{}
     }}
  end

  @impl true
  def handle_call({:ownership_resolved, owner_pid}, _from, state) do
    state = reprobe_pending_resolutions(state, owner_pid)
    {:reply, owner_resolved?(state, owner_pid), state}
  end

  def handle_call({:owner_custody, owner_pid}, _from, state) do
    state = reprobe_pending_resolutions(state, owner_pid)
    {:reply, custody_evidence(state, owner_pid), state}
  end

  def handle_call({:record_prewatch_nonexistence, owner_pid, model_ref}, _from, state) do
    {:reply, :ok, resolve_custody(state, model_ref, owner_pid)}
  end

  def handle_call({:watch_beam_only, owner, key}, {owner, _tag}, state) do
    monitor = Process.monitor(owner)

    state = %{
      supersede_custody(state, key)
      | beam_owners: Map.put(state.beam_owners, monitor, {owner, key})
    }

    {:reply, :ok, state}
  end

  def handle_call({:watch, owner_pid, os_pid, meta}, _from, state) do
    ref = make_ref()
    monitor_ref = Process.monitor(owner_pid)

    lease = %{
      owner_pid: owner_pid,
      owner_monitor_ref: monitor_ref,
      model_ref: Map.get(meta, :model_ref),
      phase: Map.get(meta, :phase, :loading),
      os_pid: os_pid,
      os_identity: lease_identity(meta),
      shutdown_timeout_ms: Map.get(meta, :shutdown_timeout_ms, 1_000),
      socket_path: Map.get(meta, :socket_path),
      term_deadline: nil,
      timer_ref: nil
    }

    state =
      state
      |> supersede_custody(lease.model_ref)
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
  def handle_info({:DOWN, ref, :process, owner, _reason}, %{beam_owners: owners} = state)
      when is_map_key(owners, ref) do
    {{^owner, key}, owners} = Map.pop(owners, ref)

    {:noreply, resolve_custody(%{state | beam_owners: owners}, key, owner)}
  end

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
        now = System.monotonic_time(:millisecond)

        _ =
          WorkerProcessLifecycle.escalate_owned_exit(
            os_pid,
            os_identity,
            now,
            now + @escalation_exit_budget_ms
          )

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

    state.leases
    |> Enum.map(fn {_ref, lease} -> signal_swept_lease(lease, sweep_deadline) end)
    |> Enum.each(&await_swept_lease(&1, sweep_deadline))

    :ok
  end

  defp signal_swept_lease(lease, sweep_deadline) do
    _ = WorkerProcessLifecycle.remove_owned_socket(lease.socket_path)

    with true <- WorkerProcessLifecycle.os_process_alive?(lease.os_pid),
         deadline when is_integer(deadline) <- resolve_term_deadline(lease) do
      {lease, min(deadline, sweep_deadline)}
    else
      _unsignalled -> :swept
    end
  end

  defp await_swept_lease(:swept, _sweep_deadline), do: :ok

  defp await_swept_lease({lease, grace_deadline}, sweep_deadline) do
    _ =
      WorkerProcessLifecycle.escalate_owned_exit(
        lease.os_pid,
        lease.os_identity,
        grace_deadline,
        sweep_deadline
      )

    :ok
  end

  defp resolve_term_deadline(%{term_deadline: deadline}) when is_integer(deadline), do: deadline

  defp resolve_term_deadline(lease) do
    signal_result =
      WorkerProcessLifecycle.signal_owned_process(lease.os_pid, lease.os_identity, "-TERM")

    cond do
      WorkerProcessLifecycle.custody_refused?(signal_result) ->
        :custody_refused

      signal_result == :ok ->
        System.monotonic_time(:millisecond) + lease.shutdown_timeout_ms

      true ->
        System.monotonic_time(:millisecond)
    end
  end

  defp start_reaping(state, ref, reason) do
    case get_in(state.leases[ref]) do
      nil ->
        state

      %{os_pid: os_pid, shutdown_timeout_ms: timeout, timer_ref: nil} = lease ->
        log_orphan_reap(lease, reason)
        _ = WorkerProcessLifecycle.remove_owned_socket(lease.socket_path)

        if WorkerProcessLifecycle.os_process_alive?(os_pid) do
          start_live_process_reaping(state, ref, lease, timeout)
        else
          cleanup_lease(state, ref)
        end

      _other ->
        state
    end
  end

  defp start_live_process_reaping(state, ref, lease, timeout) do
    signal_result =
      WorkerProcessLifecycle.signal_owned_process(lease.os_pid, lease.os_identity, "-TERM")

    if WorkerProcessLifecycle.custody_refused?(signal_result) do
      cleanup_lease(state, ref)
    else
      timer_ref = Process.send_after(self(), {:escalate, ref}, timeout)

      state
      |> put_in([Access.key(:leases), ref, :timer_ref], timer_ref)
      |> put_in(
        [Access.key(:leases), ref, :term_deadline],
        System.monotonic_time(:millisecond) + timeout
      )
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
        |> record_lease_custody(lease)
    end
  end

  defp record_lease_custody(state, lease) do
    cond do
      proven_exit?(lease) -> resolve_custody(state, lease.model_ref, lease.owner_pid)
      is_binary(lease.os_identity) -> retain_pending_resolution(state, lease)
      true -> supersede_custody(state, lease.model_ref)
    end
  end

  defp retain_pending_resolution(state, lease) do
    pending = %{
      model_ref: lease.model_ref,
      os_identity: lease.os_identity,
      os_pid: lease.os_pid,
      owner_pid: lease.owner_pid
    }

    %{
      state
      | pending_resolutions: Map.put(state.pending_resolutions, lease.model_ref, pending),
        resolved_owners: Map.delete(state.resolved_owners, lease.model_ref)
    }
  end

  defp reprobe_pending_resolutions(state, owner_pid) do
    state.pending_resolutions
    |> Enum.filter(fn {_model_ref, pending} -> pending.owner_pid == owner_pid end)
    |> Enum.reduce(state, fn {model_ref, pending}, acc ->
      if proven_exit?(pending),
        do: resolve_custody(acc, model_ref, pending.owner_pid),
        else: acc
    end)
  end

  defp proven_exit?(%{os_identity: os_identity, os_pid: os_pid}) do
    is_binary(os_identity) and WorkerProcessLifecycle.os_process_status(os_pid) == :not_alive
  end

  defp resolve_custody(state, model_ref, owner_pid) do
    %{
      state
      | pending_resolutions: Map.delete(state.pending_resolutions, model_ref),
        resolved_owners: Map.put(state.resolved_owners, model_ref, owner_pid)
    }
  end

  defp supersede_custody(state, model_ref) do
    %{
      state
      | pending_resolutions: Map.delete(state.pending_resolutions, model_ref),
        resolved_owners: Map.delete(state.resolved_owners, model_ref)
    }
  end

  defp owner_resolved?(state, owner_pid) do
    Enum.any?(state.resolved_owners, fn {_key, owner} -> owner == owner_pid end) and
      not Enum.any?(state.leases, fn {_ref, lease} -> lease.owner_pid == owner_pid end) and
      not Enum.any?(state.beam_owners, fn {_ref, {owner, _key}} -> owner == owner_pid end)
  end

  defp custody_evidence(state, owner_pid) do
    case owned_runtime_process(state, owner_pid) do
      nil -> if owner_resolved?(state, owner_pid), do: :resolved, else: :unknown
      os_pid -> {:runtime_process, os_pid}
    end
  end

  defp owned_runtime_process(state, owner_pid) do
    state.leases
    |> Stream.map(fn {_ref, lease} -> lease end)
    |> Stream.concat(Map.values(state.pending_resolutions))
    |> Enum.find_value(fn record ->
      if record.owner_pid == owner_pid and is_binary(record.os_identity), do: record.os_pid
    end)
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

  defp watch_after_reaper_check(owner_pid, os_pid, meta) do
    case prewatch_custody_proof(os_pid) do
      :ok ->
        call_reaper({:watch, owner_pid, os_pid, meta})

      {:error, :process_not_alive} ->
        record_prewatch_nonexistence(owner_pid, meta)

      {:error, :process_status_unavailable} = error ->
        error
    end
  end

  defp record_prewatch_nonexistence(owner_pid, meta) do
    case call_reaper({:record_prewatch_nonexistence, owner_pid, Map.get(meta, :model_ref)}) do
      :ok -> {:error, :process_not_alive}
      {:error, :reaper_unavailable} = error -> error
    end
  end

  defp call_reaper(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _reason -> {:error, :reaper_unavailable}
  end

  defp prewatch_custody_proof(os_pid) do
    case WorkerProcessLifecycle.os_process_status(os_pid) do
      :alive -> :ok
      :not_alive -> {:error, :process_not_alive}
      :unknown -> {:error, :process_status_unavailable}
    end
  end

  defp lease_identity(meta) do
    case Map.get(meta, :os_identity) do
      identity when is_binary(identity) -> identity
      _other -> nil
    end
  end
end
