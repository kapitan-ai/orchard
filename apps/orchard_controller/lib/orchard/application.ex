defmodule Orchard.Application do
  @moduledoc false

  use Application

  require Logger

  alias Orchard.API.Endpoint

  alias Orchard.BeamPeerGrants.{
    ControllerInitializer,
    ControllerStartupVerifier,
    ControlListener
  }

  alias Orchard.ControllerInstances.MembershipOwner
  alias Orchard.Licensing
  alias Orchard.RuntimeEndpoint.DistributionExpiryGuard
  alias Orchard.SentryContext

  @impl true
  def start(_type, _args) do
    with :ok <- validate_peer_grant_mode(Node.self()) do
      start_supervisor()
    end
  end

  @doc """
  Verifies that the grant-control phase has no BEAM Distribution identity.
  """
  @spec validate_peer_grant_mode(node()) :: :ok | {:error, atom()}
  def validate_peer_grant_mode(current_node) do
    if peer_grant_control_mode?() and current_node != :nonode@nohost do
      {:error, :beam_grant_control_requires_nondistributed_vm}
    else
      :ok
    end
  end

  defp start_supervisor do
    case Orchard.SentryLogger.install_handler() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Sentry handler install failed, continuing without: #{inspect(reason)}")
    end

    warn_if_sentry_live_view_hook_unavailable()
    attach_startup_license_context()

    Supervisor.start_link(child_specs(),
      strategy: :one_for_one,
      name: Orchard.Supervisor
    )
  end

  @doc """
  Returns the configured Controller supervision children in startup order.
  """
  @spec child_specs() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs do
    [{Task.Supervisor, name: Orchard.API.HealthTaskSupervisor}]
    |> maybe_add_repo()
    |> maybe_add_peer_grant_stack()
    |> maybe_add_membership_owner()
    |> maybe_add_activation_probe()
    |> maybe_add_inference_stack()
    |> maybe_add_metrics()
    |> add_pubsub_and_coordinator()
    |> maybe_add_endpoint()
  end

  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  defp warn_if_sentry_live_view_hook_unavailable do
    if OrchardConsole.sentry_live_view_hook_available?() do
      :ok
    else
      Logger.warning(
        "Sentry.LiveViewHook is unavailable; Console mounts without Sentry LiveView context. " <>
          "If this is unexpected, recompile LiveView then Sentry " <>
          "(`mix deps.compile phoenix_live_view` and `mix deps.compile sentry --force`) " <>
          "and restart the controller. See issue #191."
      )
    end
  end

  defp attach_startup_license_context do
    status = inspect_startup_license()

    Logger.info(
      "Controller startup license status",
      license_metadata(status, app: :orchard_controller)
    )

    SentryContext.cache_license_status(status)
    SentryContext.apply_license_status(status, :controller)
  end

  defp inspect_startup_license do
    licensing_impl().inspect_local()
  rescue
    _exception -> missing_license_status()
  catch
    _kind, _reason -> missing_license_status()
  end

  defp licensing_impl do
    Application.get_env(:orchard_shared, :licensing, [])[:licensing_impl] || Licensing
  end

  defp missing_license_status do
    %Licensing{
      state: :missing_bundle,
      message: "license inspection failed during controller startup",
      bundle_path: ""
    }
  end

  defp license_metadata(status, extra) do
    status
    |> SentryContext.build_license_extra()
    |> Map.drop([:orchard_licensee])
    |> Map.to_list()
    |> Keyword.merge(extra)
  end

  defp maybe_add_repo(children) do
    if Application.get_env(:orchard_controller, :start_repo, true) do
      children ++
        [
          Orchard.Repo,
          Orchard.NodeEnrollments.PendingPublicationReconciler
        ]
    else
      children
    end
  end

  defp maybe_add_inference_stack(children) do
    if peer_grant_control_mode?() do
      children
    else
      children ++
        [
          {GRPC.Client.Supervisor, []},
          Orchard.Tokenizer.CompatibilityCache,
          Orchard.Tokenizer.TelemetryCounters,
          Orchard.DispatchCapacity.QuarantineStore,
          Orchard.Inference
        ]
    end
  end

  defp maybe_add_peer_grant_stack(children) do
    config = Application.get_env(:orchard_controller, :beam_peer_grants, [])

    if Keyword.get(config, :enabled, false) do
      listener_opts = Keyword.get(config, :control_listener, [])

      children
      |> Kernel.++([{ControllerInitializer, membership_identity_opts()}])
      |> maybe_add_controller_startup_verifier(config)
      |> maybe_add_controller_expiry_guard(config)
      |> Kernel.++([{ControlListener, listener_opts}])
    else
      children
    end
  end

  defp maybe_add_membership_owner(children) do
    if Application.get_env(:orchard_controller, :start_repo, true) do
      children ++ [{MembershipOwner, membership_identity_opts()}]
    else
      children
    end
  end

  defp membership_identity_opts do
    membership = Application.get_env(:orchard_controller, :controller_membership, [])
    trust = Application.get_env(:orchard_controller, :node_trust, [])

    [
      private_ipv4: Keyword.get(membership, :private_ipv4),
      membership_scope: Keyword.get(membership, :scope),
      node_trust_root: Keyword.get(trust, :root),
      authorization_root_path: Keyword.get(membership, :authorization_root_path)
    ]
  end

  defp maybe_add_controller_startup_verifier(children, config) do
    if Keyword.get(config, :mode, :distributed) == :distributed do
      verifier = Keyword.get(config, :startup_verifier, ControllerStartupVerifier)

      verifier_opts =
        config
        |> Keyword.delete(:enabled)
        |> Keyword.delete(:mode)
        |> Keyword.delete(:control_listener)
        |> Keyword.delete(:expiry_guard)
        |> Keyword.delete(:startup_verifier)

      children ++ [{verifier, verifier_opts}]
    else
      children
    end
  end

  defp maybe_add_controller_expiry_guard(children, config) do
    if Keyword.get(config, :mode, :distributed) == :distributed do
      expiry_guard = Keyword.get(config, :expiry_guard, DistributionExpiryGuard)
      children ++ [{expiry_guard, Keyword.take(config, [:manifest_path])}]
    else
      children
    end
  end

  defp maybe_add_activation_probe(children) do
    if Application.get_env(:orchard_controller, :start_repo, true) and
         not peer_grant_control_mode?() do
      children ++ [Orchard.RuntimeEndpoint.ActivationProbe]
    else
      children
    end
  end

  defp peer_grant_control_mode? do
    config = Application.get_env(:orchard_controller, :beam_peer_grants, [])
    Keyword.get(config, :enabled, false) and Keyword.get(config, :mode) == :grant_control
  end

  defp maybe_add_metrics(children) do
    if Application.get_env(:orchard_controller, :start_metrics, true) and
         not peer_grant_control_mode?() do
      children ++ [{Orchard.Metrics.Bootstrap, metrics_options()}]
    else
      children
    end
  end

  defp metrics_options do
    Application.get_env(:orchard_controller, :metrics, [])
  end

  defp add_pubsub_and_coordinator(children) do
    children ++
      [
        {Phoenix.PubSub, name: Orchard.PubSub},
        OrchardConsole.ModelHubDownloadCoordinator
      ]
  end

  defp maybe_add_endpoint(children) do
    if Application.get_env(:orchard_controller, :start_endpoint, true) do
      children ++ [Endpoint]
    else
      children
    end
  end
end
