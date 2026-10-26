defmodule Orchard.Repo.Migrations.CreateWorkerRecoveryCheckpoints do
  use Ecto.Migration

  def change do
    create table(:worker_recovery_checkpoints, primary_key: false) do
      # No foreign keys. All-in-one source development keeps checkpoints for its
      # in-process Node Agent, which has no Node inventory row, and deleting a
      # catalog model must not erase an open or unresolved placement's state.
      add(:node_id, :binary_id, primary_key: true)

      add(:runtime_model_id, :text, primary_key: true)
      add(:version, :text, primary_key: true)
      add(:epoch, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:transition_id, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:record, :map, null: false)
      # SPEC.md §8.2 stores every Controller timestamp as timestamptz.
      timestamps(type: :timestamptz)
    end

    create(
      constraint(:worker_recovery_checkpoints, :worker_recovery_revision_positive,
        check: "revision > 0"
      )
    )

    create(
      constraint(:worker_recovery_checkpoints, :worker_recovery_record_bounded,
        check: "octet_length(record::text) <= 4096"
      )
    )
  end
end
