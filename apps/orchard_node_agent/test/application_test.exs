defmodule OrchardNodeAgentApplicationTest.BootstrapIdentityLoader do
  @moduledoc false

  def load_registered_identity(_root, require_controller_certificate: true) do
    send(:orchard_node_app_test, :application_identity_loaded)
    {:ok, identity()}
  end

  def identity do
    %{
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }
  end
end

defmodule OrchardNodeAgentApplicationTest.BootstrapDescriptorLoader do
  @moduledoc false

  def load(_path) do
    send(:orchard_node_app_test, :application_descriptor_loaded)
    {:ok, descriptor()}
  end

  def descriptor do
    %{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      control_endpoint: "10.0.0.10:50072"
    }
  end
end

defmodule OrchardNodeAgentApplicationTest.BootstrapGrantStore do
  @moduledoc false

  def load(_root, _identity, _node_name) do
    send(:orchard_node_app_test, :application_grant_loaded)
    {:ok, grant()}
  end

  def ensure_current(_grant), do: :ok

  def grant do
    %{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"
    }
  end
end

defmodule OrchardNodeAgentApplicationTest.BootstrapCookieInstaller do
  @moduledoc false

  def install(grant, node_name) do
    send(:orchard_node_app_test, {:application_peer_grant_installed, grant, node_name})
    :ok
  end
end

defmodule OrchardNodeAgentApplicationTest.BootstrapStartupVerifier do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(:orchard_node_app_test, {:application_launch_verified, opts})
    {:ok, opts}
  end
end

defmodule OrchardNodeAgentApplicationTest.BootstrapExpiryGuard do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(:orchard_node_app_test, {:application_expiry_guard_started, opts})
    {:ok, opts}
  end
end

defmodule OrchardNodeAgentApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OrchardNodeAgentApplicationTest.{
    BootstrapCookieInstaller,
    BootstrapDescriptorLoader,
    BootstrapExpiryGuard,
    BootstrapGrantStore,
    BootstrapIdentityLoader,
    BootstrapStartupVerifier
  }

  alias Orchard.Node.Identity
  alias Orchard.Node.SentryTelemetryBridge
  alias Orchard.SentryHandlerTestSupport

  @sentry_dsn "https://public@example.invalid/1"

  defmodule BackgroundCrash do
    defexception message: "controlled Node Agent background crash"
  end

  defmodule BackgroundCrashProcess do
    use GenServer

    def start, do: GenServer.start(__MODULE__, nil)
    def crash(pid), do: GenServer.cast(pid, :crash)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:crash, _state) do
      Orchard.SentryContext.clear_all()
      raise OrchardNodeAgentApplicationTest.BackgroundCrash
    end
  end

  setup do
    previous_env = %{
      sentry: snapshot_sentry_env(),
      controller_start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      controller_start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      controller_enable_db_checks:
        Application.get_env(:orchard_controller, :enable_db_checks, true),
      node_agent_beam_peer_grants: Application.get_env(:orchard_node_agent, :beam_peer_grants),
      node_agent_runtime: Application.get_env(:orchard_node_agent, :runtime, [])
    }

    controller_was_started = is_pid(Process.whereis(Orchard.Supervisor))
    node_agent_was_started = is_pid(Process.whereis(Orchard.NodeAgent.Supervisor))
    sentry_was_started = application_started?(:sentry)
    previous_handler = :logger.get_handler_config(Sentry.LoggerHandler)

    stop_controller_app()
    stop_node_agent_app()
    remove_sentry_handler()
    stop_sentry_app()
    SentryTelemetryBridge.detach()

    Application.put_env(:orchard_controller, :start_repo, false)
    Application.put_env(:orchard_controller, :start_endpoint, false)
    Application.put_env(:orchard_controller, :enable_db_checks, false)
    Application.put_env(:orchard_node_agent, :beam_peer_grants, enabled: false)

    on_exit(fn ->
      stop_controller_app()
      stop_node_agent_app()
      remove_sentry_handler()
      stop_sentry_app()
      restore_sentry_env(previous_env.sentry)

      if sentry_was_started do
        {:ok, _apps} = Application.ensure_all_started(:sentry)
      end

      SentryHandlerTestSupport.restore_handler(previous_handler)
      Application.put_env(:orchard_controller, :start_repo, previous_env.controller_start_repo)

      Application.put_env(
        :orchard_controller,
        :start_endpoint,
        previous_env.controller_start_endpoint
      )

      Application.put_env(
        :orchard_controller,
        :enable_db_checks,
        previous_env.controller_enable_db_checks
      )

      Application.put_env(:orchard_node_agent, :runtime, previous_env.node_agent_runtime)

      restore_app_env(
        :orchard_node_agent,
        :beam_peer_grants,
        previous_env.node_agent_beam_peer_grants
      )

      SentryTelemetryBridge.detach()

      if controller_was_started do
        {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
      end

      if node_agent_was_started do
        {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
      end
    end)

    :ok
  end

  test "SPEC.md §7.5.0 production grant bootstrap precedes the Node runtime supervisor" do
    config = [
      enabled: true,
      manifest_path: "/protected/launch.json",
      descriptor_path: "/protected/peer-grant.json"
    ]

    Application.put_env(:orchard_node_agent, :beam_peer_grants, config)

    assert [
             {Orchard.Node.BeamPeerGrantStartupVerifier, verifier_opts},
             {Orchard.RuntimeEndpoint.DistributionExpiryGuard, expiry_opts},
             {Orchard.Node.BeamPeerGrantBootstrap, bootstrap_opts},
             Orchard.Node.Supervisor
           ] = Orchard.NodeAgent.Application.child_specs()

    assert verifier_opts[:manifest_path] == config[:manifest_path]
    assert expiry_opts == [manifest_path: config[:manifest_path]]
    assert bootstrap_opts[:descriptor_path] == config[:descriptor_path]
    assert bootstrap_opts[:retrieval] == :forbid

    Application.put_env(:orchard_node_agent, :beam_peer_grants, enabled: false)
    assert [Orchard.Node.Supervisor] = Orchard.NodeAgent.Application.child_specs()
  end

  test "controller and node-agent startup ignore legacy product-license configuration" do
    legacy_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-startup-license-#{System.unique_integer([:positive])}"
      )

    bundle_path = Path.join([legacy_root, "config", "licensing", "current.json"])
    bundle = ~s({"license_certificate":"legacy","machine_certificate":"legacy"})
    File.mkdir_p!(Path.dirname(bundle_path))
    File.write!(bundle_path, bundle)
    {:ok, before_stat} = File.stat(bundle_path)

    previous_licensing = Application.get_env(:orchard_shared, :licensing)

    legacy_env = %{
      "ORCHARD_LICENSE_ENFORCEMENT" => "not-a-mode",
      "ORCHARD_LICENSE_BUNDLE_PATH" => bundle_path,
      "ORCHARD_KEYGEN_API_BASE_URL" => "not a url",
      "ORCHARD_KEYGEN_ACCOUNT_ID" => "not-an-account",
      "ORCHARD_KEYGEN_PUBLIC_KEY" => "not-a-key"
    }

    previous_env = Map.new(legacy_env, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(legacy_env, fn {key, value} -> System.put_env(key, value) end)

    Application.put_env(:orchard_shared, :licensing,
      enforcement_mode: :hard,
      bundle_path: bundle_path
    )

    for app <- [:orchard_node_agent, :orchard_controller] do
      case Application.stop(app) do
        :ok -> :ok
        {:error, {:not_started, ^app}} -> :ok
      end
    end

    on_exit(fn ->
      restore_app_env(:orchard_shared, :licensing, previous_licensing)

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(legacy_root)
      assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
      assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    end)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    assert File.read!(bundle_path) == bundle
    assert {:ok, after_stat} = File.stat(bundle_path)
    assert after_stat.size == before_stat.size
    assert after_stat.mode == before_stat.mode
    assert after_stat.mtime == before_stat.mtime
  end

  test "SPEC.md §7.5.0 peer-grant startup derives the runtime Node id from registered identity" do
    Process.register(self(), :orchard_node_app_test)

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-peer-grant-runtime-identity-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:orchard_node_agent, :runtime,
      node_id: nil,
      node_identity_path: Path.join(root, "unrelated-node-id"),
      grpc_security: :plaintext_compatibility
    )

    Application.put_env(:orchard_node_agent, :beam_peer_grants,
      enabled: true,
      identity_root: "/protected/node-identity",
      identity_loader: BootstrapIdentityLoader
    )

    assert Identity.ensure_identity!() == "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    assert Application.fetch_env!(:orchard_node_agent, :runtime)[:node_id] ==
             "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    refute File.exists?(Path.join(root, "unrelated-node-id"))
  end

  test "SPEC.md §7.5.0 node-agent startup installs its admitted grant before runtime startup" do
    Process.register(self(), :orchard_node_app_test)
    node_name = "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"
    grant = BootstrapGrantStore.grant()

    Application.put_env(:orchard_node_agent, :beam_peer_grants,
      enabled: true,
      startup_verifier: BootstrapStartupVerifier,
      expiry_guard: BootstrapExpiryGuard,
      manifest_path: "/protected/launch.json",
      identity_root: "/protected/node-identity",
      descriptor_path: "/protected/peer-grant.json",
      node_beam_name: node_name,
      identity_loader: BootstrapIdentityLoader,
      descriptor_loader: BootstrapDescriptorLoader,
      grant_store: BootstrapGrantStore,
      cookie_installer: BootstrapCookieInstaller
    )

    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    Application.put_env(:orchard_node_agent, :runtime, Keyword.put(runtime, :node_id, nil))

    assert [
             {BootstrapStartupVerifier, verifier_opts},
             {BootstrapExpiryGuard, expiry_opts},
             {Orchard.Node.BeamPeerGrantBootstrap, bootstrap_opts},
             Orchard.Node.Supervisor
           ] = Orchard.NodeAgent.Application.child_specs()

    assert verifier_opts[:manifest_path] == "/protected/launch.json"
    assert expiry_opts == [manifest_path: "/protected/launch.json"]
    assert bootstrap_opts[:identity_loader] == BootstrapIdentityLoader
    assert bootstrap_opts[:descriptor_loader] == BootstrapDescriptorLoader
    assert bootstrap_opts[:grant_store] == BootstrapGrantStore
    assert bootstrap_opts[:cookie_installer] == BootstrapCookieInstaller
    assert bootstrap_opts[:identity_root] == "/protected/node-identity"
    assert bootstrap_opts[:descriptor_path] == "/protected/peer-grant.json"
    assert bootstrap_opts[:node_beam_name] == node_name

    start_result = Application.ensure_all_started(:orchard_node_agent)
    assert {:ok, _apps} = start_result
    assert_receive {:application_launch_verified, _opts}
    assert_receive {:application_expiry_guard_started, ^expiry_opts}
    assert_receive :application_identity_loaded
    assert_receive :application_descriptor_loaded
    assert_receive :application_grant_loaded
    assert_receive {:application_peer_grant_installed, ^grant, ^node_name}
    assert is_pid(Process.whereis(Orchard.NodeAgent.Supervisor))
    assert is_pid(Process.whereis(Orchard.Node.Supervisor))
  end

  test "no DSN leaves Sentry logger handler uninstalled when node-agent starts" do
    Application.put_env(:sentry, :dsn, nil)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)

    assert :logger.get_handler_config(Sentry.LoggerHandler) in [
             {:error, :not_found},
             {:error, {:not_found, Sentry.LoggerHandler}}
           ]
  end

  test "DSN installs Sentry logger handler with expected metadata whitelist when node-agent starts" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)

    assert {:ok, %{config: config}} = :logger.get_handler_config(Sentry.LoggerHandler)
    assert config.capture_log_messages == false
    assert config.capture_excluded_domains == [:cowboy]
    assert config.capture_metadata == [:request_id, :worker_model, :model_backend]
    assert config.rate_limiting == [max_events: 50, interval: 60_000]
    assert :ok = SentryTelemetryBridge.attach()
  end

  test "Sentry logger installation fails closed when the Sentry supervisor is unavailable" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

    _log =
      capture_log(fn ->
        assert {:error, _reason} = Orchard.SentryLogger.install_handler()
      end)

    assert :logger.get_handler_config(Sentry.LoggerHandler) in [
             {:error, :not_found},
             {:error, {:not_found, Sentry.LoggerHandler}}
           ]
  end

  test "Sentry logger handler configuration survives snapshot restoration" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)
    assert {:ok, _apps} = Application.ensure_all_started(:sentry)
    assert :ok = Orchard.SentryLogger.install_handler()
    assert {:ok, before} = :logger.get_handler_config(Sentry.LoggerHandler)

    remove_sentry_handler()
    assert :ok = SentryHandlerTestSupport.restore_handler({:ok, before})

    assert {:ok, after_restore} = :logger.get_handler_config(Sentry.LoggerHandler)
    assert after_restore.config.capture_excluded_domains == before.config.capture_excluded_domains
    assert after_restore.config.capture_metadata == before.config.capture_metadata
    assert after_restore.config.rate_limiting == before.config.rate_limiting
  end

  test "logger-captured background crash retains static Node Agent identity" do
    identity =
      Orchard.SentryRelease.identity("orchard_node_agent", "0.5.0-dev",
        build_sha: "abcdef1234567890",
        build_date: "2026-07-30",
        build_channel: "internal"
      )

    Application.put_env(:sentry, :dsn, @sentry_dsn)
    Application.put_env(:sentry, :before_send, {Orchard.SentryFilter, :filter})
    Application.put_env(:sentry, :environment_name, "issue-114-node-agent")
    Application.put_env(:sentry, :release, identity.release)
    Application.put_env(:sentry, :tags, identity.tags)
    Application.put_env(:sentry, :send_result, :none)
    Application.put_env(:sentry, :test_mode, true)
    persist_sentry_config()

    {:ok, _apps} = Application.ensure_all_started(:sentry)
    :ok = Sentry.Test.start_collecting_sentry_reports()
    :ok = Orchard.SentryLogger.install_handler()
    _flushed_reports = Sentry.Test.pop_sentry_reports()

    {:ok, pid} = BackgroundCrashProcess.start()
    :ok = Sentry.Test.allow_sentry_reports(self(), pid)

    ref = Process.monitor(pid)
    BackgroundCrashProcess.crash(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%BackgroundCrash{}, _stack}}, 5_000

    event = pop_node_background_crash_report()

    assert event.source == :logger
    assert event.release == identity.release
    assert event.environment == "issue-114-node-agent"
    assert event.tags.orchard_app == "node_agent"
    assert event.tags.orchard_version == "0.5.0-dev"
    assert event.tags.orchard_build_channel == "internal"
    assert event.tags.build_sha == "abcdef1234567890"
    assert event.tags.build_date == "2026-07-30"
    assert event.request.method == nil
    assert event.user == %{}

    envelope = serialized_filtered_envelope(event)
    payload = envelope |> String.split("\n") |> Enum.at(2) |> Jason.decode!()

    assert payload["release"] == identity.release
    assert payload["tags"]["orchard_app"] == "node_agent"
    assert get_in(payload, ["exception", Access.at(0), "value"]) == "[Filtered]"
    assert get_in(payload, ["exception", Access.at(0), "module"]) == nil
    refute envelope =~ "controlled Node Agent background crash"
    refute envelope =~ "/Users/"
  end

  test "controller and node-agent in one VM keep exactly one Sentry handler" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)

    assert {:ok, %{config: config}} = :logger.get_handler_config(Sentry.LoggerHandler)
    assert config.capture_excluded_domains == [:cowboy]
    assert config.capture_metadata == [:request_id, :worker_model, :model_backend]

    handler_count =
      :logger.get_handler_ids()
      |> Enum.uniq()
      |> Enum.count(&(&1 == Sentry.LoggerHandler))

    assert handler_count == 1
  end

  test "concurrent install_handler/0 calls process one crash exactly once" do
    before_send_calls = :atomics.new(1, signed: false)

    Application.put_env(:sentry, :dsn, @sentry_dsn)
    Application.put_env(:sentry, :send_result, :none)
    Application.put_env(:sentry, :test_mode, true)

    Application.put_env(:sentry, :before_send, fn event ->
      _count = :atomics.add_get(before_send_calls, 1, 1)
      event
    end)

    persist_sentry_config()
    assert {:ok, _apps} = Application.ensure_all_started(:sentry)
    :ok = Sentry.Test.start_collecting_sentry_reports()

    1..16
    |> Task.async_stream(fn _ -> Orchard.SentryLogger.install_handler() end,
      max_concurrency: 16,
      ordered: false,
      timeout: 5_000
    )
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    handler_count =
      :logger.get_handler_ids()
      |> Enum.uniq()
      |> Enum.count(&(&1 == Sentry.LoggerHandler))

    assert handler_count == 1

    {:ok, pid} = BackgroundCrashProcess.start()
    :ok = Sentry.Test.allow_sentry_reports(self(), pid)

    ref = Process.monitor(pid)
    BackgroundCrashProcess.crash(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%BackgroundCrash{}, _stack}}, 5_000
    assert %Sentry.Event{} = pop_node_background_crash_report()
    assert :atomics.get(before_send_calls, 1) == 1
  end

  defp stop_controller_app do
    case Application.stop(:orchard_controller) do
      :ok -> :ok
      {:error, {:not_started, :orchard_controller}} -> :ok
    end
  end

  defp stop_node_agent_app do
    case Application.stop(:orchard_node_agent) do
      :ok -> :ok
      {:error, {:not_started, :orchard_node_agent}} -> :ok
    end
  end

  defp stop_sentry_app do
    case Application.stop(:sentry) do
      :ok -> :ok
      {:error, {:not_started, :sentry}} -> :ok
    end
  end

  defp application_started?(app) do
    Enum.any?(Application.started_applications(), fn {started_app, _description, _version} ->
      started_app == app
    end)
  end

  defp remove_sentry_handler do
    case :logger.remove_handler(Sentry.LoggerHandler) do
      :ok -> remove_sentry_handler()
      {:error, :not_found} -> :ok
      {:error, {:not_found, Sentry.LoggerHandler}} -> :ok
    end
  end

  defp pop_node_background_crash_report(deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    events = Sentry.Test.pop_sentry_reports()
    event = Enum.find(events, &match?(%BackgroundCrash{}, &1.original_exception))

    cond do
      event ->
        event

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(25)
        pop_node_background_crash_report(deadline)

      events == [] ->
        flunk("Node Agent process reached :DOWN but no Sentry event was collected")

      true ->
        flunk("Sentry reports were collected, but none matched the Node Agent crash")
    end
  end

  defp serialized_filtered_envelope(event) do
    filtered_event = Orchard.SentryFilter.filter(event)
    envelope = Sentry.Envelope.from_event(filtered_event)
    {:ok, binary} = Sentry.Envelope.to_binary(envelope)
    binary
  end

  defp snapshot_sentry_env do
    :sentry
    |> Application.get_all_env()
    |> Map.new()
  end

  defp restore_sentry_env(previous) do
    :sentry
    |> Application.get_all_env()
    |> Keyword.keys()
    |> Enum.each(&Application.delete_env(:sentry, &1))

    Enum.each(previous, fn {key, value} -> Application.put_env(:sentry, key, value) end)
    persist_sentry_config()
  end

  defp persist_sentry_config do
    :sentry
    |> Application.get_all_env()
    |> Sentry.Config.validate!()
    |> Sentry.Config.persist()
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
