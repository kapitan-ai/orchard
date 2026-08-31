defmodule Orchard.DispatchCapacity.AllocationAuthority do
  @moduledoc """
  Owns live Controller-local dispatch-capacity claims.

  Acquisition and release are serialized per Controller process. Durable
  permits and recovery after a Controller crash remain outside this boundary.

  The authority mirrors the quarantine set it seeds from `QuarantineStore`, so
  evaluation never blocks on a second process. Losing the store — at boot or
  later — leaves the mirror unusable, and every Node then evaluates as
  unreachable rather than as free capacity, per `SPEC.md` §4.6.2.
  """

  use GenServer

  alias Orchard.DispatchCapacity.{Evaluator, QuarantineStore}
  alias Orchard.DispatchCapacity.Evaluator.Input

  require Logger

  defmodule Claim do
    @moduledoc "Opaque ownership proof for one live Node capacity claim."

    @enforce_keys [
      :token,
      :authority_incarnation,
      :node_id,
      :request_id,
      :kind,
      :owner,
      :monitor_ref
    ]
    defstruct @enforce_keys

    @type kind :: :f11 | :legacy
    @type t :: %__MODULE__{
            token: reference(),
            authority_incarnation: reference(),
            node_id: Ecto.UUID.t(),
            request_id: String.t(),
            kind: kind(),
            owner: pid(),
            monitor_ref: reference()
          }
  end

  defmodule AcceptanceLease do
    @moduledoc "Opaque ownership proof for one per-Node acceptance gate."

    @enforce_keys [:token, :node_id, :owner, :monitor_ref]
    defstruct [:token, :node_id, :owner, :monitor_ref, guardian: nil]

    @type t :: %__MODULE__{
            token: reference(),
            node_id: Ecto.UUID.t(),
            owner: pid(),
            monitor_ref: reference(),
            guardian: pid() | nil
          }
  end

  @gate_response_margin_ms 1
  @gate_cleanup_timeout_ms 25

  @type acceptance_gate_error ::
          :dispatch_capacity_acceptance_gate_busy
          | :dispatch_capacity_authority_unavailable
          | :dispatch_capacity_caller_down

  @type acquire_result ::
          {:ok, Claim.t(), Evaluator.Result.t()}
          | {:error, :dispatch_capacity_unavailable, Evaluator.Result.t()}
          | {:error, :dispatch_capacity_request_already_claimed, Evaluator.Result.t()}

  @type quarantine_error :: :dispatch_capacity_quarantine_store_unavailable
  @type release_outcome :: :released | :already_released | :unresolved

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    init_arg = %{
      quarantine_store: Keyword.get(opts, :quarantine_store, QuarantineStore),
      acceptance_gate_queue_observer: Keyword.get(opts, :acceptance_gate_queue_observer)
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  @doc "Atomically evaluates and acquires one available Node capacity unit."
  @spec acquire(Ecto.UUID.t(), String.t(), Input.t()) :: acquire_result()
  def acquire(node_id, request_id, %Input{} = input) do
    acquire(__MODULE__, node_id, request_id, input)
  end

  @spec acquire(GenServer.server(), Ecto.UUID.t(), String.t(), Input.t()) :: acquire_result()
  def acquire(server, node_id, request_id, %Input{} = input) do
    GenServer.call(server, {:acquire, node_id, request_id, input})
  end

  @doc "Releases a claim idempotently and reports whether ownership was resolved."
  @spec release(Claim.t()) :: release_outcome()
  def release(%Claim{} = claim), do: release(__MODULE__, claim)

  @spec release(GenServer.server(), Claim.t()) :: release_outcome()
  def release(server, %Claim{} = claim) do
    GenServer.call(server, {:release, claim})
  catch
    :exit, _reason -> :unresolved
  end

  @doc """
  Blocks new acquisition and revalidation for a Node after unresolved execution.

  Quarantine is per-Node. `nil` is not a Node identity — unmanaged and
  compatibility evaluations share it — so quarantining `nil` is a no-op rather
  than a cluster-wide block on every unmanaged evaluation.

  The block does not expire or expose an unauthenticated operator-release seam.
  Recovery requires verified reconciliation that proves the unresolved runtime
  execution is absent. That durable recovery flow remains outside this tracer.
  """
  @spec quarantine_node(Ecto.UUID.t() | nil) :: :ok | {:error, quarantine_error()}
  def quarantine_node(node_id), do: quarantine_node(__MODULE__, node_id)

  @spec quarantine_node(GenServer.server(), Ecto.UUID.t() | nil) ::
          :ok | {:error, quarantine_error()}
  def quarantine_node(_server, nil), do: :ok

  def quarantine_node(server, node_id) when is_binary(node_id) do
    GenServer.call(server, {:quarantine_node, node_id})
  end

  @doc "Returns the Node identities blocked by unresolved execution."
  @spec quarantined_nodes() :: MapSet.t(Ecto.UUID.t()) | {:error, quarantine_error()}
  def quarantined_nodes, do: quarantined_nodes(__MODULE__)

  @spec quarantined_nodes(GenServer.server()) ::
          MapSet.t(Ecto.UUID.t()) | {:error, quarantine_error()}
  def quarantined_nodes(server), do: GenServer.call(server, :quarantined_nodes)

  @doc """
  Returns the live Controller-owned dispatch claims.

  Read-only callers with their own latency budget pass `:timeout` instead of
  waiting the default `GenServer.call/3` five seconds.
  """
  @spec live_claims() :: [Claim.t()]
  def live_claims, do: live_claims(__MODULE__)

  @spec live_claims(GenServer.server()) :: [Claim.t()]
  @spec live_claims(GenServer.server(), keyword()) :: [Claim.t()]
  def live_claims(server, opts \\ []) do
    GenServer.call(server, :live_claims, Keyword.get(opts, :timeout, 5_000))
  end

  @doc "Returns the number of live claims owned for one Node."
  @spec claim_count(Ecto.UUID.t()) :: non_neg_integer()
  def claim_count(node_id), do: claim_count(__MODULE__, node_id)

  @spec claim_count(GenServer.server(), Ecto.UUID.t()) :: non_neg_integer()
  def claim_count(server, node_id) do
    GenServer.call(server, {:claim_count, node_id})
  end

  @doc "Evaluates capacity with the current serialized Node claim counts."
  @spec evaluate(Ecto.UUID.t() | nil, Input.t()) :: Evaluator.Result.t()
  def evaluate(node_id, %Input{} = input), do: evaluate(__MODULE__, node_id, input)

  @spec evaluate(GenServer.server(), Ecto.UUID.t() | nil, Input.t()) :: Evaluator.Result.t()
  def evaluate(server, node_id, %Input{} = input) do
    GenServer.call(server, {:evaluate, node_id, input})
  end

  @doc "Revalidates one recognized claim without counting that claim twice."
  @spec revalidate(Claim.t(), Input.t()) ::
          {:ok, Evaluator.Result.t()}
          | {:error, :dispatch_capacity_revalidation_failed, Evaluator.Result.t()}
  def revalidate(%Claim{} = claim, %Input{} = input) do
    revalidate(__MODULE__, claim, input)
  end

  @spec revalidate(GenServer.server(), Claim.t(), Input.t()) ::
          {:ok, Evaluator.Result.t()}
          | {:error, :dispatch_capacity_revalidation_failed, Evaluator.Result.t()}
  def revalidate(server, %Claim{} = claim, %Input{} = input) do
    GenServer.call(server, {:revalidate, claim, input})
  end

  @doc "Acquires the Controller-local acceptance gate for one Node."
  @spec acquire_acceptance_gate(Ecto.UUID.t()) :: {:ok, AcceptanceLease.t()}
  def acquire_acceptance_gate(node_id), do: acquire_acceptance_gate(__MODULE__, node_id)

  @spec acquire_acceptance_gate(GenServer.server(), Ecto.UUID.t()) ::
          {:ok, AcceptanceLease.t()}
  def acquire_acceptance_gate(server, node_id) do
    GenServer.call(server, {:acquire_acceptance_gate, node_id}, :infinity)
  end

  @doc """
  Acquires the acceptance gate for one Node without queueing behind dispatch.

  Dispatch can hold the gate for a whole request, so callers that must stay
  responsive wait with a deadline instead of waiting unboundedly. Waiting is
  ordered: a bounded caller joins the same per-Node FIFO queue as an unbounded
  one, so a contended Node grants in arrival order rather than by race, and no
  caller polls the authority while it waits. A dead or restarting authority is
  reported as an error rather than exiting the caller.

  Waiting runs in a short-lived guardian process that owns the lease, so a
  grant that arrives after the caller's deadline is released instead of leaving
  the gate held forever. The lease is likewise released when the caller dies,
  and `release_acceptance_gate/1,2` stops the guardian.
  """
  @spec try_acquire_acceptance_gate(GenServer.server(), Ecto.UUID.t(), timeout()) ::
          {:ok, AcceptanceLease.t()} | {:error, acceptance_gate_error()}
  def try_acquire_acceptance_gate(server, node_id, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    try_acquire_acceptance_gate(server, node_id, timeout_ms, nil, nil)
  end

  @spec try_acquire_acceptance_gate(
          GenServer.server(),
          Ecto.UUID.t(),
          timeout(),
          reference() | nil
        ) :: {:ok, AcceptanceLease.t()} | {:error, acceptance_gate_error()}
  def try_acquire_acceptance_gate(server, node_id, timeout_ms, abort_monitor_ref)
      when is_integer(timeout_ms) and timeout_ms >= 0 and
             (is_reference(abort_monitor_ref) or is_nil(abort_monitor_ref)) do
    try_acquire_acceptance_gate(server, node_id, timeout_ms, abort_monitor_ref, nil)
  end

  @spec try_acquire_acceptance_gate(
          GenServer.server(),
          Ecto.UUID.t(),
          timeout(),
          reference() | nil,
          pid() | nil
        ) :: {:ok, AcceptanceLease.t()} | {:error, acceptance_gate_error()}
  def try_acquire_acceptance_gate(
        server,
        node_id,
        timeout_ms,
        abort_monitor_ref,
        abort_pid
      )
      when is_integer(timeout_ms) and timeout_ms >= 0 and
             (is_reference(abort_monitor_ref) or is_nil(abort_monitor_ref)) and
             (is_pid(abort_pid) or is_nil(abort_pid)) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    caller = self()
    request_ref = make_ref()

    {guardian, monitor_ref} =
      spawn_monitor(fn ->
        acceptance_gate_guardian(caller, request_ref, server, node_id, deadline, abort_pid)
      end)

    await_acceptance_gate(
      server,
      node_id,
      guardian,
      monitor_ref,
      request_ref,
      deadline,
      abort_monitor_ref
    )
  end

  defp poll_acceptance_gate(server, node_id, deadline, abort_pid) do
    remaining_ms = remaining_ms(deadline)

    if remaining_ms <= 0 do
      {:error, :dispatch_capacity_acceptance_gate_busy}
    else
      case call_acceptance_gate(server, node_id, deadline, remaining_ms, abort_pid) do
        {:ok, _lease} = acquired ->
          acquired

        :expired ->
          {:error, :dispatch_capacity_acceptance_gate_busy}

        :unavailable ->
          {:error, :dispatch_capacity_authority_unavailable}

        :caller_down ->
          {:error, :dispatch_capacity_caller_down}
      end
    end
  end

  defp call_acceptance_gate(server, node_id, deadline, remaining_ms, abort_pid) do
    timeout_ms = max(remaining_ms - @gate_response_margin_ms, 1)

    GenServer.call(
      server,
      {:try_acquire_acceptance_gate, node_id, deadline, abort_pid},
      timeout_ms
    )
  catch
    :exit, {:timeout, _call} -> :expired
    :exit, _reason -> :unavailable
  end

  defp acceptance_gate_guardian(caller, request_ref, server, node_id, deadline, abort_pid) do
    caller_monitor = Process.monitor(caller)

    case poll_acceptance_gate(server, node_id, deadline, abort_pid) do
      {:ok, lease} ->
        lease = %{lease | guardian: self()}
        send(caller, {request_ref, {:ok, lease}})
        await_guardian_release(caller_monitor, lease.token)

      {:error, _reason} = error ->
        send(caller, {request_ref, error})
    end
  end

  defp await_acceptance_gate(
         server,
         node_id,
         guardian,
         monitor_ref,
         request_ref,
         deadline,
         abort_monitor_ref
       ) do
    receive do
      {^request_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^guardian, _reason} ->
        {:error, :dispatch_capacity_authority_unavailable}

      {:DOWN, ^abort_monitor_ref, :process, _caller, _reason}
      when is_reference(abort_monitor_ref) ->
        stop_acceptance_gate_guardian(server, node_id, guardian, monitor_ref, request_ref)
        {:error, :dispatch_capacity_caller_down}
    after
      remaining_ms(deadline) ->
        stop_acceptance_gate_guardian(server, node_id, guardian, monitor_ref, request_ref)
        {:error, :dispatch_capacity_acceptance_gate_busy}
    end
  end

  defp stop_acceptance_gate_guardian(server, node_id, guardian, monitor_ref, request_ref) do
    Process.exit(guardian, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^guardian, _reason} -> :ok
    end

    release_guardian_gate(server, node_id, guardian)
    flush_acceptance_gate_result(request_ref)
  end

  defp release_guardian_gate(server, node_id, guardian) do
    GenServer.call(
      server,
      {:release_acceptance_gate_owner, node_id, guardian},
      @gate_cleanup_timeout_ms
    )
  catch
    :exit, _reason -> :ok
  end

  defp await_guardian_release(caller_monitor, request_ref) do
    receive do
      {^request_ref, :release} -> :ok
      {:DOWN, ^caller_monitor, :process, _caller, _reason} -> :ok
    end
  end

  defp flush_acceptance_gate_result(request_ref) do
    receive do
      {^request_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  @doc "Releases an acceptance-gate lease idempotently."
  @spec release_acceptance_gate(AcceptanceLease.t()) :: :ok
  def release_acceptance_gate(%AcceptanceLease{} = lease) do
    release_acceptance_gate(__MODULE__, lease)
  end

  @spec release_acceptance_gate(GenServer.server(), AcceptanceLease.t()) :: :ok
  def release_acceptance_gate(server, %AcceptanceLease{} = lease) do
    GenServer.call(server, {:release_acceptance_gate, lease})
  catch
    :exit, _reason -> :ok
  after
    release_guardian(lease)
  end

  defp release_guardian(%AcceptanceLease{guardian: guardian, token: token})
       when is_pid(guardian) do
    send(guardian, {token, :release})
    :ok
  end

  defp release_guardian(%AcceptanceLease{}), do: :ok

  @impl true
  def init(%{
        acceptance_gate_queue_observer: acceptance_gate_queue_observer,
        quarantine_store: quarantine_store
      }) do
    base = %{
      authority_incarnation: make_ref(),
      claims: %{},
      claim_counts: %{},
      request_claims: %{},
      monitors: %{},
      gates: %{},
      gate_monitors: %{},
      acceptance_gate_queue_observer: acceptance_gate_queue_observer
    }

    case resolve_quarantine_store(quarantine_store) do
      {:ok, quarantine_store_pid, quarantined_nodes} ->
        {:ok,
         Map.merge(base, %{
           quarantined_nodes: quarantined_nodes,
           quarantine_store: quarantine_store_pid,
           quarantine_store_available?: true,
           quarantine_store_monitor_ref: Process.monitor(quarantine_store_pid)
         })}

      :error ->
        Logger.error(
          "dispatch-capacity authority started without a reachable quarantine store; all " <>
            "dispatch remains blocked until the Controller is recovered through a verified " <>
            "reconciliation path"
        )

        {:ok, Map.merge(base, mark_quarantine_store_unavailable(%{}))}
    end
  end

  @impl true
  def handle_call({:acquire, node_id, request_id, input}, {owner, _tag}, state) do
    result = evaluate_with_live_claims(input, node_id, state)

    if Map.has_key?(state.request_claims, request_id) do
      {:reply, {:error, :dispatch_capacity_request_already_claimed, result}, state}
    else
      case claim_kind(result) do
        {:ok, kind} ->
          monitor_ref = Process.monitor(owner)

          claim = %Claim{
            token: make_ref(),
            authority_incarnation: state.authority_incarnation,
            node_id: node_id,
            request_id: request_id,
            kind: kind,
            owner: owner,
            monitor_ref: monitor_ref
          }

          claims = Map.put(state.claims, claim.token, claim)
          claim_counts = adjust_claim_count(state.claim_counts, node_id, kind, 1)
          request_claims = Map.put(state.request_claims, request_id, claim.token)
          monitors = Map.put(state.monitors, monitor_ref, claim.token)

          {:reply, {:ok, claim, result},
           %{
             state
             | claims: claims,
               claim_counts: claim_counts,
               request_claims: request_claims,
               monitors: monitors
           }}

        :error ->
          {:reply, {:error, :dispatch_capacity_unavailable, result}, state}
      end
    end
  end

  def handle_call({:release, %Claim{} = claim}, _from, state) do
    {outcome, state} = release_claim(state, claim)
    {:reply, outcome, state}
  end

  def handle_call({:quarantine_node, node_id}, _from, state) when is_binary(node_id) do
    {reply, state} = quarantine_node_in_store(state, node_id)
    log_quarantine_outcome(reply, node_id)
    {:reply, reply, state}
  end

  def handle_call(:quarantined_nodes, _from, state) do
    {reply, state} = quarantined_nodes_from_store(state)
    {:reply, reply, state}
  end

  def handle_call(:live_claims, _from, state) do
    {:reply, Map.values(state.claims), state}
  end

  def handle_call({:claim_count, node_id}, _from, state) do
    {f11_count, legacy_count} = claim_counts(state, node_id, nil)
    {:reply, f11_count + legacy_count, state}
  end

  def handle_call({:evaluate, node_id, input}, _from, state) do
    {:reply, evaluate_with_live_claims(input, node_id, state), state}
  end

  def handle_call({:revalidate, %Claim{} = claim, input}, _from, state) do
    result =
      evaluate_with_live_claims(input, claim.node_id, state, claim.token)

    reply =
      case Map.get(state.claims, claim.token) do
        %Claim{node_id: node_id, kind: kind}
        when node_id == claim.node_id and kind == claim.kind ->
          revalidation_result(kind, result)

        _missing_or_foreign ->
          {:error, :dispatch_capacity_revalidation_failed, result}
      end

    {:reply, reply, state}
  end

  def handle_call({:acquire_acceptance_gate, node_id}, from, state) do
    case Map.get(state.gates, node_id) do
      nil ->
        {lease, state} = put_gate_owner(state, node_id, from, :queue.new())
        {:reply, {:ok, lease}, state}

      gate ->
        {:noreply, enqueue_gate_waiter(state, node_id, gate, {from, :infinity, nil})}
    end
  end

  def handle_call(
        {:try_acquire_acceptance_gate, node_id, deadline, abort_pid},
        {owner, _tag} = from,
        state
      ) do
    cond do
      is_pid(abort_pid) and not Process.alive?(abort_pid) ->
        {:reply, :caller_down, state}

      remaining_ms(deadline) <= 0 or not Process.alive?(owner) ->
        {:reply, :expired, state}

      gate = Map.get(state.gates, node_id) ->
        {:noreply, enqueue_gate_waiter(state, node_id, gate, {from, deadline, abort_pid})}

      true ->
        {lease, state} = put_gate_owner(state, node_id, from, :queue.new())
        {:reply, {:ok, lease}, state}
    end
  end

  def handle_call({:release_acceptance_gate, lease}, _from, state) do
    {:reply, :ok, release_gate(state, lease)}
  end

  def handle_call({:release_acceptance_gate_owner, node_id, owner}, _from, state) do
    state =
      case Map.get(state.gates, node_id) do
        %{lease: %AcceptanceLease{owner: ^owner} = lease} -> release_gate(state, lease)
        _missing_or_foreign -> state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _owner, _reason}, state) do
    cond do
      state.quarantine_store_monitor_ref == monitor_ref ->
        Logger.error(
          "dispatch-capacity quarantine store stopped; all dispatch remains blocked until " <>
            "the Controller is recovered through a verified reconciliation path"
        )

        {:noreply, mark_quarantine_store_unavailable(state)}

      Map.has_key?(state.monitors, monitor_ref) ->
        token = Map.fetch!(state.monitors, monitor_ref)
        {:noreply, remove_claim(state, token)}

      Map.has_key?(state.gate_monitors, monitor_ref) ->
        {node_id, gate_monitors} = Map.pop!(state.gate_monitors, monitor_ref)
        gate = Map.fetch!(state.gates, node_id)
        state = %{state | gate_monitors: gate_monitors}
        {:noreply, advance_gate(state, node_id, gate.waiters)}

      true ->
        {:noreply, state}
    end
  end

  defp evaluate_with_live_claims(input, node_id, state, excluded_token \\ nil) do
    {f11_count, legacy_count} = claim_counts(state, node_id, excluded_token)

    input =
      case quarantine_status(state, node_id) do
        false -> input
        true -> %{input | health: :unreachable}
        :unavailable -> %{input | health: :unreachable}
      end

    input
    |> Map.put(:controller_accounted_allocation, f11_count)
    |> Map.put(:temporary_legacy_claim_count, legacy_count)
    |> Evaluator.evaluate()
  end

  defp resolve_quarantine_store(quarantine_store) do
    quarantine_store
    |> quarantine_store_pid()
    |> probe_quarantine_store()
  end

  defp probe_quarantine_store(pid) when is_pid(pid) do
    case safe_quarantine_store_call(fn -> QuarantineStore.quarantined_nodes(pid) end) do
      {:ok, %MapSet{} = quarantined_nodes} -> {:ok, pid, quarantined_nodes}
      _unavailable -> :error
    end
  end

  defp probe_quarantine_store(_missing), do: :error

  defp quarantine_store_pid(pid) when is_pid(pid), do: pid
  defp quarantine_store_pid(name) when is_atom(name), do: Process.whereis(name)

  defp quarantine_store_pid({:global, name}) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  defp quarantine_store_pid({:via, module, name}) do
    case module.whereis_name(name) do
      pid when is_pid(pid) -> pid
      _missing -> nil
    end
  end

  defp quarantine_store_pid(_unsupported), do: nil

  defp quarantine_node_in_store(state, node_id) do
    case call_quarantine_store(state, &QuarantineStore.quarantine(&1, node_id)) do
      {:ok, state} ->
        {:ok, %{state | quarantined_nodes: MapSet.put(state.quarantined_nodes, node_id)}}

      unavailable ->
        unavailable
    end
  end

  defp log_quarantine_outcome(:ok, node_id) do
    Logger.warning(
      "dispatch-capacity authority quarantined node #{node_id} after an unreconciled " <>
        "dispatch; it remains excluded until verified reconciliation proves the runtime " <>
        "execution is absent"
    )
  end

  defp log_quarantine_outcome({:error, reason}, node_id) do
    Logger.error(
      "dispatch-capacity authority could not quarantine node #{node_id} after an " <>
        "unreconciled dispatch: #{inspect(reason)}; every Node evaluates as unreachable " <>
        "until the Controller is recovered through a verified reconciliation path"
    )
  end

  defp quarantined_nodes_from_store(%{quarantine_store_available?: false} = state) do
    {{:error, :dispatch_capacity_quarantine_store_unavailable}, state}
  end

  defp quarantined_nodes_from_store(state), do: {state.quarantined_nodes, state}

  defp call_quarantine_store(%{quarantine_store_available?: false} = state, _call) do
    {{:error, :dispatch_capacity_quarantine_store_unavailable}, state}
  end

  defp call_quarantine_store(state, call) do
    case safe_quarantine_store_call(fn -> call.(state.quarantine_store) end) do
      {:ok, reply} ->
        {reply, state}

      :error ->
        {{:error, :dispatch_capacity_quarantine_store_unavailable},
         mark_quarantine_store_unavailable(state)}
    end
  end

  defp quarantine_status(%{quarantine_store_available?: false}, _node_id), do: :unavailable
  defp quarantine_status(_state, nil), do: false

  defp quarantine_status(state, node_id) do
    MapSet.member?(state.quarantined_nodes, node_id)
  end

  defp safe_quarantine_store_call(call) do
    {:ok, call.()}
  catch
    :exit, _reason -> :error
  end

  defp mark_quarantine_store_unavailable(state) do
    Map.merge(state, %{
      quarantined_nodes: MapSet.new(),
      quarantine_store: nil,
      quarantine_store_available?: false,
      quarantine_store_monitor_ref: nil
    })
  end

  defp claim_counts(state, node_id, excluded_token) do
    counts = Map.get(state.claim_counts, node_id, {0, 0})

    case Map.get(state.claims, excluded_token) do
      %Claim{node_id: ^node_id, kind: kind} -> apply_claim_delta(counts, kind, -1)
      _foreign_or_missing -> counts
    end
  end

  defp adjust_claim_count(claim_counts, node_id, kind, delta) do
    case claim_counts |> Map.get(node_id, {0, 0}) |> apply_claim_delta(kind, delta) do
      {0, 0} -> Map.delete(claim_counts, node_id)
      counts -> Map.put(claim_counts, node_id, counts)
    end
  end

  defp apply_claim_delta({f11, legacy}, :f11, delta), do: {f11 + delta, legacy}
  defp apply_claim_delta({f11, legacy}, :legacy, delta), do: {f11, legacy + delta}

  defp release_claim(%{quarantine_store_available?: false} = state, %Claim{}) do
    {:unresolved, state}
  end

  defp release_claim(state, %Claim{authority_incarnation: incarnation})
       when incarnation != state.authority_incarnation do
    {:unresolved, state}
  end

  defp release_claim(state, %Claim{} = claim) do
    case Map.get(state.claims, claim.token) do
      ^claim -> {:released, remove_claim(state, claim.token)}
      nil -> {:already_released, state}
      _conflicting_claim -> {:unresolved, state}
    end
  end

  defp remove_claim(state, token) do
    case Map.pop(state.claims, token) do
      {nil, _claims} ->
        state

      {%Claim{} = claim, claims} ->
        Process.demonitor(claim.monitor_ref, [:flush])
        monitors = Map.delete(state.monitors, claim.monitor_ref)
        request_claims = Map.delete(state.request_claims, claim.request_id)
        claim_counts = adjust_claim_count(state.claim_counts, claim.node_id, claim.kind, -1)

        %{
          state
          | claims: claims,
            claim_counts: claim_counts,
            request_claims: request_claims,
            monitors: monitors
        }
    end
  end

  defp revalidation_result(kind, %Evaluator.Result{} = result) do
    if claim_kind(result) == {:ok, kind} do
      {:ok, result}
    else
      {:error, :dispatch_capacity_revalidation_failed, result}
    end
  end

  defp put_gate_owner(state, node_id, {owner, _tag}, waiters) do
    monitor_ref = Process.monitor(owner)

    lease = %AcceptanceLease{
      token: make_ref(),
      node_id: node_id,
      owner: owner,
      monitor_ref: monitor_ref
    }

    gate = %{lease: lease, waiters: waiters}
    gates = Map.put(state.gates, node_id, gate)
    gate_monitors = Map.put(state.gate_monitors, monitor_ref, node_id)
    {lease, %{state | gates: gates, gate_monitors: gate_monitors}}
  end

  defp release_gate(state, %AcceptanceLease{} = lease) do
    case Map.get(state.gates, lease.node_id) do
      %{lease: %{token: token}, waiters: waiters} when token == lease.token ->
        Process.demonitor(lease.monitor_ref, [:flush])
        gate_monitors = Map.delete(state.gate_monitors, lease.monitor_ref)
        state = %{state | gate_monitors: gate_monitors}
        advance_gate(state, lease.node_id, waiters)

      _missing_or_foreign ->
        state
    end
  end

  defp enqueue_gate_waiter(state, node_id, gate, waiter) do
    waiters = :queue.in(waiter, gate.waiters)
    state = %{state | gates: Map.put(state.gates, node_id, %{gate | waiters: waiters})}
    notify_gate_queue_observer(state.acceptance_gate_queue_observer, node_id)
    state
  end

  defp notify_gate_queue_observer({observer, tag}, node_id) when is_pid(observer) do
    send(observer, {tag, :acceptance_gate_waiter_queued, node_id})
    :ok
  end

  defp notify_gate_queue_observer(_observer, _node_id), do: :ok

  defp advance_gate(state, node_id, waiters) do
    case :queue.out(waiters) do
      {:empty, _waiters} ->
        %{state | gates: Map.delete(state.gates, node_id)}

      {{:value, {from, deadline, abort_pid}}, remaining_waiters} ->
        grant_gate_to_waiter(state, node_id, from, deadline, abort_pid, remaining_waiters)
    end
  end

  defp grant_gate_to_waiter(
         state,
         node_id,
         {owner, _tag} = from,
         deadline,
         abort_pid,
         remaining_waiters
       ) do
    cond do
      is_pid(abort_pid) and not Process.alive?(abort_pid) ->
        GenServer.reply(from, :caller_down)
        advance_gate(state, node_id, remaining_waiters)

      gate_waiter_live?(owner, deadline) ->
        {lease, state} = put_gate_owner(state, node_id, from, remaining_waiters)
        GenServer.reply(from, {:ok, lease})
        state

      true ->
        GenServer.reply(from, :expired)
        advance_gate(state, node_id, remaining_waiters)
    end
  end

  defp gate_waiter_live?(owner, :infinity), do: Process.alive?(owner)

  defp gate_waiter_live?(owner, deadline),
    do: remaining_ms(deadline) > 0 and Process.alive?(owner)

  defp claim_kind(%Evaluator.Result{
         eligible?: true,
         available_slots: slots,
         authority_decision: :f11_enforcing
       })
       when slots > 0,
       do: {:ok, :f11}

  defp claim_kind(%Evaluator.Result{
         eligible?: true,
         available_slots: slots,
         authority_decision: :legacy_pre_cutover
       })
       when slots > 0,
       do: {:ok, :legacy}

  defp claim_kind(%Evaluator.Result{}), do: :error
end
