defmodule Orchard.Repo.Migrations.CreateWorkerRecoveryCheckpoints do
  use Ecto.Migration

  def change do
    create table(:worker_recovery_checkpoints, primary_key: false) do
      # No foreign key: all-in-one source development keeps checkpoints for its
      # in-process Node Agent, which has no Node inventory row.
      add(:node_id, :binary_id, primary_key: true)

      add(:runtime_model_id, :text, primary_key: true)
      add(:version, :text, primary_key: true)
      add(:model_id, references(:models, type: :binary_id, on_delete: :delete_all), null: false)
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
