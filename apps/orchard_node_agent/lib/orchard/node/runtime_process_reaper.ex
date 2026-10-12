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

  The reaper ends a lease only when it confirms the process exit: the PID is
  gone, or it now belongs to a different process. A KILL that is not yet confirmed, or an
  identity that cannot be read, keeps the lease and rechecks on a timer with
  backoff. `custody_model_keys/0` reports the model of every lease, so the Node
  does not start a replacement or treat a slot as free while a runtime it
  launched may still run.

  When a lease ends, the reaper keeps Worker recovery evidence for its owner. Proof
  that the recorded runtime no longer exists records resolved ownership. A lease
  that ends without that proof leaves a pending resolution record: for example, a
  caller released it while the PID still runs, or the PID now belongs to another
  process. `ownership_resolved?/1` and `owner_custody/1` re-probe that record, so a
  runtime that exits later, or one an operator kills through host controls per
  SPEC §12.2.2, still resolves ownership for its placement.

  Slot custody and recovery ownership answer different questions. A PID that now
  belongs to another process ends the lease and frees the slot. SPEC §12.2
  automatic recovery still waits for proof that the recorded runtime is gone.
  """

  use GenServer

  alias Orchard.Node.WorkerProcessLifecycle
  require Logger

  @type lease_ref :: reference()
  @type phase :: :loading | :loaded | :unloading

  @type lease_meta :: %{
          optional(:os_identity) => WorkerProcessLifecycle.custody_identity() | nil,
          optional(:socket_path) => String.t() | nil,
          shutdown_timeout_ms: pos_integer(),
          model_ref: term(),
          phase: phase()
        }

  @type lease :: %{
          owner_pid: pid(),
          owner_monitor_ref: reference(),
          os_pid: pos_integer(),
          os_identity: WorkerProcessLifecycle.custody_identity() | nil,
          model_ref: term(),
          phase: phase(),
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

  # Recheck an unconfirmed exit with exponential backoff up to this cap.
  @confirm_base_ms 200
  @confirm_max_ms 5_000
  @grace_poll_ms 50

  # A custody query that cannot answer in time is treated as unavailable.
  @query_timeout_ms 2_000

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

  @doc """
  The `{model_id, version}` of every runtime the reaper holds custody of.

  A key stays here until that runtime's exit is confirmed. A reaper that does not
  answer returns `{:error, :unavailable}`, which is never evidence that no
  runtime remains.
  """
  @spec custody_model_keys(timeout()) ::
          {:ok, MapSet.t({String.t(), String.t()})} | {:error, :unavailable}
  def custody_model_keys(timeout_ms \\ @query_timeout_ms) do
    {:ok, GenServer.call(__MODULE__, :custody_model_keys, timeout_ms)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Ends custody after the caller confirmed the process exited.

  Synchronous, so a later `custody_model_keys/0` never sees the released lease.
  """
  @spec release(lease_ref()) :: :ok
  def release(ref) do
    GenServer.call(__MODULE__, {:release, ref}, @query_timeout_ms)
  catch
    :exit, _reason -> :ok
  end

  @spec mark_phase(lease_ref(), phase()) :: :ok
  def mark_phase(ref, phase) when phase in [:loading, :loaded, :unloading] do
    GenServer.cast(__MODULE__, {:mark_phase, ref, phase})
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

  def handle_call(:custody_model_keys, _from, state) do
    keys =
      for {_ref, %{model_ref: model_ref}} <- state.leases,
          key = model_key(model_ref),
          key != nil,
          into: MapSet.new(),
          do: key

    {:reply, keys, state}
  end

  def handle_call({:release, ref}, _from, state) do
    {:reply, :ok, cleanup_lease(state, ref)}
  end

  @impl true
  def handle_cast({:reap, ref, reason}, state) do
    {:noreply, start_reaping(state, ref, {:requested, reason})}
  end

  def handle_cast({:mark_phase, ref, phase}, state) do
    if Map.has_key?(state.leases, ref) do
      {:noreply, put_in(state, [Access.key(:leases), ref, :phase], phase)}
    else
      {:noreply, state}
    end
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
    {:noreply, kill_until_confirmed(state, ref, 1)}
  end

  def handle_info({:confirm_exit, ref, attempt}, state) do
    {:noreply, kill_until_confirmed(state, ref, attempt)}
  end

  def handle_info({:retry_term, ref, timeout, attempt}, state) do
    {:noreply, retry_term(state, ref, timeout, attempt)}
  end

  def handle_info({:grace_poll, ref}, state) do
    {:noreply, poll_term_grace(state, ref)}
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
        log_reap(lease, reason)
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

  defp start_live_process_reaping(state, ref, lease, timeout),
    do: term_or_retry(state, ref, lease, timeout, 1)

  defp term_or_retry(state, ref, lease, timeout, attempt) do
    signal_result =
      WorkerProcessLifecycle.signal_owned_process(lease.os_pid, lease.os_identity, "-TERM")

    cond do
      signal_result == {:error, :identity_mismatch} ->
        # The PID now belongs to another process, so ours has exited.
        cleanup_lease(state, ref)

      WorkerProcessLifecycle.custody_refused?(signal_result) ->
        # An unreadable identity proves nothing. Keep custody and retry TERM, so
        # the runtime still gets its grace once the identity reads again.
        log_unconfirmed_exit(lease, attempt)

        timer_ref =
          Process.send_after(self(), {:retry_term, ref, timeout, attempt}, backoff_ms(attempt))

        put_in(state, [Access.key(:leases), ref, :timer_ref], timer_ref)

      true ->
        start_term_grace(state, ref, timeout)
    end
  end

  defp retry_term(state, ref, timeout, attempt) do
    case state.leases[ref] do
      nil ->
        state

      lease ->
        if exit_confirmed?(lease),
          do: cleanup_lease(state, ref),
          else: term_or_retry(state, ref, lease, timeout, attempt + 1)
    end
  end

  defp start_term_grace(state, ref, timeout) do
    timer_ref = Process.send_after(self(), {:escalate, ref}, timeout)
    Process.send_after(self(), {:grace_poll, ref}, @grace_poll_ms)

    state
    |> put_in([Access.key(:leases), ref, :timer_ref], timer_ref)
    |> put_in(
      [Access.key(:leases), ref, :term_deadline],
      System.monotonic_time(:millisecond) + timeout
    )
  end

  # A runtime that exits within its TERM grace frees its slot at once instead of
  # holding custody until the escalation timer fires.
  defp poll_term_grace(state, ref) do
    case state.leases[ref] do
      %{term_deadline: deadline} = lease when is_integer(deadline) ->
        cond do
          exit_confirmed?(lease) ->
            cleanup_lease(state, ref)

          System.monotonic_time(:millisecond) < deadline ->
            Process.send_after(self(), {:grace_poll, ref}, @grace_poll_ms)
            state

          true ->
            state
        end

      _other ->
        state
    end
  end

  defp kill_until_confirmed(state, ref, attempt) do
    case state.leases[ref] do
      nil ->
        state

      lease ->
        if exit_confirmed?(lease) do
          cleanup_lease(state, ref)
        else
          log_unconfirmed_exit(lease, attempt)
          _ = WorkerProcessLifecycle.kill_owned_process_tree(lease.os_pid, lease.os_identity)
          schedule_confirm(state, ref, attempt + 1)
        end
    end
  end

  # Exit is confirmed when the process is gone, or when its PID now belongs to a
  # different process. A missing or unreadable identity is not proof.
  defp exit_confirmed?(%{os_pid: os_pid, os_identity: identity}) do
    cond do
      not WorkerProcessLifecycle.os_process_alive?(os_pid) ->
        true

      is_nil(identity) ->
        false

      true ->
        case WorkerProcessLifecycle.process_identity(os_pid) do
          {:ok, current} -> current != identity
          {:error, :identity_unavailable} -> false
        end
    end
  end

  defp backoff_ms(attempt),
    do: min(@confirm_base_ms * Integer.pow(2, min(attempt - 1, 5)), @confirm_max_ms)

  defp schedule_confirm(state, ref, attempt) do
    timer_ref = Process.send_after(self(), {:confirm_exit, ref, attempt}, backoff_ms(attempt))

    put_in(state, [Access.key(:leases), ref, :timer_ref], timer_ref)
  end

  defp log_unconfirmed_exit(lease, attempt) when attempt == 1 or rem(attempt, 10) == 0 do
    Logger.warning(
      "worker process exit not yet confirmed; keeping custody " <>
        inspect(%{model_ref: lease.model_ref, os_pid: lease.os_pid, attempt: attempt})
    )
  end

  defp log_unconfirmed_exit(_lease, _attempt), do: :ok

  defp model_key(%{model_id: model_id, version: version}), do: {model_id, version}
  defp model_key(_model_ref), do: nil

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

  defp log_reap(lease, {:owner_down, reason}) do
    details =
      inspect(%{
        model_ref: lease.model_ref,
        os_pid: lease.os_pid,
        owner_reason: reason,
        phase: lease.phase
      })

    if owner_stopped?(reason) do
      Logger.info("reaping worker process after its owner stopped " <> details)
    else
      Logger.warning("reaping orphaned worker process " <> details)
    end
  end

  defp log_reap(_lease, _reason), do: :ok

  defp owner_stopped?(:shutdown), do: true
  defp owner_stopped?({:shutdown, _detail}), do: true
  defp owner_stopped?(_reason), do: false

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
