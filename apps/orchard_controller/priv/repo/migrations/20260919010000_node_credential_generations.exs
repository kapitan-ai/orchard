defmodule Orchard.Repo.Migrations.NodeCredentialGenerations do
  use Ecto.Migration

  def change do
    create table(:node_credential_generations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:node_id, references(:nodes, type: :uuid), null: false)
      add(:enrollment_id, references(:node_enrollments, type: :uuid), null: false)
      add(:generation, :bigint, null: false)
      add(:state, :text, null: false)
      add(:cluster_id, :uuid, null: false)
      add(:controller_id, :uuid, null: false)
      add(:trust_authority_id, :uuid, null: false)
      add(:certificate_identifier, :text, null: false)
      add(:certificate_fingerprint_sha256, :text, null: false)
      add(:csr_fingerprint_sha256, :text, null: false)
      add(:public_key_fingerprint_sha256, :text, null: false)
      add(:certificate_result, :map, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:not_before_at, :utc_datetime_usec, null: false)
      add(:not_after_at, :utc_datetime_usec, null: false)
      add(:renew_after_at, :utc_datetime_usec, null: false)
      add(:staged_at, :utc_datetime_usec)
      add(:overlap_ends_at, :utc_datetime_usec)
      add(:activated_at, :utc_datetime_usec)
      add(:superseded_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:transition_evidence, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
    INSERT INTO node_credential_generations (
      id, node_id, enrollment_id, generation, state, cluster_id, controller_id,
      trust_authority_id, certificate_identifier, certificate_fingerprint_sha256,
      csr_fingerprint_sha256, public_key_fingerprint_sha256, certificate_result,
      issued_at, not_before_at, not_after_at, renew_after_at, activated_at,
      transition_evidence, inserted_at, updated_at
    )
    SELECT
      gen_random_uuid(), enrollment.node_id, enrollment.id, 1, 'current',
      enrollment.cluster_id, enrollment.expected_controller_id,
      enrollment.trust_authority_id, enrollment.certificate_identifier,
      'sha256-' || rtrim(
        translate(
          encode(
            digest(
              decode(
                regexp_replace(
                  enrollment.certificate_result->>'node_certificate_pem',
                  '-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\\s',
                  '',
                  'g'
                ),
                'base64'
              ),
              'sha256'
            ),
            'base64'
          ),
          '+/',
          '-_'
        ),
        '='
      ),
      enrollment.csr_fingerprint,
      enrollment.resume_verifier_metadata->>'public_key_fingerprint',
      enrollment.certificate_result,
      enrollment.consumed_at,
      enrollment.consumed_at - interval '60 seconds',
      (enrollment.certificate_result->>'not_after')::timestamptz,
      (enrollment.certificate_result->>'not_after')::timestamptz - interval '30 days',
      enrollment.consumed_at,
      jsonb_build_object('source', 'verified_enrollment_backfill'),
      enrollment.inserted_at,
      clock_timestamp()
    FROM node_enrollments AS enrollment
    WHERE enrollment.state = 'consumed'
      AND enrollment.certificate_issuance_outcome = 'issued'
      AND enrollment.certificate_identifier IS NOT NULL
      AND enrollment.csr_fingerprint IS NOT NULL
      AND enrollment.resume_verifier_metadata->>'public_key_fingerprint' IS NOT NULL
      AND enrollment.certificate_result->>'node_certificate_pem' IS NOT NULL
      AND enrollment.certificate_result->>'not_after' IS NOT NULL
      AND enrollment.consumed_at IS NOT NULL
      """,
      """
      DELETE FROM node_credential_generations
      WHERE transition_evidence->>'source' = 'verified_enrollment_backfill'
      """
    )

    create(index(:node_credential_generations, [:node_id]))

    create(
      unique_index(:node_credential_generations, [:node_id, :generation],
        name: :node_credential_generations_node_generation
      )
    )

    create(
      unique_index(:node_credential_generations, [:certificate_identifier],
        name: :node_credential_generations_certificate_identifier
      )
    )

    create(
      unique_index(:node_credential_generations, [:node_id],
        where: "state = 'current'",
        name: :node_credential_generations_one_current
      )
    )

    create(
      unique_index(:node_credential_generations, [:node_id],
        where: "state = 'staged'",
        name: :node_credential_generations_one_staged
      )
    )

    create(
      constraint(:node_credential_generations, :node_credential_generations_generation,
        check: "generation > 0"
      )
    )

    create(
      constraint(:node_credential_generations, :node_credential_generations_state,
        check: "state IN ('current', 'staged', 'superseded', 'revoked')"
      )
    )

    create(
      constraint(:node_credential_generations, :node_credential_generations_validity,
        check:
          "not_before_at < renew_after_at AND renew_after_at < not_after_at AND (overlap_ends_at IS NULL OR overlap_ends_at <= not_after_at)"
      )
    )
  end
end
