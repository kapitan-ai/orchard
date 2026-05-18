defmodule OrchardCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias OrchardCLI.Commands.{ApiKeys, Console, Migrate, Models, Nodes, Tenants}

  # A no-op halt function for tests that just need to suppress halt
  defp no_halt(_code), do: :ok

  # A halt stub that sends the exit code to the test process
  defp halt_stub(parent) do
    fn code -> send(parent, {:halt_called, code}) end
  end

  defp check_status(plan, id) do
    plan["checks"]
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("status")
  end

  defp repo_root do
    Path.expand("../../..", __DIR__)
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp db_backed_upgrade_script(missing_manifest_path) do
    """
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Logger.configure(level: :warning)

    test_repo_config = Application.fetch_env!(:orchard_controller, Orchard.Repo)

    encode = fn value -> value |> to_string() |> URI.encode_www_form() end
    username = encode.(Keyword.fetch!(test_repo_config, :username))
    password = encode.(Keyword.get(test_repo_config, :password, ""))
    hostname = Keyword.get(test_repo_config, :hostname, "localhost")
    database = encode.(Keyword.fetch!(test_repo_config, :database))

    port =
      case Keyword.get(test_repo_config, :port) do
        nil -> ""
        value -> ":\#{value}"
      end

    System.put_env("RELEASE_NAME", "orchard_cli")
    System.delete_env("MIX_RELEASE_NAME")
    System.put_env("DATABASE_URL", "ecto://\#{username}:\#{password}@\#{hostname}\#{port}/\#{database}")
    System.put_env("ORCHARD_UPGRADE_BACKUP_MANIFEST_PATH", #{inspect(missing_manifest_path)})
    System.put_env("ORCHARD_UPGRADE_QUEUE_TOLERANCE", "0")
    System.put_env("POOL_SIZE", "2")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    controller_config = Keyword.fetch!(runtime_config, :orchard_controller)

    Enum.each(controller_config, fn
      {Orchard.Repo, value} -> Application.put_env(:orchard_controller, Orchard.Repo, value)
      {key, value} -> Application.put_env(:orchard_controller, key, value)
    end)

    Logger.configure(level: :debug)
    {:ok, _pid} = Orchard.Repo.start_link()
    OrchardCLI.main(["upgrade", "plan", "--json"])
    """
  end

  test "prints usage when invoked without arguments" do
    output = capture_io(fn -> OrchardCLI.main([], &no_halt/1) end)

    assert output =~ "orchardctl (M0 scaffold)"

    assert output =~
             "status, start, stop, migrate, console, cluster, env, license, nodes, models, requests, support, tenants, api-keys, tls, transport, upgrade"
  end

  test "dispatches each placeholder command module" do
    placeholder_commands = ["cluster", "requests", "support"]

    for command <- placeholder_commands do
      output = capture_io(fn -> OrchardCLI.main([command], &no_halt/1) end)
      assert output =~ "not implemented yet"
    end
  end

  test "placeholder commands do not trigger halt" do
    parent = self()

    for command <- ["cluster", "requests", "support"] do
      capture_io(fn -> OrchardCLI.main([command], halt_stub(parent)) end)
      refute_received {:halt_called, _}
    end
  end

  test "env command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["env"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl env"
    assert_received {:halt_called, 1}
  end

  test "nodes command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["nodes"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl nodes"
    assert_received {:halt_called, 1}
  end

  test "Nodes.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Nodes.run([])
    assert message =~ "orchardctl nodes"
  end

  test "models command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["models"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl models"
    assert_received {:halt_called, 1}
  end

  test "tenants command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["tenants"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl tenants"
    assert_received {:halt_called, 1}
  end

  test "api-keys command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["api-keys"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl api-keys"
    assert_received {:halt_called, 1}
  end

  test "models import without path exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["models", "import"], halt_stub(parent))
      end)

    assert stderr =~ "missing bundle path"
    assert_received {:halt_called, 1}
  end

  test "Tenants.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Tenants.run([])
    assert message =~ "orchardctl tenants"
  end

  test "ApiKeys.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = ApiKeys.run([])
    assert message =~ "orchardctl api-keys"
  end

  test "Models.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Models.run([])
    assert message =~ "orchardctl models"
    assert message =~ "<import|list|delete>"
  end

  test "Models.run/1 returns error tuple for missing import path" do
    assert {:error, message, 1} = Models.run(["import"])
    assert message =~ "missing bundle path"
  end

  test "no-arg usage does not trigger halt" do
    parent = self()
    capture_io(fn -> OrchardCLI.main([], halt_stub(parent)) end)
    refute_received {:halt_called, _}
  end

  test "Models.run/1 returns ok tuple for import with too many args" do
    assert {:error, message, 1} = Models.run(["import", "a", "b"])
    assert message =~ "expected exactly one bundle path"
  end

  test "status --help dispatches through main without network activity" do
    output = capture_io(fn -> OrchardCLI.main(["status", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl status"
    assert output =~ "health endpoint"
  end

  test "license help dispatches through main without network activity" do
    output = capture_io(fn -> OrchardCLI.main(["license", "help"], &no_halt/1) end)
    assert output =~ "orchardctl license"
    assert output =~ "activate --key-stdin"
  end

  test "transport help dispatches through main without side effects" do
    output = capture_io(fn -> OrchardCLI.main(["transport", "help"], &no_halt/1) end)
    assert output =~ "orchardctl transport <command>"
    assert output =~ "enable-local-https"
  end

  test "console help dispatches through main without side effects" do
    output = capture_io(fn -> OrchardCLI.main(["console", "help"], &no_halt/1) end)
    assert output =~ "orchardctl console <command>"
    assert output =~ "enable|disable|rotate"
  end

  test "license with missing subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["license"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl license"
    assert_received {:halt_called, 1}
  end

  test "status with extra args exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["status", "extra"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl status"
    assert_received {:halt_called, 1}
  end

  test "start --help dispatches through main without side effects" do
    output = capture_io(fn -> OrchardCLI.main(["start", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl start"
    assert output =~ "launchd"
  end

  test "upgrade help dispatches through main without running preflight" do
    output = capture_io(fn -> OrchardCLI.main(["upgrade", "help"], &no_halt/1) end)
    assert output =~ "orchardctl upgrade"
    assert output =~ "orchardctl upgrade plan [--json]"
  end

  test "upgrade plan help dispatches through main without running preflight" do
    output = capture_io(fn -> OrchardCLI.main(["upgrade", "plan", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl upgrade plan [--json]"
    assert output =~ "SPEC 13.7"
  end

  test "SPEC 13.7 DB-backed JSON upgrade plan keeps stdout empty on non-zero exit" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-cli-upgrade-json-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    script_path = Path.join(tmp_dir, "db_backed_upgrade_plan.exs")
    stdout_path = Path.join(tmp_dir, "stdout.txt")
    stderr_path = Path.join(tmp_dir, "stderr.txt")
    missing_manifest_path = Path.join(tmp_dir, "missing-upgrade-manifest.json")

    File.write!(script_path, db_backed_upgrade_script(missing_manifest_path))

    command =
      "MIX_ENV=test mix run --no-compile --no-deps-check --no-start #{shell_quote(script_path)} " <>
        "> #{shell_quote(stdout_path)} 2> #{shell_quote(stderr_path)}"

    {_shell_output, exit_status} = System.cmd("sh", ["-c", command], cd: repo_root())

    stdout = File.read!(stdout_path)
    stderr = File.read!(stderr_path)

    assert exit_status == 1
    assert stdout == ""

    decoded = Jason.decode!(stderr)
    assert decoded["status"] == "unsafe"
    assert decoded["exit_code"] == 1
    assert check_status(decoded, "backup_manifest") == "blocked"
    assert check_status(decoded, "database_reachable") == "ok"
    assert check_status(decoded, "database_lockable") == "ok"
    assert check_status(decoded, "migrations_current") == "ok"
    assert check_status(decoded, "request_activity") == "ok"
  end

  test "upgrade unknown subcommand exits with usage error" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["upgrade", "apply"], halt_stub(parent))
      end)

    assert stderr =~ "Unknown upgrade subcommand: apply"
    assert_received {:halt_called, 2}
  end

  test "stop --help dispatches through main without side effects" do
    output = capture_io(fn -> OrchardCLI.main(["stop", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl stop"
    assert output =~ "launchd"
  end

  test "migrate --help dispatches through main without running wrapper" do
    output = capture_io(fn -> OrchardCLI.main(["migrate", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl migrate"
    assert output =~ "Orchard.Release.migrate()"
  end

  test "Migrate.run/1 returns error tuple for extra args" do
    assert {:error, message, 1} = Migrate.run(["extra"])
    assert message =~ "orchardctl migrate"
  end

  test "Console.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Console.run([])
    assert message =~ "orchardctl console"
  end

  test "cli application supervisor is running" do
    assert is_pid(Process.whereis(OrchardCLI.Supervisor))
  end
end
