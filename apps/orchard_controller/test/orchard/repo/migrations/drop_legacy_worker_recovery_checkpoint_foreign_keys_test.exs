defmodule Orchard.Repo.Migrations.DropLegacyWorkerRecoveryCheckpointForeignKeysTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Orchard.Repo
  alias Orchard.Repo.Migrations.DropLegacyWorkerRecoveryCheckpointForeignKeys, as: Migration

  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20261026000000_drop_legacy_worker_recovery_checkpoint_foreign_keys.exs",
      __DIR__
    )
  )

  @node_id "11111111-1111-1111-1111-111111111111"
  @model_id "22222222-2222-2222-2222-222222222222"

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    prefix = "worker_recovery_fk_migration_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.query!("DROP SCHEMA #{prefix} CASCADE") end)
    end)

    Repo.query!("CREATE TABLE #{prefix}.nodes (id uuid PRIMARY KEY)")
    Repo.query!("CREATE TABLE #{prefix}.models (id uuid PRIMARY KEY)")
    %{prefix: prefix}
  end

  test "SPEC.md §12.2.2 drops the pre-merge #444 foreign keys so checkpoints outlive Node and model rows",
       %{prefix: prefix} do
    # The shape an earlier revision of 20260908000000 created.
    create_checkpoints(prefix, """
    node_id uuid NOT NULL REFERENCES #{prefix}.nodes (id) ON DELETE CASCADE,
    model_id uuid NOT NULL REFERENCES #{prefix}.models (id) ON DELETE CASCADE,
    """)

    Repo.query!("INSERT INTO #{prefix}.nodes VALUES ('#{@node_id}')")
    Repo.query!("INSERT INTO #{prefix}.models VALUES ('#{@model_id}')")

    Repo.query!("""
    INSERT INTO #{prefix}.worker_recovery_checkpoints (node_id, model_id, runtime_model_id, version)
    VALUES ('#{@node_id}', '#{@model_id}', 'org/model', 'main')
    """)

    assert foreign_keys(prefix) == [
             "worker_recovery_checkpoints_model_id_fkey",
             "worker_recovery_checkpoints_node_id_fkey"
           ]

    up(prefix)

    assert foreign_keys(prefix) == []
    refute "model_id" in columns(prefix)

    # All-in-one source dev writes checkpoints for a Node with no inventory row.
    Repo.query!("""
    INSERT INTO #{prefix}.worker_recovery_checkpoints (node_id, runtime_model_id, version)
    VALUES (gen_random_uuid(), 'org/other', 'main')
    """)

    Repo.query!("DELETE FROM #{prefix}.models")
    Repo.query!("DELETE FROM #{prefix}.nodes")
    assert checkpoint_count(prefix) == 2
  end

  test "SPEC.md §12.2.2 is a no-op on the current checkpoint schema and safe to rerun",
       %{prefix: prefix} do
    create_checkpoints(prefix, "node_id uuid NOT NULL,")
    before = columns(prefix)

    up(prefix)
    up(prefix)

    assert columns(prefix) == before
    assert foreign_keys(prefix) == []
  end

  defp create_checkpoints(prefix, key_columns) do
    Repo.query!("""
    CREATE TABLE #{prefix}.worker_recovery_checkpoints (
      #{key_columns}
      runtime_model_id text NOT NULL,
      version text NOT NULL,
      PRIMARY KEY (node_id, runtime_model_id, version)
    )
    """)
  end

  defp up(prefix) do
    Runner.run(Repo, Repo.config(), 0, Migration, :forward, :up, :up, prefix: prefix, log: false)
  end

  defp foreign_keys(prefix) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT conname FROM pg_constraint
        WHERE conrelid = $1::text::regclass AND contype = 'f' ORDER BY conname
        """,
        ["#{prefix}.worker_recovery_checkpoints"]
      )

    List.flatten(rows)
  end

  defp columns(prefix) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'worker_recovery_checkpoints'
        ORDER BY ordinal_position
        """,
        [prefix]
      )

    List.flatten(rows)
  end

  defp checkpoint_count(prefix) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{prefix}.worker_recovery_checkpoints")
    count
  end
end
