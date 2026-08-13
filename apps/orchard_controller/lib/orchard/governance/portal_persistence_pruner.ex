defmodule Orchard.Governance.PortalPersistencePruner do
  @moduledoc """
  Best-effort hourly cleanup of expired portal sessions and stale throttle rows.
  """

  use GenServer

  alias Orchard.Governance

  @interval_ms 3_600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    _ = Governance.prune_portal_persistence()
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :prune, interval_ms())
  end

  defp interval_ms do
    Application.get_env(:orchard_controller, :portal, [])
    |> Keyword.get(:prune_interval_ms, @interval_ms)
  end
end
