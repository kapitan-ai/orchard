defmodule Orchard.ControllerInstances.MembershipOwner do
  @moduledoc """
  Owns the local Controller membership heartbeat and capability evidence.
  """

  use GenServer

  require Logger

  alias Orchard.ControllerInstances

  @heartbeat_interval_ms 10_000
  @dispatch_capacity_contract_version 1
  @dispatch_capacity_consumers_ready false

  @type state :: %{
          opts: keyword(),
          timer_ref: term(),
          last_failure: term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the fixed Controller membership heartbeat interval.
  """
  @spec heartbeat_interval_ms() :: 10_000
  def heartbeat_interval_ms, do: @heartbeat_interval_ms

  @impl true
  def init(opts) do
    send(self(), :heartbeat)
    {:ok, %{opts: opts, timer_ref: start_timer(), last_failure: nil}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    case attempt_publish(state.opts) do
      {:ok, _instance} ->
        {:noreply, %{state | last_failure: nil}}

      {:error, reason} ->
        log_failure(reason, state.last_failure)
        {:noreply, %{state | last_failure: reason}}
    end
  end

  defp log_failure(reason, reason), do: :ok

  defp log_failure(reason, _previous) do
    Logger.warning(
      "Controller membership heartbeat failed; capability evidence remains stale " <>
        "(reason=#{inspect(reason)})"
    )
  end

  defp attempt_publish(opts) do
    publish(opts)
  rescue
    exception in [
      ArgumentError,
      DBConnection.ConnectionError,
      Ecto.QueryError,
      Ecto.StaleEntryError,
      File.Error,
      Postgrex.Error,
      RuntimeError
    ] ->
      {:error, {:heartbeat_publish_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:heartbeat_publish_exit, reason}}
  end

  defp publish(opts) do
    observed_at = now(opts)

    publisher(opts).(opts, %{
      last_seen_at: observed_at,
      software_version: software_version(),
      dispatch_capacity_contract_version: @dispatch_capacity_contract_version,
      dispatch_capacity_consumers_ready: @dispatch_capacity_consumers_ready,
      dispatch_capacity_capability_observed_at: observed_at
    })
  end

  defp start_timer do
    {:ok, timer_ref} = :timer.send_interval(@heartbeat_interval_ms, :heartbeat)
    timer_ref
  end

  defp now(opts) do
    opts
    |> Keyword.get(:clock, &DateTime.utc_now/0)
    |> then(fn clock -> clock.() end)
  end

  defp software_version do
    :orchard_controller
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp publisher(opts) do
    Keyword.get(opts, :publisher, &ControllerInstances.heartbeat_local/2)
  end
end
