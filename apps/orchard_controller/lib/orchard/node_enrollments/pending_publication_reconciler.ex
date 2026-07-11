defmodule Orchard.NodeEnrollments.PendingPublicationReconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias Orchard.NodeEnrollments

  @initial_delay_ms 5_000
  @interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      initial_delay_ms: Keyword.get(opts, :initial_delay_ms, @initial_delay_ms),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)
    }

    schedule_reconciliation(state.initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    schedule_reconciliation(state.interval_ms)
    {:noreply, state}
  end

  defp reconcile do
    case NodeEnrollments.reconcile_stale_pending_publications() do
      {:ok, %{reconciled: count}} when count > 0 ->
        Logger.info("Reconciled #{count} stale pending Node Enrollment publications")

      {:ok, %{reconciled: 0}} ->
        :ok

      {:error, reason} when reason in [:controller_standby, :controller_leadership_unproven] ->
        :ok

      {:error, _reason} ->
        Logger.warning("Pending Node Enrollment publication reconciliation unavailable")
    end
  rescue
    _error -> Logger.warning("Pending Node Enrollment publication reconciliation failed")
  catch
    _kind, _reason -> Logger.warning("Pending Node Enrollment publication reconciliation failed")
  end

  defp schedule_reconciliation(delay_ms) do
    Process.send_after(self(), :reconcile, delay_ms)
  end
end
