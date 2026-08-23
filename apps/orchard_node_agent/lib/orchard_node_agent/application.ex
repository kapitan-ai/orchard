defmodule Orchard.NodeAgent.Application do
  @moduledoc false

  use Application

  alias Orchard.Node.{
    BeamPeerGrantBootstrap,
    BeamPeerGrantStartupVerifier,
    Identity,
    SentryTelemetryBridge
  }

  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.RuntimeEndpoint.DistributionExpiryGuard

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

    start_result =
      Supervisor.start_link(child_specs(),
        strategy: :one_for_one,
        name: Orchard.NodeAgent.Supervisor
      )

    case start_result do
      {:ok, _pid} -> attach_sentry_telemetry_bridge()
      _other -> :ok
    end

    start_result
  end

  @doc """
  Returns the configured Node Agent supervision children in startup order.
  """
  @spec child_specs() :: [module() | {module(), term()}]
  def child_specs do
    config = Application.get_env(:orchard_node_agent, :beam_peer_grants, [])

    if Keyword.get(config, :enabled, false) do
      shared_opts =
        config
        |> Keyword.delete(:enabled)
        |> Keyword.delete(:expiry_guard)
        |> Keyword.delete(:startup_verifier)
        |> Keyword.put_new(:identity_root, Orchard.Node.node_identity_root())

      verifier = Keyword.get(config, :startup_verifier, BeamPeerGrantStartupVerifier)
      expiry_guard = Keyword.get(config, :expiry_guard, DistributionExpiryGuard)
      expiry_opts = Keyword.take(config, [:manifest_path])

      bootstrap_opts =
        shared_opts
        |> Keyword.delete(:manifest_path)
        |> Keyword.delete(:static_targets)
        |> Keyword.delete(:cookie_file)
        |> Keyword.put(:retrieval, :forbid)

      [
        {verifier, shared_opts},
        {expiry_guard, expiry_opts},
        {BeamPeerGrantBootstrap, bootstrap_opts},
        NodeSupervisor
      ]
    else
      [NodeSupervisor]
    end
  end

  defp attach_sentry_telemetry_bridge do
    SentryTelemetryBridge.attach()
  end

  @impl true
  def stop(_state) do
    SentryTelemetryBridge.detach()
    :ok
  end
end
