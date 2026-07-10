defmodule Orchard.Repo.Migrations.NodeEnrollmentPersistence do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      modify(:hostname, :text, null: true, from: {:text, null: false})
      modify(:advertise_addr, :text, null: true, from: {:text, null: false})
    end

    create table(:node_enrollments, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:format_version, :integer, null: false, default: 1)
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :restrict), null: false)
      add(:cluster_id, :binary_id, null: false)
      add(:expected_controller_id, :binary_id, null: false)
      add(:trust_authority_id, :binary_id, null: false)
      add(:token_prefix, :text, null: false)
      add(:token_hash, :text, null: false)
      add(:state, :text, null: false, default: "issued")
      add(:creator_type, :text, null: false)
      add(:creator_id, :text)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:output_failed_at, :utc_datetime_usec)
      add(:csr_fingerprint, :text)
      add(:resume_verifier_metadata, :map, null: false, default: %{})
      add(:certificate_issuance_outcome, :text, null: false, default: "not_started")
      add(:certificate_identifier, :text)
      add(:certificate_result, :map, null: false, default: %{})
      add(:audit_metadata, :map, null: false, default: %{})
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:node_enrollments, [:node_id]))
    create(unique_index(:node_enrollments, [:token_prefix]))
    create(unique_index(:node_enrollments, [:token_hash]))

    create(
      unique_index(:node_enrollments, [:certificate_identifier],
        where: "certificate_identifier IS NOT NULL"
      )
    )

    create(index(:node_enrollments, [:state, :expires_at]))

    create(
      constraint(:node_enrollments, :node_enrollments_format_version,
        check: "format_version = 1"
      )
    )

    create(
      constraint(:node_enrollments, :node_enrollments_state,
        check: "state IN ('issued', 'consumed', 'revoked', 'expired', 'output_failed')"
      )
    )

    create(
      constraint(:node_enrollments, :node_enrollments_certificate_issuance_outcome,
        check:
          "certificate_issuance_outcome IN ('not_started', 'pending', 'issued', 'failed')"
      )
    )

    create(
      constraint(:node_enrollments, :node_enrollments_expiry_window,
        check: "expires_at > issued_at AND expires_at <= issued_at + interval '24 hours'"
      )
    )

    create(
      constraint(:node_enrollments, :node_enrollments_lifecycle_timestamps,
        check: """
        (state = 'issued'
          AND consumed_at IS NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'consumed'
          AND consumed_at IS NOT NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'revoked'
          AND revoked_at IS NOT NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'expired'
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'output_failed'
          AND consumed_at IS NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NOT NULL)
        """
      )
    )
  end
end
