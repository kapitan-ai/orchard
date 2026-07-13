defmodule Orchard.Repo.Migrations.BeamPeerGrantFoundation do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TYPE beam_peer_grant_state AS ENUM (
      'pending_delivery',
      'staged',
      'active',
      'superseded',
      'revoked',
      'expired',
      'delivery_failed'
    )
    """)

    alter table(:nodes) do
      add(:canonical_beam_name, :text)
    end

    create table(:controller_instances, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:certificate_uri_san, :text, null: false)
      add(:certificate_identifier, :text, null: false)
      add(:certificate_fingerprint_sha256, :text, null: false)
      add(:canonical_beam_name, :text, null: false)
      add(:beam_authorization_root_id, :uuid, null: false)
      add(:authorization_root_custody_ref, :text, null: false)
      add(:status, :text, null: false)
      add(:first_enrolled_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:controller_instances, [:certificate_uri_san]))
    create(unique_index(:controller_instances, [:canonical_beam_name]))
    create(unique_index(:controller_instances, [:beam_authorization_root_id]))

    create(
      constraint(:controller_instances, :controller_instances_status,
        check: "status IN ('enrolled', 'operational', 'recovery_required', 'retired')"
      )
    )

    create table(:beam_peer_grants, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:generation, :bigint, null: false)
      add(:cluster_id, :uuid, null: false)

      add(
        :controller_id,
        references(:controller_instances, type: :uuid),
        null: false
      )

      add(:controller_beam_name, :text, null: false)
      add(:controller_certificate_identifier, :text, null: false)
      add(:controller_certificate_fingerprint_sha256, :text, null: false)
      add(:beam_authorization_root_id, :uuid, null: false)
      add(:node_id, references(:nodes, type: :uuid), null: false)
      add(:node_beam_name, :text, null: false)
      add(:node_certificate_identifier, :text, null: false)
      add(:node_certificate_fingerprint_sha256, :text, null: false)
      add(:contract_version, :integer, null: false)
      add(:purpose, :text, null: false)
      add(:state, :beam_peer_grant_state, null: false, default: "pending_delivery")
      add(:secret_hash, :binary, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:not_before_at, :utc_datetime_usec, null: false)
      add(:cutover_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:delivery_evidence, :map, null: false, default: %{})
      add(:activation_evidence, :map, null: false, default: %{})
      add(:supersession_evidence, :map, null: false, default: %{})
      add(:failure_evidence, :map, null: false, default: %{})
      add(:revocation_evidence, :map, null: false, default: %{})
      add(:delivered_at, :utc_datetime_usec)
      add(:activated_at, :utc_datetime_usec)
      add(:superseded_at, :utc_datetime_usec)
      add(:failed_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :beam_peer_grants,
        [:cluster_id, :controller_id, :node_id, :purpose, :generation],
        name: :beam_peer_grants_pair_generation
      )
    )

    create(
      unique_index(
        :beam_peer_grants,
        [:cluster_id, :controller_id, :node_id, :purpose],
        where: "state = 'active'",
        name: :beam_peer_grants_one_active
      )
    )

    create(
      unique_index(
        :beam_peer_grants,
        [:cluster_id, :controller_id, :node_id, :purpose],
        where: "state = 'staged'",
        name: :beam_peer_grants_one_staged
      )
    )

    create(constraint(:beam_peer_grants, :beam_peer_grants_generation, check: "generation > 0"))

    create(
      constraint(:beam_peer_grants, :beam_peer_grants_contract_version,
        check: "contract_version > 0"
      )
    )

    create(
      constraint(:beam_peer_grants, :beam_peer_grants_secret_hash,
        check: "octet_length(secret_hash) = 32"
      )
    )

    create(
      constraint(:beam_peer_grants, :beam_peer_grants_validity,
        check: "expires_at > not_before_at"
      )
    )

    create(
      constraint(:beam_peer_grants, :beam_peer_grants_cutover,
        check:
          "cutover_at IS NULL OR (cutover_at >= not_before_at AND cutover_at <= expires_at)"
      )
    )
  end

  def down do
    drop(table(:beam_peer_grants))
    drop(table(:controller_instances))

    alter table(:nodes) do
      remove(:canonical_beam_name)
    end

    execute("DROP TYPE beam_peer_grant_state")
  end
end
