defmodule Orchard.DispatchCapacity.AllocationAuthority do
  @moduledoc """
  Owns live Controller-local dispatch-capacity claims.

  Acquisition and release are serialized per Controller process. Durable
  permits and recovery after a Controller crash remain outside this boundary.
  """

  use GenServer

  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.Evaluator.Input

  defmodule Claim do
    @moduledoc "Opaque ownership proof for one live Node capacity claim."

    @enforce_keys [:token, :node_id, :request_id, :kind, :owner, :monitor_ref]
    defstruct @enforce_keys

    @type kind :: :f11 | :legacy
    @type t :: %__MODULE__{
            token: reference(),
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
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            token: reference(),
            node_id: Ecto.UUID.t(),
            owner: pid(),
            monitor_ref: reference()
          }
  end

  @gate_poll_interval_ms 25

  @type acceptance_gate_error ::
          :dispatch_capacity_acceptance_gate_busy
          | :dispatch_capacity_authority_unavailable

  @type acquire_result ::
          {:ok, Claim.t(), Evaluator.Result.t()}
          | {:error, :dispatch_capacity_unavailable, Evaluator.Result.t()}
          | {:error, :dispatch_capacity_request_already_claimed, Evaluator.Result.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, %{})
      name -> GenServer.start_link(__MODULE__, %{}, name: name)
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

  @doc "Releases a claim idempotently."
  @spec release(Claim.t()) :: :ok
  def release(%Claim{} = claim), do: release(__MODULE__, claim)

  @spec release(GenServer.server(), Claim.t()) :: :ok
  def release(server, %Claim{} = claim) do
    GenServer.call(server, {:release, claim.token})
  end

  @doc """
  Blocks new acquisition and revalidation for a Node until this authority restarts.

  Quarantine is per-Node. `nil` is not a Node identity — unmanaged and
  compatibility evaluations share it — so quarantining `nil` is a no-op rather
  than a cluster-wide block on every unmanaged evaluation.
  """
  @spec quarantine_node(Ecto.UUID.t() | nil) :: :ok
  def quarantine_node(node_id), do: quarantine_node(__MODULE__, node_id)

  @spec quarantine_node(GenServer.server(), Ecto.UUID.t() | nil) :: :ok
  def quarantine_node(_server, nil), do: :ok

  def quarantine_node(server, node_id) when is_binary(node_id) do
    GenServer.call(server, {:quarantine_node, node_id})
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
  responsive poll with a deadline instead of waiting unboundedly. A dead or
  restarting authority is reported as an error rather than exiting the caller.
  """
  @spec try_acquire_acceptance_gate(GenServer.server(), Ecto.UUID.t(), timeout()) ::
          {:ok, AcceptanceLease.t()} | {:error, acceptance_gate_error()}
  def try_acquire_acceptance_gate(server, node_id, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_acceptance_gate(server, node_id, deadline)
  end

  defp poll_acceptance_gate(server, node_id, deadline) do
    case call_acceptance_gate(server, node_id) do
      {:ok, _lease} = acquired ->
        acquired

      :busy ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@gate_poll_interval_ms)
          poll_acceptance_gate(server, node_id, deadline)
        else
          {:error, :dispatch_capacity_acceptance_gate_busy}
        end

      :unavailable ->
        {:error, :dispatch_capacity_authority_unavailable}
    end
  end

  defp call_acceptance_gate(server, node_id) do
    GenServer.call(server, {:try_acquire_acceptance_gate, node_id})
  catch
    :exit, _reason -> :unavailable
  end

  @doc "Releases an acceptance-gate lease idempotently."
  @spec release_acceptance_gate(AcceptanceLease.t()) :: :ok
  def release_acceptance_gate(%AcceptanceLease{} = lease) do
    release_acceptance_gate(__MODULE__, lease)
  end

  @spec release_acceptance_gate(GenServer.server(), AcceptanceLease.t()) :: :ok
  def release_acceptance_gate(server, %AcceptanceLease{} = lease) do
    GenServer.call(server, {:release_acceptance_gate, lease})
  end

  @impl true
  def init(_init_arg) do
    {:ok,
     %{
       claims: %{},
       request_claims: %{},
       monitors: %{},
       gates: %{},
       gate_monitors: %{},
       quarantined_nodes: MapSet.new()
     }}
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
            node_id: node_id,
            request_id: request_id,
            kind: kind,
            owner: owner,
            monitor_ref: monitor_ref
          }

          claims = Map.put(state.claims, claim.token, claim)
          request_claims = Map.put(state.request_claims, request_id, claim.token)
          monitors = Map.put(state.monitors, monitor_ref, claim.token)

          {:reply, {:ok, claim, result},
           %{state | claims: claims, request_claims: request_claims, monitors: monitors}}

        :error ->
          {:reply, {:error, :dispatch_capacity_unavailable, result}, state}
      end
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, remove_claim(state, token)}
  end

  def handle_call({:quarantine_node, node_id}, _from, state) when is_binary(node_id) do
    quarantined_nodes = MapSet.put(state.quarantined_nodes, node_id)
    {:reply, :ok, %{state | quarantined_nodes: quarantined_nodes}}
  end

  def handle_call({:claim_count, node_id}, _from, state) do
    count = Enum.count(state.claims, fn {_token, claim} -> claim.node_id == node_id end)
    {:reply, count, state}
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
        waiters = :queue.in(from, gate.waiters)
        gates = Map.put(state.gates, node_id, %{gate | waiters: waiters})
        {:noreply, %{state | gates: gates}}
    end
  end

  def handle_call({:try_acquire_acceptance_gate, node_id}, from, state) do
    case Map.get(state.gates, node_id) do
      nil ->
        {lease, state} = put_gate_owner(state, node_id, from, :queue.new())
        {:reply, {:ok, lease}, state}

      _held ->
        {:reply, :busy, state}
    end
  end

  def handle_call({:release_acceptance_gate, lease}, _from, state) do
    {:reply, :ok, release_gate(state, lease)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _owner, _reason}, state) do
    cond do
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
    {f11_count, legacy_count} = claim_counts(state.claims, node_id, excluded_token)

    input =
      if MapSet.member?(state.quarantined_nodes, node_id),
        do: %{input | health: :unreachable},
        else: input

    input
    |> Map.put(:controller_accounted_allocation, f11_count)
    |> Map.put(:temporary_legacy_claim_count, legacy_count)
    |> Evaluator.evaluate()
  end

  defp claim_counts(claims, node_id, excluded_token) do
    Enum.reduce(claims, {0, 0}, fn
      {token, _claim}, counts when token == excluded_token ->
        counts

      {_token, %Claim{node_id: ^node_id, kind: :f11}}, {f11, legacy} ->
        {f11 + 1, legacy}

      {_token, %Claim{node_id: ^node_id, kind: :legacy}}, {f11, legacy} ->
        {f11, legacy + 1}

      _claim, counts ->
        counts
    end)
  end

  defp remove_claim(state, token) do
    case Map.pop(state.claims, token) do
      {nil, _claims} ->
        state

      {%Claim{monitor_ref: monitor_ref, request_id: request_id}, claims} ->
        Process.demonitor(monitor_ref, [:flush])
        monitors = Map.delete(state.monitors, monitor_ref)
        request_claims = Map.delete(state.request_claims, request_id)
        %{state | claims: claims, request_claims: request_claims, monitors: monitors}
    end
  end

  defp revalidation_result(
         :f11,
         %Evaluator.Result{
           authority_decision: :f11_enforcing,
           eligible?: true,
           available_slots: slots
         } = result
       )
       when slots > 0,
       do: {:ok, result}

  defp revalidation_result(
         :legacy,
         %Evaluator.Result{
           authority_decision: :legacy_pre_cutover,
           eligible?: true,
           available_slots: slots
         } = result
       )
       when slots > 0,
       do: {:ok, result}

  defp revalidation_result(_kind, %Evaluator.Result{} = result),
    do: {:error, :dispatch_capacity_revalidation_failed, result}

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

  defp advance_gate(state, node_id, waiters) do
    case :queue.out(waiters) do
      {:empty, _waiters} ->
        %{state | gates: Map.delete(state.gates, node_id)}

      {{:value, from}, remaining_waiters} ->
        {lease, state} = put_gate_owner(state, node_id, from, remaining_waiters)
        GenServer.reply(from, {:ok, lease})
        state
    end
  end

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
