defmodule OrchardCLI.ReleaseEvalRepoRuntimeTest do
  use ExUnit.Case, async: false

  defp repo_root do
    Path.expand("../../../..", __DIR__)
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp release_eval_script(output_path) do
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
    System.put_env("POOL_SIZE", "2")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    controller_config = Keyword.fetch!(runtime_config, :orchard_controller)

    Enum.each(controller_config, fn
      {Orchard.Repo, value} -> Application.put_env(:orchard_controller, Orchard.Repo, value)
      {key, value} -> Application.put_env(:orchard_controller, key, value)
    end)

    cleanup = fn ->
      Ecto.Migrator.with_repo(Orchard.Repo, fn repo ->
        repo.query!("ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_append_only")

        try do
          repo.delete_all(Orchard.Governance.AuditLog)
          repo.delete_all(Orchard.Governance.RoleBinding)
          repo.delete_all(Orchard.Governance.ApiKey)
          repo.delete_all(Orchard.Governance.ServiceAccount)
        after
          repo.query!("ALTER TABLE audit_logs ENABLE TRIGGER audit_logs_append_only")
        end
      end)
    end

    cleanup.()

    if Process.whereis(Orchard.Repo) do
      raise "release eval test precondition failed: Orchard.Repo is already started"
    end

    try do
      OrchardCLI.main([
        "cluster",
        "init",
        "--output",
        #{inspect(output_path)}
      ])
    after
      cleanup.()
    end
    """
  end

  defp model_release_eval_script(bundle_path, artifacts_root) do
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
    System.put_env("ORCHARD_ARTIFACTS_ROOT", #{inspect(artifacts_root)})
    System.put_env("POOL_SIZE", "2")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    controller_config = Keyword.fetch!(runtime_config, :orchard_controller)

    Enum.each(controller_config, fn
      {Orchard.Repo, value} -> Application.put_env(:orchard_controller, Orchard.Repo, value)
      {key, value} -> Application.put_env(:orchard_controller, key, value)
    end)

    cleanup_model = fn ->
      Ecto.Migrator.with_repo(Orchard.Repo, fn repo ->
        import Ecto.Query

        repo.delete_all(
          from model in Orchard.Models.Model,
            where: model.model_id == "test-org/tiny-llm" and model.version == "mlx-q4-v1"
        )
      end)
    end

    assert_cli_runtime_only = fn ->
      started_apps = Application.started_applications() |> Enum.map(&elem(&1, 0))

      if :orchard_controller in started_apps do
        raise "release eval started :orchard_controller"
      end

      if Process.whereis(Orchard.Supervisor) do
        raise "release eval started Orchard.Supervisor"
      end

      if Process.whereis(Orchard.API.Endpoint) do
        raise "release eval started Orchard.API.Endpoint"
      end

      if Process.whereis(Orchard.Repo) do
        raise "release eval left Orchard.Repo running"
      end
    end

    retire_model = fn ->
      Ecto.Migrator.with_repo(Orchard.Repo, fn repo ->
        import Ecto.Query

        {1, _rows} =
          repo.update_all(
            from(model in Orchard.Models.Model,
              where: model.model_id == "test-org/tiny-llm" and model.version == "mlx-q4-v1"
            ),
            set: [state: :retired]
          )
      end)
    end

    cleanup_model.()

    if Process.whereis(Orchard.Repo) do
      raise "release eval test precondition failed: Orchard.Repo is already started"
    end

    OrchardCLI.main(["models", "import", #{inspect(bundle_path)}, "--activate"])
    assert_cli_runtime_only.()

    OrchardCLI.main(["models", "list"])
    assert_cli_runtime_only.()

    retire_model.()
    assert_cli_runtime_only.()

    OrchardCLI.main(["models", "delete", "test-org/tiny-llm@mlx-q4-v1"])
    assert_cli_runtime_only.()

    cleanup_model.()
    """
  end

  defp missing_database_url_script do
    """
    Application.ensure_all_started(:logger)
    Logger.configure(level: :warning)

    System.put_env("RELEASE_NAME", "orchard_cli")
    System.delete_env("MIX_RELEASE_NAME")
    System.delete_env("DATABASE_URL")
    Application.delete_env(:orchard_controller, Orchard.Repo)

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    controller_config = Keyword.fetch!(runtime_config, :orchard_controller)

    Enum.each(controller_config, fn
      {Orchard.Repo, value} -> Application.put_env(:orchard_controller, Orchard.Repo, value)
      {key, value} -> Application.put_env(:orchard_controller, key, value)
    end)

    OrchardCLI.main(["models", "list"])
    """
  end

  defp unreachable_database_script(args \\ ["models", "list"]) do
    """
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Logger.configure(level: :warning)

    System.put_env("RELEASE_NAME", "orchard_cli")
    System.delete_env("MIX_RELEASE_NAME")
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@127.0.0.1:1/orchard_unreachable?ssl=false")
    System.put_env("POOL_SIZE", "1")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    controller_config = Keyword.fetch!(runtime_config, :orchard_controller)

    Enum.each(controller_config, fn
      {Orchard.Repo, value} -> Application.put_env(:orchard_controller, Orchard.Repo, value)
      {key, value} -> Application.put_env(:orchard_controller, key, value)
    end)

    OrchardCLI.main(#{inspect(args)})
    """
  end

  defp run_release_eval_script(script, tmp_dir, basename) do
    script_path = Path.join(tmp_dir, "#{basename}.exs")
    stdout_path = Path.join(tmp_dir, "#{basename}.stdout.txt")
    stderr_path = Path.join(tmp_dir, "#{basename}.stderr.txt")

    File.write!(script_path, script)

    command =
      "MIX_ENV=test mix run --no-compile --no-deps-check --no-start #{shell_quote(script_path)} " <>
        "> #{shell_quote(stdout_path)} 2> #{shell_quote(stderr_path)}"

    {_shell_output, exit_status} = System.cmd("sh", ["-c", command], cd: repo_root())

    %{
      exit_status: exit_status,
      stdout: File.read!(stdout_path),
      stderr: File.read!(stderr_path)
    }
  end

  test "packaged release eval starts only the repo runtime for DB-backed cluster init" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-cli-release-eval-repo-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    output_path = Path.join(tmp_dir, "bootstrap-admin.json")
    script_path = Path.join(tmp_dir, "release_eval_cluster_init.exs")
    stdout_path = Path.join(tmp_dir, "stdout.txt")
    stderr_path = Path.join(tmp_dir, "stderr.txt")

    File.write!(script_path, release_eval_script(output_path))

    command =
      "MIX_ENV=test mix run --no-compile --no-deps-check --no-start #{shell_quote(script_path)} " <>
        "> #{shell_quote(stdout_path)} 2> #{shell_quote(stderr_path)}"

    {_shell_output, exit_status} = System.cmd("sh", ["-c", command], cd: repo_root())

    stdout = File.read!(stdout_path)
    stderr = File.read!(stderr_path)

    assert exit_status == 0, stderr
    assert stdout =~ "Cluster admin credential minted."
    assert stdout =~ "One-time Secret Output: #{output_path}"
    assert File.regular?(output_path)

    decoded = output_path |> File.read!() |> Jason.decode!()

    assert decoded["api_token"] =~
             ~r/^orchard_sk_[A-Za-z0-9_-]{16}_[A-Za-z0-9_-]{43}$/
  end

  test "packaged release eval runs model import list and delete without starting listeners" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-cli-release-eval-models-#{System.unique_integer([:positive])}"
      )

    artifacts_root = Path.join(tmp_dir, "artifacts")

    bundle_path =
      Path.expand("../../../orchard_controller/test/fixtures/bundles/test-model-bundle", __DIR__)

    File.mkdir_p!(artifacts_root)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    result =
      model_release_eval_script(bundle_path, artifacts_root)
      |> run_release_eval_script(tmp_dir, "release_eval_models")

    assert result.exit_status == 0, result.stderr
    assert result.stdout =~ "Imported test-org/tiny-llm@mlx-q4-v1 (state: active)"
    assert result.stdout =~ "test-org/tiny-llm@mlx-q4-v1  state=active  format=mlx"
    assert result.stdout =~ "Deleted test-org/tiny-llm@mlx-q4-v1"
  end

  test "packaged release eval reports missing DATABASE_URL with sudo env guidance" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-cli-release-eval-missing-db-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    result =
      run_release_eval_script(missing_database_url_script(), tmp_dir, "missing_database_url")

    assert result.exit_status == 1
    assert result.stdout == ""
    assert result.stderr =~ "DATABASE_URL is not configured"
    assert result.stderr =~ "sudo"
    assert result.stderr =~ "/Library/Application Support/Orchard/config/controller.env"
  end

  test "packaged release eval reports unreachable database without falling back to empty data" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-cli-release-eval-unreachable-db-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    result =
      run_release_eval_script(unreachable_database_script(), tmp_dir, "unreachable_database")

    assert result.exit_status == 1
    assert result.stderr =~ "database is unavailable"
    assert result.stderr =~ "PostgreSQL is reachable"
    refute result.stdout =~ "No active models."
    refute result.stderr =~ "No active models."
  end

  test "packaged release eval nodes list reports unreachable database without empty fallback" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-cli-release-eval-unreachable-nodes-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    result =
      ["nodes", "list"]
      |> unreachable_database_script()
      |> run_release_eval_script(tmp_dir, "unreachable_nodes_database")

    assert result.exit_status == 1
    assert result.stderr =~ "database is unavailable"
    assert result.stderr =~ "PostgreSQL is reachable"
    refute result.stdout =~ "No nodes registered."
    refute result.stderr =~ "No nodes registered."
  end
end
