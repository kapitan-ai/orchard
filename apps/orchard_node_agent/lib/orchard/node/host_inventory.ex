defmodule Orchard.Node.HostInventory do
  @moduledoc """
  Refreshes and retains the latest observation-only host inventory snapshot.

  Refresh failure is represented inside the typed snapshot and never changes
  runtime readiness or creates scheduling authority.
  """

  use GenServer

  alias Orchard.Cluster.V1.HostInventoryObservation
  alias Orchard.Node.LinuxHostInventory

  @default_refresh_ms 60_000
  @default_collection_timeout_ms 15_000

  @type state :: %{
          observation: HostInventoryObservation.t() | nil,
          provider: module() | nil,
          provider_opts: keyword(),
          refresh_ms: pos_integer(),
          collection_timeout_ms: pos_integer(),
          collection:
            nil
            | %{
                pid: pid(),
                collection_ref: reference(),
                timeout_ref: reference()
              }
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec current(GenServer.server()) :: HostInventoryObservation.t() | nil
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, _reason -> nil
  end

  @spec refresh(GenServer.server()) :: HostInventoryObservation.t() | nil
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    provider = Keyword.get_lazy(opts, :provider, &default_provider/0)
    provider_opts = Keyword.get(opts, :provider_opts, [])
    refresh_ms = Keyword.get(opts, :refresh_ms, configured_refresh_ms())

    collection_timeout_ms =
      Keyword.get(opts, :collection_timeout_ms, @default_collection_timeout_ms)

    {:ok,
     %{
       observation: nil,
       provider: provider,
       provider_opts: provider_opts,
       refresh_ms: refresh_ms,
       collection_timeout_ms: collection_timeout_ms,
       collection: nil
     }, {:continue, :collect}}
  end

  @impl true
  def handle_continue(:collect, state), do: {:noreply, start_collection(state)}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.observation, state}

  def handle_call(:refresh, _from, state) do
    state = start_collection(state)
    {:reply, state.observation, state}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, start_collection(state)}

  def handle_info({:collection_complete, collection_ref, observation}, state) do
    case state.collection do
      %{
        collection_ref: ^collection_ref,
        pid: pid,
        timeout_ref: timeout_ref
      } ->
        Process.cancel_timer(timeout_ref)
        Process.unlink(pid)
        schedule_refresh(state.refresh_ms)
        {:noreply, %{state | observation: observation, collection: nil}}

      _collection ->
        {:noreply, state}
    end
  end

  def handle_info({:collection_timeout, collection_ref}, state) do
    case state.collection do
      %{pid: pid, collection_ref: ^collection_ref} ->
        Process.exit(pid, :kill)
        schedule_refresh(state.refresh_ms)

        observation =
          LinuxHostInventory.error_observation(
            System.system_time(:millisecond),
            "provider_timeout"
          )

        {:noreply, %{state | observation: observation, collection: nil}}

      _collection ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    case state.collection do
      %{pid: ^pid, timeout_ref: timeout_ref} ->
        Process.cancel_timer(timeout_ref)
        schedule_refresh(state.refresh_ms)
        {:noreply, %{state | observation: error_observation(), collection: nil}}

      _collection ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{collection: %{pid: pid}}) do
    Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_collection(%{provider: nil} = state), do: state
  defp start_collection(%{collection: collection} = state) when not is_nil(collection), do: state

  defp start_collection(state) do
    parent = self()
    collection_ref = make_ref()

    pid =
      spawn_link(fn ->
        observation = observe(state.provider, state.provider_opts)
        send(parent, {:collection_complete, collection_ref, observation})
      end)

    timeout_ref =
      Process.send_after(
        self(),
        {:collection_timeout, collection_ref},
        state.collection_timeout_ms
      )

    collection = %{
      pid: pid,
      collection_ref: collection_ref,
      timeout_ref: timeout_ref
    }

    %{state | collection: collection}
  end

  defp observe(provider, opts) do
    provider.observe(opts)
  rescue
    _error -> error_observation()
  catch
    _kind, _reason -> error_observation()
  end

  defp error_observation do
    LinuxHostInventory.error_observation(
      System.system_time(:millisecond),
      "provider_failed"
    )
  end

  defp configured_refresh_ms do
    configured =
      Application.get_env(:orchard_node_agent, :host_inventory_refresh_ms, @default_refresh_ms)

    case configured do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_refresh_ms
    end
  end

  defp default_provider do
    if :os.type() == {:unix, :linux}, do: LinuxHostInventory
  end

  defp schedule_refresh(refresh_ms), do: Process.send_after(self(), :refresh, refresh_ms)
end
