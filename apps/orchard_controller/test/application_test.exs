defmodule OrchardApplicationTest do
  use ExUnit.Case, async: false

  @sentry_dsn "https://public@example.invalid/1"

  setup do
    previous_env = %{
      start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      enable_db_checks: Application.get_env(:orchard_controller, :enable_db_checks, true),
      beam_peer_grants: Application.get_env(:orchard_controller, :beam_peer_grants),
      controller_membership: Application.get_env(:orchard_controller, :controller_membership),
      sentry_dsn: Application.get_env(:sentry, :dsn)
    }

    was_started = is_pid(Process.whereis(Orchard.Supervisor))

    stop_controller_app()
    remove_sentry_handler()

    Application.put_env(:orchard_controller, :start_repo, false)
    Application.put_env(:orchard_controller, :start_endpoint, false)
    Application.put_env(:orchard_controller, :enable_db_checks, false)
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: false)

    on_exit(fn ->
      stop_controller_app()

      Application.put_env(:orchard_controller, :start_repo, previous_env.start_repo)
      Application.put_env(:orchard_controller, :start_endpoint, previous_env.start_endpoint)
      Application.put_env(:orchard_controller, :enable_db_checks, previous_env.enable_db_checks)
      restore_app_env(:orchard_controller, :beam_peer_grants, previous_env.beam_peer_grants)

      restore_app_env(
        :orchard_controller,
        :controller_membership,
        previous_env.controller_membership
      )

      Application.put_env(:sentry, :dsn, previous_env.sentry_dsn)
      remove_sentry_handler()

      if was_started do
        {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
      end
    end)

    :ok
  end

  test "controller application boots with inference supervision but without repo or endpoint children" do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    supervisor = Process.whereis(Orchard.Supervisor)
    assert is_pid(supervisor)

    child_ids =
      Supervisor.which_children(supervisor)
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert Orchard.Inference in child_ids
    assert Phoenix.PubSub.Supervisor in child_ids
    assert OrchardConsole.ModelHubDownloadCoordinator in child_ids
    refute Orchard.Repo in child_ids
    refute Orchard.API.Endpoint in child_ids

    assert is_pid(Process.whereis(Orchard.Inference))
    assert is_pid(Process.whereis(Orchard.Requests.Supervisor))
    assert is_pid(Process.whereis(OrchardConsole.ModelHubDownloadCoordinator))
  end

  test "SPEC.md §7.5.0 production grants add the configured control listener child" do
    listener = [host: "10.0.0.10", port: 50_072]

    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      mode: :distributed,
      manifest_path: "/protected/controller-launch.json",
      control_listener: listener
    )

    child_specs = Orchard.Application.child_specs()

    assert {Orchard.BeamPeerGrants.ControllerInitializer, initializer} =
             Enum.find(
               child_specs,
               &match?({Orchard.BeamPeerGrants.ControllerInitializer, _}, &1)
             )

    assert initializer[:private_ipv4] == listener[:host]

    assert {Orchard.BeamPeerGrants.ControllerStartupVerifier, verifier} =
             Enum.find(
               child_specs,
               &match?({Orchard.BeamPeerGrants.ControllerStartupVerifier, _}, &1)
             )

    assert verifier[:manifest_path] == "/protected/controller-launch.json"

    assert {Orchard.RuntimeEndpoint.DistributionExpiryGuard, expiry_guard} =
             Enum.find(
               child_specs,
               &match?({Orchard.RuntimeEndpoint.DistributionExpiryGuard, _}, &1)
             )

    assert expiry_guard == [manifest_path: "/protected/controller-launch.json"]
    assert {Orchard.BeamPeerGrants.ControlListener, listener} in child_specs

    assert Enum.find_index(
             child_specs,
             &match?({Orchard.BeamPeerGrants.ControllerInitializer, _}, &1)
           ) <
             Enum.find_index(
               child_specs,
               &match?({Orchard.BeamPeerGrants.ControllerStartupVerifier, _}, &1)
             )

    assert Enum.find_index(
             child_specs,
             &match?({Orchard.BeamPeerGrants.ControllerStartupVerifier, _}, &1)
           ) <
             Enum.find_index(
               child_specs,
               &match?({Orchard.RuntimeEndpoint.DistributionExpiryGuard, _}, &1)
             )

    assert Enum.find_index(
             child_specs,
             &match?({Orchard.RuntimeEndpoint.DistributionExpiryGuard, _}, &1)
           ) <
             Enum.find_index(
               child_specs,
               &match?({Orchard.BeamPeerGrants.ControlListener, _}, &1)
             )

    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: false)

    refute Enum.any?(Orchard.Application.child_specs(), fn
             {Orchard.BeamPeerGrants.ControllerInitializer, _opts} -> true
             {Orchard.BeamPeerGrants.ControlListener, _opts} -> true
             _other -> false
           end)
  end

  test "SPEC.md §8.3 exactly one membership owner is supervised whenever the repo is owned" do
    listener = [host: "10.0.0.10", port: 50_072]

    for peer_grants <- [
          [enabled: false],
          [
            enabled: true,
            mode: :distributed,
            authorization_root_path: "/protected/authorization-root",
            manifest_path: "/protected/controller-launch.json",
            control_listener: listener
          ]
        ] do
      Application.put_env(:orchard_controller, :beam_peer_grants, peer_grants)
      Application.put_env(:orchard_controller, :start_repo, true)

      assert [{Orchard.ControllerInstances.MembershipOwner, _opts}] =
               membership_owner_specs(Orchard.Application.child_specs())
    end
  end

  test "SPEC.md §8.3 membership identity never follows the peer-grant control listener" do
    Application.put_env(:orchard_controller, :start_repo, true)

    Application.put_env(:orchard_controller, :controller_membership,
      private_ipv4: "10.0.0.10",
      scope: :remote_beam,
      authorization_root_path: "/protected/authorization-root"
    )

    assert [{Orchard.ControllerInstances.MembershipOwner, disabled_opts}] =
             membership_owner_specs(Orchard.Application.child_specs())

    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      mode: :distributed,
      authorization_root_path: "/grant/authorization-root",
      manifest_path: "/protected/controller-launch.json",
      control_listener: [host: "10.0.0.99", port: 50_072]
    )

    assert [{Orchard.ControllerInstances.MembershipOwner, enabled_opts}] =
             membership_owner_specs(Orchard.Application.child_specs())

    assert enabled_opts == disabled_opts
    assert enabled_opts[:private_ipv4] == "10.0.0.10"
    assert enabled_opts[:membership_scope] == :remote_beam
    assert enabled_opts[:authorization_root_path] == "/protected/authorization-root"
  end

  test "SPEC.md §8.3 membership identity defaults to a local-only loopback host" do
    Application.put_env(:orchard_controller, :start_repo, true)
    Application.delete_env(:orchard_controller, :controller_membership)

    assert [{Orchard.ControllerInstances.MembershipOwner, opts}] =
             membership_owner_specs(Orchard.Application.child_specs())

    assert opts[:private_ipv4] == "127.0.0.1"
    assert opts[:membership_scope] == :local_only
  end

  test "SPEC.md §8.3 membership owner is omitted only when repo ownership is disabled" do
    Application.put_env(:orchard_controller, :start_repo, false)

    assert membership_owner_specs(Orchard.Application.child_specs()) == []
  end

  test "SPEC.md §7.5.0 controller startup fails closed when its grant listener is invalid" do
    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      control_listener: [host: "127.0.0.1", port: 50_072]
    )

    assert {:error, {:orchard_controller, _reason}} =
             Application.ensure_all_started(:orchard_controller)

    refute is_pid(Process.whereis(Orchard.Supervisor))
  end

  test "SPEC.md §7.5.0 grant-control mode is non-distributed and starts no runtime dispatch" do
    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      mode: :grant_control,
      control_listener: [host: "10.0.0.10", port: 50_072]
    )

    assert :ok = Orchard.Application.validate_peer_grant_mode(:nonode@nohost)

    assert {:error, :beam_grant_control_requires_nondistributed_vm} =
             Orchard.Application.validate_peer_grant_mode(:orchard_controller@localhost)

    children = Orchard.Application.child_specs()
    refute Orchard.Inference in children
    refute Orchard.RuntimeEndpoint.ActivationProbe in children

    refute Enum.any?(children, fn
             {Orchard.BeamPeerGrants.ControllerStartupVerifier, _opts} -> true
             _other -> false
           end)
  end

  test "test environment uses deterministic endpoint config defaults" do
    endpoint_config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    # Loopback HTTP only in test
    assert endpoint_config[:http] == [ip: {127, 0, 0, 1}, port: 4002]
    assert endpoint_config[:https] == nil

    # CORS explicitly empty
    assert endpoint_config[:cors_origins] == []

    # Loopback HTTP is the degraded local/default transport.
    assert Application.get_env(:orchard_controller, :transport_mode) == :plain_http_localhost
    assert Application.get_env(:orchard_controller, :transport_cert_source) == :unknown
    assert Application.get_env(:orchard_controller, :transport_degraded, false) == true
  end

  test "test environment has deterministic console config defaults" do
    console = Application.fetch_env!(:orchard_controller, :console)

    assert console[:enabled] == true
    assert console[:auth] == :none
    assert console[:username] == nil
    assert console[:password] == nil
    assert console[:model_hub_impl] == OrchardConsole.ModelHub
    assert console[:model_hub_client_impl] == Orchard.Models.HubClient
    assert console[:download_coordinator_impl] == OrchardConsole.ModelHubDownloadCoordinator
  end

  test "test environment has deterministic hugging face config defaults" do
    hf = Application.fetch_env!(:orchard_controller, :hf)

    assert hf[:base_url] == "https://huggingface.co"
    assert hf[:api_base_url] == "https://huggingface.co/api"
    assert hf[:token] == nil
    assert hf[:retry_attempts] == 3
    assert hf[:connect_timeout_ms] == 10_000
    assert hf[:receive_timeout_ms] == 30_000
    assert hf[:req_options] == []
  end

  test "test environment config uses fake tokenizer and local runtime target" do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    assert inference[:tokenizer_mode] == :fake
    assert inference[:request_timeout_ms] == 5_000
    assert inference[:runtime_client_target] == test_runtime_client_target()
    assert Path.type(inference[:artifacts_root]) == :absolute
    assert String.ends_with?(inference[:artifacts_root], "/tmp/test/bundles")

    assert String.ends_with?(
             inference[:tokenizer_executable],
             "/native/orchard_tokenizer/bin/orchard-tokenizer"
           )
  end

  test "no DSN leaves Sentry logger handler uninstalled" do
    Application.put_env(:sentry, :dsn, nil)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    assert :logger.get_handler_config(Sentry.LoggerHandler) in [
             {:error, :not_found},
             {:error, {:not_found, Sentry.LoggerHandler}}
           ]
  end

  test "DSN installs Sentry logger handler with expected metadata whitelist" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    assert {:ok, %{config: config}} = :logger.get_handler_config(Sentry.LoggerHandler)
    assert config.capture_log_messages == false
    assert config.metadata == [:request_id, :worker_model, :orchard_node_id, :model_backend]
    assert config.rate_limiting == [max_events: 50, interval: 60_000]
  end

  test "test environment aligns shared licensing paths with tmp/test" do
    licensing = Application.fetch_env!(:orchard_shared, :licensing)

    assert Path.type(licensing[:bundle_path]) == :absolute
    assert Path.type(licensing[:node_identity_path]) == :absolute
    assert String.ends_with?(licensing[:bundle_path], "/tmp/test/config/licensing/current.json")
    assert String.ends_with?(licensing[:node_identity_path], "/tmp/test/data/node-id")
  end

  defp membership_owner_specs(child_specs) do
    Enum.filter(child_specs, &match?({Orchard.ControllerInstances.MembershipOwner, _opts}, &1))
  end

  defp remove_sentry_handler do
    case :logger.remove_handler(Sentry.LoggerHandler) do
      :ok -> remove_sentry_handler()
      {:error, :not_found} -> :ok
      {:error, {:not_found, Sentry.LoggerHandler}} -> :ok
    end
  end

  defp stop_controller_app do
    case Application.stop(:orchard_controller) do
      :ok -> :ok
      {:error, {:not_started, :orchard_controller}} -> :ok
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp test_runtime_client_target do
    [host: "127.0.0.1", port: test_node_agent_port()]
  end

  defp test_node_agent_port do
    System.get_env("ORCHARD_TEST_NODE_AGENT_PORT", "50071")
    |> String.to_integer()
  end
end
