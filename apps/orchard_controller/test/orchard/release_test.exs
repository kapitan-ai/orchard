defmodule Orchard.ReleaseTest.UnexpectedRepo do
end

defmodule Orchard.ReleaseTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Models
  alias Orchard.Release
  alias Orchard.Repo
  alias Orchard.TestSupport.RepoManager

  setup context do
    previous_db_checks = Application.get_env(:orchard_controller, :enable_db_checks, true)
    previous_start_repo = Application.get_env(:orchard_controller, :start_repo, true)
    previous_repo_config = Application.fetch_env!(:orchard_controller, Repo)
    previous_ecto_repos = Application.fetch_env!(:orchard_controller, :ecto_repos)

    unless context[:skip_sandbox] do
      :ok = Sandbox.checkout(Repo)
    end

    Application.put_env(:orchard_controller, :enable_db_checks, true)
    Application.put_env(:orchard_controller, :start_repo, true)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :enable_db_checks, previous_db_checks)
      Application.put_env(:orchard_controller, :start_repo, previous_start_repo)
      Application.put_env(:orchard_controller, Repo, previous_repo_config)
      Application.put_env(:orchard_controller, :ecto_repos, previous_ecto_repos)
      :ok = RepoManager.ensure_repo_started()
    end)

    :ok
  end

  test "SPEC 13.7 DB helpers report reachable lockable and current Postgres" do
    assert Release.postgres_reachable?()
    assert Release.migration_lockable?() == {:ok, :locked}
    assert Release.migration_status() == {:ok, :current}
    assert Release.migrations_current?()
  end

  test "backfill_resident_memory/1 returns a dry-run summary" do
    assert {:ok, result} = Release.backfill_resident_memory()
    assert result.processed == 0
    assert result.updated == 0
    assert result.would_update == 0
    assert result.failed == 0
    assert result.dry_run == true
  end

  test "backfill_resident_memory/1 re-raises callback exceptions" do
    create_backfill_test_model!("release-backfill-test-model")

    assert_raise RuntimeError, "boom", fn ->
      Release.backfill_resident_memory(log: fn _message -> raise "boom" end)
    end
  end

  test "backfill_resident_memory/1 re-raises callback ArgumentError exceptions" do
    create_backfill_test_model!("release-backfill-argument-error-model")

    assert_raise ArgumentError, "boom", fn ->
      Release.backfill_resident_memory(log: fn _message -> raise ArgumentError, "boom" end)
    end
  end

  test "backfill_resident_memory/1 reports unexpected repo count as an error tuple" do
    Application.put_env(:orchard_controller, :ecto_repos, [Repo, Repo])

    assert {:error, {:unexpected_repo_count, 2}} = Release.backfill_resident_memory()
  end

  test "backfill_resident_memory/1 rejects an unexpected single repo" do
    Application.put_env(:orchard_controller, :ecto_repos, [Orchard.ReleaseTest.UnexpectedRepo])

    assert {:error, {:unexpected_repo, Orchard.ReleaseTest.UnexpectedRepo}} =
             Release.backfill_resident_memory()
  end

  test "backfill_resident_memory/1 rejects malformed ecto_repos config" do
    Application.put_env(:orchard_controller, :ecto_repos, :invalid)

    assert {:error, {:invalid_ecto_repos, :invalid}} = Release.backfill_resident_memory()
  end

  test "backfill_resident_memory/1 rejects missing ecto_repos config" do
    Application.delete_env(:orchard_controller, :ecto_repos)

    assert {:error, :missing_ecto_repos} = Release.backfill_resident_memory()
  end

  test "backfill_resident_memory/1 rejects an empty repo list" do
    Application.put_env(:orchard_controller, :ecto_repos, [])

    assert {:error, {:unexpected_repo_count, 0}} = Release.backfill_resident_memory()
  end

  @tag skip_sandbox: true
  test "backfill_resident_memory/1 normalizes DB reachability failures as startup errors" do
    Application.put_env(
      :orchard_controller,
      Repo,
      Keyword.merge(Application.fetch_env!(:orchard_controller, Repo),
        hostname: 123,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )
    )

    :ok = RepoManager.stop_repo()

    assert {:error, {:db_unreachable, _message}} = Release.backfill_resident_memory()
  end

  test "SPEC 13.7 DB helpers fail closed when DB checks are disabled" do
    Application.put_env(:orchard_controller, :enable_db_checks, false)

    refute Release.postgres_reachable?()
    assert Release.migration_lockable?() == {:error, :database_checks_disabled}
    assert Release.migration_status() == {:error, :database_checks_disabled}
    refute Release.migrations_current?()
  end

  test "SPEC 13.7 DB helpers report repo startup disabled" do
    Application.put_env(:orchard_controller, :start_repo, false)

    refute Release.postgres_reachable?()
    assert Release.migration_lockable?() == {:error, :repo_not_started}
    assert Release.migration_status() == {:error, :repo_not_started}
    refute Release.migrations_current?()
  end

  test "SPEC 13.7 migration status reports pending migrations" do
    unique = System.unique_integer([:positive])
    priv = "priv/release_pending_test_#{unique}"
    priv_dir = Application.app_dir(:orchard_controller, priv)
    migrations_dir = Path.join(priv_dir, "migrations")
    File.mkdir_p!(migrations_dir)
    File.write!(Path.join(migrations_dir, "99999999999999_pending_release_test.exs"), "")

    Application.put_env(
      :orchard_controller,
      Repo,
      Keyword.put(Application.fetch_env!(:orchard_controller, Repo), :priv, priv)
    )

    try do
      assert Release.migration_status() == {:ok, :pending}
      refute Release.migrations_current?()
    after
      File.rm_rf(priv_dir)
    end
  end

  defp create_backfill_test_model!(model_id) do
    {:ok, model} =
      Models.create_model(%{
        model_id: model_id,
        version: "v1",
        state: :active,
        format: "mlx",
        capabilities: ["chat"],
        artifact_uri: "file:///models/#{model_id}",
        artifact_sha256: "abc123",
        artifact_size_bytes: 1_000,
        resident_memory_bytes: 2_000,
        kv_cache_bytes_per_token: 32,
        prefill_workspace_bytes_per_token: 64,
        max_context_tokens: 8_192,
        tokenizer: %{"type" => "huggingface_tokenizer_json"},
        runtime_requirements: %{"backend" => "mlx"}
      })

    model
  end

  test "SPEC 13.7 migration lock helper reports another holder" do
    parent = self()
    lock_key = Release.migration_advisory_lock_key()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)

        Repo.transaction(fn ->
          {:ok, _result} = SQL.query(Repo, "SELECT pg_advisory_xact_lock($1)", [lock_key])
          send(parent, :migration_lock_held)

          receive do
            :release_migration_lock -> :released
          after
            5_000 -> :timeout
          end
        end)
      end)

    assert_receive :migration_lock_held, 1_000

    try do
      assert Release.migration_lockable?() == {:error, :locked_by_other}
    after
      send(task.pid, :release_migration_lock)
    end

    assert {:ok, :released} = Task.await(task)
  end
end
