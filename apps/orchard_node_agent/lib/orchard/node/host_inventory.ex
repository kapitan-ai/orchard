defmodule Orchard.Node.HostInventory do
  @moduledoc """
  Owns the last observation-only host inventory snapshot (`SPEC.md` §4.1).

  Collection runs in a linked process so a slow or failing provider never blocks
  the owner. The snapshot is published to a protected ETS table and read without
  a process call, so Runtime Endpoint status never waits on collection. A
  snapshot older than its maximum age reads as absent evidence.

  The owner starts only when a provider is explicitly configured; it is not a
  readiness, capacity, scheduling, or custody input.
  """

  use GenServer

  alias Orchard.Cluster.V1.HostInventoryObservation
  alias Orchard.RuntimeEndpoint.HostInventory, as: InventoryBound

  @default_refresh_ms 60_000
  @default_collection_timeout_ms 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Returns the current fresh snapshot without calling the owner, or `nil`."
  @spec current(atom()) :: HostInventoryObservation.t() | nil
  def current(name \\ __MODULE__) do
    case :ets.whereis(name) do
      :undefined -> nil
      table -> lookup(table)
    end
  end

  defp lookup(table) do
    case :ets.lookup(table, :snapshot) do
      [{:snapshot, observation, expires_at}] ->
        if System.monotonic_time(:millisecond) <= expires_at, do: observation

      [] ->
        nil
    end
  rescue
    # The owner deleted its table between whereis and lookup.
    ArgumentError -> nil
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(name, [:named_table, :protected, read_concurrency: true])
    refresh_ms = positive(opts, :refresh_ms, @default_refresh_ms)
    collection_timeout_ms = positive(opts, :collection_timeout_ms, @default_collection_timeout_ms)

    state = %{
      table: table,
      provider: Keyword.fetch!(opts, :provider),
      provider_opts: Keyword.get(opts, :provider_opts, []),
      refresh_ms: refresh_ms,
      collection_timeout_ms: collection_timeout_ms,
      max_age_ms: positive(opts, :max_age_ms, 3 * refresh_ms + collection_timeout_ms),
      collection: nil
    }

    {:ok, state, {:continue, :collect}}
  end

  @impl true
  def handle_continue(:collect, state), do: {:noreply, start_collection(state)}

  @impl true
  def handle_info(:refresh, %{collection: nil} = state), do: {:noreply, start_collection(state)}

  def handle_info({:collected, ref, observation}, %{collection: %{ref: ref}} = state) do
    bounded =
      InventoryBound.normalize(observation) ||
        error_observation(state, "inventory_out_of_bounds")

    {:noreply, finish_collection(state, bounded)}
  end

  def handle_info({:collection_timeout, ref}, %{collection: %{ref: ref, pid: pid}} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    {:noreply, finish_collection(state, error_observation(state, "provider_timeout"))}
  end

  def handle_info({:EXIT, pid, reason}, %{collection: %{pid: pid}} = state)
      when reason != :normal do
    {:noreply, finish_collection(state, error_observation(state, "provider_failed"))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_collection(state) do
    owner = self()
    ref = make_ref()
    %{provider: provider, provider_opts: provider_opts} = state

    pid = spawn_link(fn -> send(owner, {:collected, ref, provider.observe(provider_opts)}) end)
    timer = Process.send_after(owner, {:collection_timeout, ref}, state.collection_timeout_ms)
    %{state | collection: %{ref: ref, pid: pid, timer: timer}}
  end

  defp finish_collection(%{collection: collection} = state, observation) do
    Process.cancel_timer(collection.timer)
    expires_at = System.monotonic_time(:millisecond) + state.max_age_ms
    :ets.insert(state.table, {:snapshot, observation, expires_at})
    Process.send_after(self(), :refresh, state.refresh_ms)
    %{state | collection: nil}
  end

  defp error_observation(state, error_code) do
    state.provider.error_observation(System.system_time(:millisecond), error_code)
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end
end
