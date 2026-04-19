defmodule Orchard.ReleaseTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Release
  alias Orchard.Repo

  setup do
    previous_db_checks = Application.get_env(:orchard_controller, :enable_db_checks, true)
    previous_start_repo = Application.get_env(:orchard_controller, :start_repo, true)
    previous_repo_config = Application.fetch_env!(:orchard_controller, Repo)

    :ok = Sandbox.checkout(Repo)
    Application.put_env(:orchard_controller, :enable_db_checks, true)
    Application.put_env(:orchard_controller, :start_repo, true)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :enable_db_checks, previous_db_checks)
      Application.put_env(:orchard_controller, :start_repo, previous_start_repo)
      Application.put_env(:orchard_controller, Repo, previous_repo_config)
    end)

    :ok
  end

  test "SPEC 13.7 DB helpers report reachable lockable and current Postgres" do
    assert Release.postgres_reachable?()
    assert Release.migration_lockable?() == {:ok, :locked}
    assert Release.migration_status() == {:ok, :current}
    assert Release.migrations_current?()
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
