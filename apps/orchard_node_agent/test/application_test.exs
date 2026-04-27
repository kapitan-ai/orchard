defmodule OrchardNodeAgentApplicationTest.ValidLicense do
  @moduledoc false

  def inspect_local do
    %Orchard.Licensing{
      state: :valid,
      message: "License bundle is valid.",
      bundle_path: "/tmp/orchard-license.json",
      license_id: "lic_valid_application_test",
      machine_id: "mach_application_test",
      licensee: "Orchard Test",
      max_machines: 3,
      metadata: %{program: "eval", reference: "phase-6"}
    }
  end
end

defmodule OrchardNodeAgentApplicationTest.ExpiredLicense do
  @moduledoc false

  def inspect_local do
    %Orchard.Licensing{
      state: :expired,
      message: "License bundle has expired.",
      bundle_path: "/tmp/orchard-license.json",
      license_id: "lic_expired_application_test",
      machine_id: "mach_application_test",
      licensee: "Orchard Test",
      max_machines: 3,
      metadata: %{program: "eval", reference: "phase-6"}
    }
  end
end

defmodule OrchardNodeAgentApplicationTest.RaisingLicense do
  @moduledoc false

  def inspect_local do
    raise "license store unavailable"
  end
end

defmodule OrchardNodeAgentApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Node.LicenseEnforcer
  alias Orchard.Node.SentryTelemetryBridge
  alias Orchard.SentryContext

  @sentry_dsn "https://public@example.invalid/1"

  setup do
    previous_env = %{
      sentry_dsn: Application.get_env(:sentry, :dsn),
      controller_start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      controller_start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      controller_enable_db_checks:
        Application.get_env(:orchard_controller, :enable_db_checks, true),
      node_agent_runtime: Application.get_env(:orchard_node_agent, :runtime, []),
      shared_licensing: Application.get_env(:orchard_shared, :licensing, [])
    }

    controller_was_started = is_pid(Process.whereis(Orchard.Supervisor))
    node_agent_was_started = is_pid(Process.whereis(Orchard.NodeAgent.Supervisor))

    stop_controller_app()
    stop_node_agent_app()
    remove_sentry_handler()
    SentryTelemetryBridge.detach()
    SentryContext.clear_cached_license_status()

    Application.put_env(:orchard_controller, :start_repo, false)
    Application.put_env(:orchard_controller, :start_endpoint, false)
    Application.put_env(:orchard_controller, :enable_db_checks, false)

    on_exit(fn ->
      stop_controller_app()
      stop_node_agent_app()

      Application.put_env(:sentry, :dsn, previous_env.sentry_dsn)
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
      Application.put_env(:orchard_shared, :licensing, previous_env.shared_licensing)

      remove_sentry_handler()
      SentryTelemetryBridge.detach()
      SentryContext.clear_cached_license_status()

      if controller_was_started do
        {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
      end

      if node_agent_was_started do
        {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
      end
    end)

    :ok
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
    assert config.metadata == [:request_id, :worker_model, :orchard_node_id, :model_backend]
    assert config.rate_limiting == [max_events: 50, interval: 60_000]
    assert :ok = SentryTelemetryBridge.attach()
  end

  test "controller and node-agent in one VM keep exactly one Sentry handler" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)

    assert {:ok, %{config: config}} = :logger.get_handler_config(Sentry.LoggerHandler)
    assert config.metadata == [:request_id, :worker_model, :orchard_node_id, :model_backend]

    handler_count =
      :logger.get_handler_ids()
      |> Enum.uniq()
      |> Enum.count(&(&1 == Sentry.LoggerHandler))

    assert handler_count == 1
  end

  test "concurrent install_handler/0 calls keep exactly one Sentry handler" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

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
  end

  test "startup logs valid local license traceability at info level" do
    put_license_startup_config(:off, OrchardNodeAgentApplicationTest.ValidLicense)

    log =
      with_logger_level(:info, fn ->
        capture_log([level: :info, metadata: :all], fn ->
          assert :ok = LicenseEnforcer.enforce_startup!()
        end)
      end)

    assert log =~ "Node-agent startup license tracking"
    assert log =~ "orchard_license_state=valid"
    assert log =~ "orchard_license_id=lic_valid_application_test"
    assert log =~ "app=orchard_node_agent"
    assert log =~ "enforcement=off"
    refute log =~ "Orchard Test"
  end

  test "startup treats inspection failures as missing license when enforcement is off" do
    put_license_startup_config(:off, OrchardNodeAgentApplicationTest.RaisingLicense)

    log =
      with_logger_level(:info, fn ->
        capture_log([level: :info, metadata: :all], fn ->
          assert :ok = LicenseEnforcer.enforce_startup!()
        end)
      end)

    assert log =~ "Node-agent startup license tracking"
    assert log =~ "orchard_license_state=missing"
    assert log =~ "enforcement=off"
  end

  test "startup logs warning license traceability under warn enforcement" do
    put_license_startup_config(:warn, OrchardNodeAgentApplicationTest.ExpiredLicense)

    log =
      capture_log([level: :warning, metadata: :all], fn ->
        assert :ok = LicenseEnforcer.enforce_startup!()
      end)

    assert log =~ "Node-agent startup license warn"
    assert log =~ "orchard_license_state=invalid"
    assert log =~ "orchard_license_id=lic_expired_application_test"
    assert log =~ "enforcement=warn"
    refute log =~ "message="
    refute log =~ "Orchard Test"
  end

  test "startup logs error license traceability before hard enforcement denial" do
    put_license_startup_config(:hard, OrchardNodeAgentApplicationTest.ExpiredLicense)

    log =
      capture_log([level: :error, metadata: :all], fn ->
        assert_raise RuntimeError,
                     ~r/Node-agent startup blocked by licensing: expired/,
                     fn -> LicenseEnforcer.enforce_startup!() end
      end)

    assert log =~ "Node-agent startup license deny"
    assert log =~ "orchard_license_state=invalid"
    assert log =~ "orchard_license_id=lic_expired_application_test"
    assert log =~ "enforcement=hard"
    refute log =~ "message="
    refute log =~ "Orchard Test"
  end

  defp put_license_startup_config(enforcement, licensing_impl) do
    shared_licensing =
      :orchard_shared
      |> Application.get_env(:licensing, [])
      |> Keyword.put(:enforcement_mode, enforcement)
      |> Keyword.put(:licensing_impl, licensing_impl)

    node_runtime =
      :orchard_node_agent
      |> Application.get_env(:runtime, [])
      |> Keyword.put(:licensing_impl, licensing_impl)

    Application.put_env(:orchard_shared, :licensing, shared_licensing)
    Application.put_env(:orchard_node_agent, :runtime, node_runtime)
  end

  defp with_logger_level(level, fun) do
    previous_level = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
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

  defp remove_sentry_handler do
    case :logger.remove_handler(Sentry.LoggerHandler) do
      :ok -> remove_sentry_handler()
      {:error, :not_found} -> :ok
      {:error, {:not_found, Sentry.LoggerHandler}} -> :ok
    end
  end
end
