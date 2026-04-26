defmodule Orchard.NodeAgent.Application do
  @moduledoc false

  use Application

  alias Orchard.Node.{Identity, LicenseEnforcer, SentryTelemetryBridge}
  alias Orchard.Node.Supervisor, as: NodeSupervisor

  @impl true
  def start(_type, _args) do
    case Orchard.SentryLogger.install_handler() do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Sentry handler install failed, continuing without: #{inspect(reason)}")
    end

    # Resolve and persist node identity before starting the supervision tree.
    # This ensures GetStatus can report stable metadata from first request.
    Identity.ensure_identity!()
    LicenseEnforcer.enforce_startup!()

    start_result =
      Supervisor.start_link(
        [NodeSupervisor],
        strategy: :one_for_one,
        name: Orchard.NodeAgent.Supervisor
      )

    case start_result do
      {:ok, _pid} -> attach_sentry_telemetry_bridge()
      _other -> :ok
    end

    start_result
  end

  defp attach_sentry_telemetry_bridge do
    case SentryTelemetryBridge.attach() do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Sentry telemetry bridge attach failed, continuing without: #{inspect(reason)}"
        )
    end
  end

  @impl true
  def stop(_state) do
    SentryTelemetryBridge.detach()
    :ok
  end
end
