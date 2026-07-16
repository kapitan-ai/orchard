defmodule Orchard.ControllerInstances.MembershipOwner do
  @moduledoc """
  Owns the local Controller membership heartbeat and capability evidence.

  The first complete membership and capability tuple is published synchronously
  during `init/1`, so identity, custody, schema, or configuration failures stop
  Controller startup instead of leaving a live Controller whose dispatch-capacity
  cutover evidence never appears. Later heartbeat failures are transient and
  retry on the fixed interval with bounded logging.
  """

  use GenServer

  require Logger

  alias Orchard.ControllerInstances

  @heartbeat_interval_ms 10_000
  @failure_log_interval_ms 300_000
  @dispatch_capacity_contract_version 1
  @dispatch_capacity_consumers_ready false

  @type failure :: %{reason: atom(), logged_at: DateTime.t(), suppressed: non_neg_integer()}

  @type state :: %{
          opts: keyword(),
          timer_ref: term(),
          failure: failure() | nil
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
    case attempt_publish(opts, now(opts)) do
      {:ok, _instance} -> {:ok, %{opts: opts, timer_ref: start_timer(), failure: nil}}
      {:error, reason} -> {:stop, sanitize_reason(reason)}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    observed_at = now(state.opts)

    case attempt_publish(state.opts, observed_at) do
      {:ok, _instance} ->
        log_recovery(state.failure)
        {:noreply, %{state | failure: nil}}

      {:error, reason} ->
        {:noreply, %{state | failure: record_failure(state.failure, reason, observed_at)}}
    end
  end

  defp record_failure(nil, reason, observed_at) do
    log_failure(sanitize_reason(reason), 0, observed_at)
  end

  defp record_failure(%{reason: previous} = failure, reason, observed_at) do
    sanitized = sanitize_reason(reason)

    cond do
      sanitized != previous ->
        log_failure(sanitized, 0, observed_at)

      DateTime.diff(observed_at, failure.logged_at, :millisecond) >= @failure_log_interval_ms ->
        log_failure(sanitized, failure.suppressed, observed_at)

      true ->
        %{failure | suppressed: failure.suppressed + 1}
    end
  end

  defp log_failure(reason, suppressed, observed_at) do
    Logger.warning(
      "Controller membership heartbeat failed; capability evidence remains stale " <>
        "(reason=#{reason} suppressed_attempts=#{suppressed})"
    )

    %{reason: reason, logged_at: observed_at, suppressed: 0}
  end

  defp log_recovery(nil), do: :ok

  defp log_recovery(%{reason: reason}) do
    Logger.info(
      "Controller membership heartbeat recovered; capability evidence is fresh " <>
        "(previous_reason=#{reason})"
    )
  end

  defp sanitize_reason(%Ecto.Changeset{}), do: :beam_controller_instance_heartbeat_invalid
  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason({tag, _detail}) when is_atom(tag), do: tag
  defp sanitize_reason(_reason), do: :beam_controller_membership_heartbeat_failed

  defp attempt_publish(opts, observed_at) do
    publish(opts, observed_at)
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

  defp publish(opts, observed_at) do
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
