defmodule Orchard.Repo.Migrations.DropLegacyWorkerRecoveryCheckpointForeignKeys do
  use Ecto.Migration

  # #444 edited 20260908000000_create_worker_recovery_checkpoints in place to
  # drop the foreign keys to `nodes` and `models` and the `model_id` column.
  # Development databases that ran an earlier revision of that branch still
  # have them, so all-in-one checkpoint writes fail (no Node row) and deleting
  # a catalog model erases checkpoints. Every step is guarded, so this is a
  # no-op on databases created from the current migration.
  def up do
    drop_if_exists(
      constraint(:worker_recovery_checkpoints, :worker_recovery_checkpoints_node_id_fkey)
    )

    drop_if_exists(
      constraint(:worker_recovery_checkpoints, :worker_recovery_checkpoints_model_id_fkey)
    )

    alter table(:worker_recovery_checkpoints) do
      remove_if_exists(:model_id, :binary_id)
    end
  end

  # The removed constraints and column are not part of the current schema, so
  # rolling back restores nothing.
  def down, do: :ok
end
