defmodule Orchard.Repo.Migrations.CreateWorkerRecoveryCheckpoints do
  use Ecto.Migration

  def change do
    create table(:worker_recovery_checkpoints, primary_key: false) do
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :restrict), primary_key: true)
      add(:runtime_model_id, :text, primary_key: true)
      add(:version, :text, primary_key: true)
      add(:model_id, references(:models, type: :binary_id, on_delete: :restrict), null: false)
      add(:epoch, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:transition_id, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:record, :map, null: false)
      timestamps(type: :utc_datetime_usec)
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
