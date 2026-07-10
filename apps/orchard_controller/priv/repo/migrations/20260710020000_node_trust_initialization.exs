defmodule Orchard.Repo.Migrations.NodeTrustInitialization do
  use Ecto.Migration

  def change do
    create table(:cluster_identities, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:singleton, :boolean, null: false, default: true)
      add(:name, :text)
      add(:runtime_controller_id, :binary_id, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:cluster_identities, [:singleton]))
    create(unique_index(:cluster_identities, [:runtime_controller_id]))

    create(
      constraint(:cluster_identities, :cluster_identities_singleton, check: "singleton = true")
    )

    create table(:node_trust_authorities, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :cluster_id,
        references(:cluster_identities, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:state, :text, null: false, default: "active")
      add(:material_generation, :binary_id, null: false)
      add(:ca_certificate_pem, :text, null: false)
      add(:ca_certificate_fingerprint, :text, null: false)
      add(:ca_spki_fingerprint, :text, null: false)
      add(:controller_certificate_pem, :text, null: false)
      add(:controller_certificate_fingerprint, :text, null: false)
      add(:controller_uri_san, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:node_trust_authorities, [:material_generation]))
    create(unique_index(:node_trust_authorities, [:ca_certificate_fingerprint]))
    create(unique_index(:node_trust_authorities, [:ca_spki_fingerprint]))
    create(unique_index(:node_trust_authorities, [:controller_certificate_fingerprint]))

    create(
      unique_index(:node_trust_authorities, [:cluster_id],
        name: :idx_node_trust_authorities_one_active_per_cluster,
        where: "state = 'active'"
      )
    )

    create(
      constraint(:node_trust_authorities, :node_trust_authorities_state,
        check: "state IN ('active', 'retired')"
      )
    )
  end
end
