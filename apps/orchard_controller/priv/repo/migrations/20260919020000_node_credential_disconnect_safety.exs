defmodule Orchard.Repo.Migrations.NodeCredentialDisconnectSafety do
  use Ecto.Migration

  def change do
    alter table(:beam_peer_grants) do
      add(:node_staged_at, :utc_datetime_usec)
      add(:node_staging_evidence, :map, null: false, default: %{})
    end

    create table(:beam_disconnect_obligations, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:node_id, references(:nodes, type: :uuid), null: false)
      add(:grant_id, references(:beam_peer_grants, type: :uuid))
      add(:credential_generation_id, references(:node_credential_generations, type: :uuid))
      add(:peer_beam_name, :text, null: false)
      add(:reason, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:due_at, :utc_datetime_usec, null: false)
      add(:last_attempt_at, :utc_datetime_usec)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:completed_at, :utc_datetime_usec)
      add(:evidence, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:beam_disconnect_obligations, [:state, :due_at]))
    create(index(:beam_disconnect_obligations, [:node_id]))

    create(
      unique_index(
        :beam_disconnect_obligations,
        [:node_id, :grant_id, :reason],
        where: "state IN ('pending', 'attempted')",
        name: :beam_disconnect_obligations_one_open_reason
      )
    )

    create(
      constraint(:beam_disconnect_obligations, :beam_disconnect_obligations_state,
        check: "state IN ('pending', 'attempted', 'completed')"
      )
    )

    create(
      constraint(:beam_disconnect_obligations, :beam_disconnect_obligations_attempt_count,
        check: "attempt_count >= 0"
      )
    )
  end
end
