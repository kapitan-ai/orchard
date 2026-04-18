defmodule OrchardApplicationTest do
  use ExUnit.Case, async: false

  @sentry_dsn "https://public@example.invalid/1"

  setup do
    previous_env = %{
      start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      enable_db_checks: Application.get_env(:orchard_controller, :enable_db_checks, true),
      sentry_dsn: Application.get_env(:sentry, :dsn)
    }

    was_started = is_pid(Process.whereis(Orchard.Supervisor))

    stop_controller_app()
    remove_sentry_handler()

    Application.put_env(:orchard_controller, :start_repo, false)
    Application.put_env(:orchard_controller, :start_endpoint, false)
    Application.put_env(:orchard_controller, :enable_db_checks, false)

    on_exit(fn ->
      stop_controller_app()

      Application.put_env(:orchard_controller, :start_repo, previous_env.start_repo)
      Application.put_env(:orchard_controller, :start_endpoint, previous_env.start_endpoint)
      Application.put_env(:orchard_controller, :enable_db_checks, previous_env.enable_db_checks)
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

  test "test environment uses deterministic endpoint config defaults" do
    endpoint_config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    # Loopback HTTP only in test
    assert endpoint_config[:http] == [ip: {127, 0, 0, 1}, port: 4002]
    assert endpoint_config[:https] == nil

    # CORS explicitly empty
    assert endpoint_config[:cors_origins] == []

    # Transport not degraded
    assert Application.get_env(:orchard_controller, :transport_degraded, false) == false
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
    assert inference[:runtime_client_target] == [host: "127.0.0.1", port: 50_071]
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
    assert config.metadata == [:request_id, :worker_model]
    assert config.rate_limiting == [max_events: 50, interval: 60_000]
  end

  test "test environment aligns shared licensing paths with tmp/test" do
    licensing = Application.fetch_env!(:orchard_shared, :licensing)

    assert Path.type(licensing[:bundle_path]) == :absolute
    assert Path.type(licensing[:node_identity_path]) == :absolute
    assert String.ends_with?(licensing[:bundle_path], "/tmp/test/config/licensing/current.json")
    assert String.ends_with?(licensing[:node_identity_path], "/tmp/test/data/node-id")
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
end
