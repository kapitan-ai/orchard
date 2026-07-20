defmodule Orchard.DispatchCapacity.QuarantineStore do
  @moduledoc """
  Preserves unresolved-execution Node quarantines across authority child restarts.

  This private Controller-local store is supervised ahead of the inference
  subtree. It is a temporary child so losing its state cannot silently restart
  dispatch from a clean quarantine set. Durable recovery after the Controller
  stops remains outside the first enforcing tracer.
  """

  use GenServer

  @doc "Returns a temporary child spec that cannot restart with empty state."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  @spec quarantine(GenServer.server(), Ecto.UUID.t()) :: :ok
  def quarantine(server \\ __MODULE__, node_id) when is_binary(node_id) do
    GenServer.call(server, {:quarantine, node_id})
  end

  @spec quarantined?(GenServer.server(), Ecto.UUID.t() | nil) :: boolean()
  def quarantined?(server \\ __MODULE__, node_id)

  def quarantined?(_server, nil), do: false

  def quarantined?(server, node_id) when is_binary(node_id) do
    GenServer.call(server, {:quarantined?, node_id})
  end

  @spec quarantined_nodes(GenServer.server()) :: MapSet.t(Ecto.UUID.t())
  def quarantined_nodes(server \\ __MODULE__) do
    GenServer.call(server, :quarantined_nodes)
  end

  @impl true
  def init(:ok), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:quarantine, node_id}, _from, quarantined_nodes) do
    {:reply, :ok, MapSet.put(quarantined_nodes, node_id)}
  end

  def handle_call({:quarantined?, node_id}, _from, quarantined_nodes) do
    {:reply, MapSet.member?(quarantined_nodes, node_id), quarantined_nodes}
  end

  def handle_call(:quarantined_nodes, _from, quarantined_nodes) do
    {:reply, quarantined_nodes, quarantined_nodes}
  end
end
