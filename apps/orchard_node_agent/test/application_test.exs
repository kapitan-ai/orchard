defmodule OrchardNodeAgentApplicationTest do
  use ExUnit.Case, async: false

  @sentry_dsn "https://public@example.invalid/1"

  setup do
    previous_env = %{
      sentry_dsn: Application.get_env(:sentry, :dsn),
      controller_start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      controller_start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      controller_enable_db_checks:
        Application.get_env(:orchard_controller, :enable_db_checks, true)
    }

    controller_was_started = is_pid(Process.whereis(Orchard.Supervisor))
    node_agent_was_started = is_pid(Process.whereis(Orchard.NodeAgent.Supervisor))

    stop_controller_app()
    stop_node_agent_app()
    remove_sentry_handler()

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

      remove_sentry_handler()

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
    assert config.metadata == [:request_id, :worker_model]
    assert config.rate_limiting == [max_events: 50, interval: 60_000]
  end

  test "controller and node-agent in one VM keep exactly one Sentry handler" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)

    assert {:ok, %{config: config}} = :logger.get_handler_config(Sentry.LoggerHandler)
    assert config.metadata == [:request_id, :worker_model]

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
