defmodule OrchardApplicationTest.FailingMetricsReporter do
  @moduledoc false

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts), do: {:error, :forced_metrics_start_failure}
end

defmodule OrchardApplicationTest.RaisingMetricsReporter do
  @moduledoc false

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts), do: raise("forced metrics reporter raise")
end

defmodule OrchardApplicationTest.ExitingMetricsReporter do
  @moduledoc false

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts), do: exit(:forced_metrics_reporter_exit)
end

defmodule OrchardApplicationTest.FlakyMetricsReporter do
  @moduledoc false

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts) do
    if :persistent_term.get({__MODULE__, :fail?}, false) do
      :persistent_term.put({__MODULE__, :fail?}, false)
      {:error, :forced_first_metrics_start_failure}
    else
      Agent.start_link(fn -> :ok end, name: Orchard.Metrics.Reporter)
    end
  end
end

defmodule OrchardApplicationTest do
  use ExUnit.Case, async: false

  alias Orchard.DispatchCapacity.{
    AllocationAuthority,
    ConformanceFixture,
    QuarantineStore,
    Readiness
  }

  alias Orchard.Inference.QueueManager
  alias Orchard.Metrics.CardinalityLedger

  @sentry_dsn "https://public@example.invalid/1"

  setup do
    previous_env = %{
      start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      enable_db_checks: Application.get_env(:orchard_controller, :enable_db_checks, true),
      beam_peer_grants: Application.get_env(:orchard_controller, :beam_peer_grants),
      controller_membership: Application.get_env(:orchard_controller, :controller_membership),
      start_metrics: Application.get_env(:orchard_controller, :start_metrics),
      metrics: Application.get_env(:orchard_controller, :metrics),
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

      restore_app_env(:orchard_controller, :start_metrics, previous_env.start_metrics)
      restore_app_env(:orchard_controller, :metrics, previous_env.metrics)

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
    assert QuarantineStore in child_ids
    assert Phoenix.PubSub.Supervisor in child_ids
    assert OrchardConsole.ModelHubDownloadCoordinator in child_ids
    refute Orchard.Repo in child_ids
    refute Orchard.API.Endpoint in child_ids

    assert is_pid(Process.whereis(Orchard.Inference))
    assert is_pid(Process.whereis(QuarantineStore))
    assert is_pid(Process.whereis(Orchard.Requests.Supervisor))
    assert is_pid(Process.whereis(OrchardConsole.ModelHubDownloadCoordinator))
  end

  test "SPEC.md §9.1 metrics startup failure does not prevent Controller boot" do
    Application.put_env(:orchard_controller, :start_metrics, true)

    Application.put_env(:orchard_controller, :metrics,
      reporter: OrchardApplicationTest.FailingMetricsReporter
    )

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
    assert is_pid(Process.whereis(Orchard.Supervisor))
    assert is_pid(Process.whereis(Orchard.Metrics.Bootstrap))
    refute_metrics_generation()
  end

  test "SPEC.md §9.1 metrics raises and exits cannot exhaust root Controller supervision" do
    Application.put_env(:orchard_controller, :start_metrics, true)

    for reporter <- [
          OrchardApplicationTest.RaisingMetricsReporter,
          OrchardApplicationTest.ExitingMetricsReporter
        ] do
      Application.put_env(:orchard_controller, :metrics, reporter: reporter)

      assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
      root = Process.whereis(Orchard.Supervisor)
      bootstrap = Process.whereis(Orchard.Metrics.Bootstrap)

      assert is_pid(root)
      assert is_pid(bootstrap)
      Process.sleep(20)
      assert Process.alive?(root)
      assert Process.alive?(bootstrap)
      refute_metrics_generation()

      :ok = Application.stop(:orchard_controller)
    end
  end

  test "SPEC.md §9.1 a stopped metrics generation is replaced by a new clean generation" do
    Application.put_env(:orchard_controller, :start_metrics, true)
    Application.put_env(:orchard_controller, :metrics, restart_delay_ms: 10)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    bootstrap = Process.whereis(Orchard.Metrics.Bootstrap)
    generation = metrics_generation()
    ledger = Process.whereis(CardinalityLedger)
    assert is_pid(generation)
    assert is_pid(ledger)

    :ok = Supervisor.stop(generation)

    assert is_pid(wait_for_replacement(Orchard.Metrics.Supervisor, generation))
    assert is_pid(wait_for_replacement(CardinalityLedger, ledger))
    assert Process.whereis(Orchard.Metrics.Bootstrap) == bootstrap
    assert CardinalityLedger.active_series() == 0
  end

  test "SPEC.md §9.1 a failed metrics generation start is retried without failing boot" do
    :persistent_term.put({OrchardApplicationTest.FlakyMetricsReporter, :fail?}, true)

    on_exit(fn ->
      :persistent_term.erase({OrchardApplicationTest.FlakyMetricsReporter, :fail?})
    end)

    Application.put_env(:orchard_controller, :start_metrics, true)

    Application.put_env(:orchard_controller, :metrics,
      reporter: OrchardApplicationTest.FlakyMetricsReporter,
      restart_delay_ms: 10
    )

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
    assert is_pid(Process.whereis(Orchard.Metrics.Bootstrap))
    assert is_pid(wait_for_replacement(&metrics_generation/0, nil))
    refute :persistent_term.get({OrchardApplicationTest.FlakyMetricsReporter, :fail?})
  end

  test "SPEC 4.8 readiness proof is independent of root quarantine startup order" do
    assert Process.whereis(QuarantineStore) == nil
    assert Readiness.ready?(required_contract_version: Readiness.contract_version())
  end

  test "SPEC 4.5 root-owned quarantine store loss leaves the live authority fail-closed" do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    supervisor = Process.whereis(Orchard.Supervisor)
    authority = Process.whereis(AllocationAuthority)
    store = Process.whereis(QuarantineStore)
    node_id = Ecto.UUID.generate()

    assert %{restart: :temporary} = QuarantineStore.child_spec([])

    store_ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^store_ref, :process, ^store, :killed}

    assert Process.whereis(QuarantineStore) == nil
    assert Process.whereis(AllocationAuthority) == authority
    assert Process.alive?(supervisor)

    assert {:error, :dispatch_capacity_unavailable, blocked} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-root-quarantine-store-loss",
               ConformanceFixture.input()
             )

    refute blocked.eligible?
    assert :node_health_unhealthy in blocked.reason_codes
  end

  test "SPEC 4.5 authority loss restarts every live capacity-dependent owner" do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    authority = Process.whereis(AllocationAuthority)
    requests_supervisor = Process.whereis(Orchard.Requests.Supervisor)
    queue_manager = Process.whereis(QueueManager)
    node_id = Ecto.UUID.generate()
    parent = self()

    assert :ok =
             QueueManager.refresh_capacity("controller-restart-model", "v1", 1,
               source: {:node, node_id}
             )

    assert node_source_limit_present?(node_id)

    owner_spec = %{
      id: make_ref(),
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             result =
               QueueManager.acquire_dispatch_capacity(
                 node_id,
                 "request-authority-loss",
                 ConformanceFixture.input()
               )

             send(parent, {:authority_loss_claimed, self(), result})
             Process.sleep(:infinity)
           end
         ]}
    }

    assert {:ok, owner} =
             DynamicSupervisor.start_child(Orchard.Requests.Supervisor, owner_spec)

    owner_ref = Process.monitor(owner)
    assert_receive {:authority_loss_claimed, ^owner, {:ok, _claim, _result}}

    Process.exit(authority, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 1_000

    replacement_authority =
      wait_for_replacement(AllocationAuthority, authority)

    replacement_requests = wait_for_replacement(Orchard.Requests.Supervisor, requests_supervisor)
    replacement_queue = wait_for_replacement(QueueManager, queue_manager)

    assert AllocationAuthority.claim_count(
             replacement_authority,
             node_id
           ) == 0

    assert {:ok, clean_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-authority-restart",
               ConformanceFixture.input()
             )

    assert :released =
             QueueManager.release_dispatch_capacity(clean_claim,
               authority: replacement_authority
             )

    assert is_pid(replacement_requests)
    assert is_pid(replacement_queue)
    assert QueueManager.active_capacity_source_lanes({:node, node_id}) == []
    refute node_source_limit_present?(node_id)
  end

  test "SPEC 4.5 queue loss preserves authority and live request ownership" do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    authority = Process.whereis(AllocationAuthority)
    requests_supervisor = Process.whereis(Orchard.Requests.Supervisor)
    queue_manager = Process.whereis(QueueManager)
    node_id = Ecto.UUID.generate()
    parent = self()

    assert :ok =
             QueueManager.refresh_capacity("queue-restart-model", "v1", 1,
               source: {:node, node_id}
             )

    assert node_source_limit_present?(node_id)

    owner_spec = %{
      id: make_ref(),
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             result =
               QueueManager.acquire_dispatch_capacity(
                 node_id,
                 "request-queue-loss",
                 ConformanceFixture.input()
               )

             send(parent, {:queue_loss_claimed, self(), result})

             receive do
               :stop -> :ok
             end
           end
         ]}
    }

    assert {:ok, owner} =
             DynamicSupervisor.start_child(Orchard.Requests.Supervisor, owner_spec)

    owner_ref = Process.monitor(owner)
    assert_receive {:queue_loss_claimed, ^owner, {:ok, _claim, _result}}

    Process.exit(queue_manager, :kill)

    replacement_queue = wait_for_replacement(QueueManager, queue_manager)

    assert Process.whereis(AllocationAuthority) == authority
    assert Process.whereis(Orchard.Requests.Supervisor) == requests_supervisor
    assert Process.alive?(owner)
    refute_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert is_pid(replacement_queue)
    assert QueueManager.active_capacity_source_lanes({:node, node_id}) == []
    refute node_source_limit_present?(node_id)

    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
  end

  test "SPEC.md §7.5.0 production grants add the configured control listener child" do
    listener = [host: "10.0.0.10", port: 50_072]

    Application.put_env(:orchard_controller, :controller_membership,
      private_ipv4: "10.0.0.20",
      scope: :remote_beam,
      authorization_root_path: "/protected/authorization-root"
    )

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

    assert initializer[:private_ipv4] == "10.0.0.20"

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

  test "SPEC.md §8.3 the grant initializer and membership owner share one durable identity" do
    Application.put_env(:orchard_controller, :start_repo, true)

    Application.put_env(:orchard_controller, :controller_membership,
      private_ipv4: "10.0.0.10",
      scope: :remote_beam,
      authorization_root_path: "/protected/authorization-root"
    )

    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      mode: :distributed,
      authorization_root_path: "/grant/authorization-root",
      manifest_path: "/protected/controller-launch.json",
      control_listener: [host: "10.0.0.99", port: 50_072]
    )

    child_specs = Orchard.Application.child_specs()

    assert {Orchard.BeamPeerGrants.ControllerInitializer, initializer_opts} =
             Enum.find(
               child_specs,
               &match?({Orchard.BeamPeerGrants.ControllerInitializer, _}, &1)
             )

    assert [{Orchard.ControllerInstances.MembershipOwner, membership_opts}] =
             membership_owner_specs(child_specs)

    assert initializer_opts == membership_opts
    assert initializer_opts[:private_ipv4] == "10.0.0.10"
    assert initializer_opts[:membership_scope] == :remote_beam
    assert initializer_opts[:authorization_root_path] == "/protected/authorization-root"
  end

  test "Source-dev membership owner receives the resolved address policy" do
    Application.put_env(:orchard_controller, :start_repo, true)
    policy = %{additional_cidrs: [{{203, 0, 113, 0}, 24}]}

    Application.put_env(:orchard_controller, :controller_membership,
      private_ipv4: "203.0.113.10",
      scope: :remote_beam,
      authorization_root_path: "/protected/authorization-root",
      source_dev_address_policy: policy
    )

    assert [{Orchard.ControllerInstances.MembershipOwner, opts}] =
             membership_owner_specs(Orchard.Application.child_specs())

    assert opts[:source_dev_address_policy] == policy
  end

  test "SPEC.md §8.3 membership identity is never defaulted when config resolved no scope" do
    Application.put_env(:orchard_controller, :start_repo, true)
    Application.delete_env(:orchard_controller, :controller_membership)

    assert [{Orchard.ControllerInstances.MembershipOwner, opts}] =
             membership_owner_specs(Orchard.Application.child_specs())

    assert opts[:private_ipv4] == nil
    assert opts[:membership_scope] == nil
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
    Application.put_env(:orchard_controller, :start_metrics, true)

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
             {Orchard.Metrics.Bootstrap, _opts} -> true
             _other -> false
           end)

    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: false)

    assert Enum.any?(Orchard.Application.child_specs(), fn
             {Orchard.Metrics.Bootstrap, _opts} -> true
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
    assert config.metadata == [:request_id, :worker_model, :model_backend]
    assert config.rate_limiting == [max_events: 50, interval: 60_000]
  end

  test "test environment does not configure product licensing" do
    assert Application.get_env(:orchard_shared, :licensing) == nil
  end

  defp refute_metrics_generation do
    assert metrics_generation() == nil
    assert Process.whereis(Orchard.Metrics.Supervisor) == nil
  end

  # The bootstrap starts a generation from `handle_continue/2`, so
  # `Orchard.Metrics.Supervisor` is registered for the whole start attempt —
  # including attempts that go on to fail — and that attempt can outlast the
  # rest of Controller boot. `:sys.get_state/1` is ordered behind the continue,
  # so it settles the attempt and reports the generation the bootstrap owns.
  defp metrics_generation do
    %{supervisor: supervisor} = :sys.get_state(Orchard.Metrics.Bootstrap)
    supervisor
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

  defp node_source_limit_present?(node_id) do
    QueueManager
    |> :sys.get_state()
    |> Map.fetch!(:capacity_source_limits)
    |> Map.has_key?({:node, node_id})
  end

  defp stop_controller_app do
    case Application.stop(:orchard_controller) do
      :ok -> :ok
      {:error, {:not_started, :orchard_controller}} -> :ok
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp wait_for_replacement(name, previous, attempts \\ 100)

  defp wait_for_replacement(_name, _previous, 0), do: flunk("supervised process was not replaced")

  defp wait_for_replacement(name, previous, attempts) do
    case resolve_process(name) do
      replacement when is_pid(replacement) and replacement != previous ->
        replacement

      _unavailable ->
        Process.sleep(10)
        wait_for_replacement(name, previous, attempts - 1)
    end
  end

  defp resolve_process(resolver) when is_function(resolver, 0), do: resolver.()
  defp resolve_process(name), do: Process.whereis(name)

  defp test_runtime_client_target do
    [host: "127.0.0.1", port: test_node_agent_port()]
  end

  defp test_node_agent_port do
    System.get_env("ORCHARD_TEST_NODE_AGENT_PORT", "50071")
    |> String.to_integer()
  end
end
