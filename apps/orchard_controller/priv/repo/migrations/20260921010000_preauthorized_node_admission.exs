defmodule Orchard.Repo.Migrations.PreauthorizedNodeAdmission do
  use Ecto.Migration

  def up do
    create table(:node_admission_modes, primary_key: false) do
      add(:singleton, :boolean, primary_key: true, default: true)
      add(:mode, :text, null: false, default: "manual")
      add(:version, :bigint, null: false, default: 1)
      add(:changed_by_actor_type, :text)
      add(:changed_by_actor_id, :text)
      add(:changed_at, :utc_datetime_usec)
      add(:change_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:node_admission_modes, :node_admission_modes_singleton,
        check: "singleton = true"
      )
    )

    create(
      constraint(:node_admission_modes, :node_admission_modes_mode,
        check: "mode IN ('manual', 'enrollment_preauthorized')"
      )
    )

    create(
      constraint(:node_admission_modes, :node_admission_modes_version,
        check: "version > 0"
      )
    )

    execute("""
    INSERT INTO node_admission_modes (
      singleton, mode, version, inserted_at, updated_at
    )
    VALUES (true, 'manual', 1, clock_timestamp(), clock_timestamp())
    """)

    create table(:node_admission_preauthorizations, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:contract_version, :integer, null: false, default: 1)
      add(:cluster_id, :binary_id, null: false)

      add(:enrollment_id, references(:node_enrollments, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:node_id, references(:nodes, type: :binary_id, on_delete: :restrict), null: false)

      add(
        :issuing_controller_id,
        references(:controller_instances, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:issuing_actor_type, :text, null: false)
      add(:issuing_actor_id, :text, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:state, :text, null: false, default: "authorized")
      add(:pool_id, :text, null: false)
      add(:pool_revision, :text, null: false)
      add(:routing_policy_id, :text, null: false)
      add(:routing_policy_revision, :text, null: false)
      add(:controller_dispatch_ceiling, :integer, null: false)
      add(:capacity_policy_reason, :text, null: false)
      add(:dispatch_capacity_phase, :text, null: false)
      add(:dispatch_capacity_revision, :bigint, null: false)
      add(:admission_mode_revision, :bigint, null: false)
      add(:bound_predicates, :map, null: false, default: %{})
      add(:preview_digest, :text, null: false)
      add(:confirmation_evidence, :map, null: false, default: %{})
      add(:issuance_audit_log_id, references(:audit_logs, type: :bigint), null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:outcome_reason, :text)
      add(:executing_controller_id, :binary_id)
      add(:redemption_csr_fingerprint, :text)
      add(:terminal_audit_log_id, references(:audit_logs, type: :bigint))
      add(:pending_review_audit_log_id, references(:audit_logs, type: :bigint))
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:node_admission_preauthorizations, [:enrollment_id]))
    create(unique_index(:node_admission_preauthorizations, [:node_id]))
    create(index(:node_admission_preauthorizations, [:state, :expires_at]))

    create(
      constraint(
        :node_admission_preauthorizations,
        :node_admission_preauthorizations_contract_version,
        check: "contract_version = 1"
      )
    )

    create(
      constraint(:node_admission_preauthorizations, :node_admission_preauthorizations_state,
        check:
          "state IN ('authorized', 'consumed_admitted', 'consumed_pending_review', 'revoked', 'expired')"
      )
    )

    create(
      constraint(
        :node_admission_preauthorizations,
        :node_admission_preauthorizations_values,
        check:
          "controller_dispatch_ceiling >= 0 AND dispatch_capacity_revision > 0 AND " <>
            "admission_mode_revision > 0 AND expires_at > issued_at"
      )
    )

    create(
      constraint(
        :node_admission_preauthorizations,
        :node_admission_preauthorizations_terminal_evidence,
        check: """
        (state = 'authorized'
          AND consumed_at IS NULL
          AND outcome_reason IS NULL
          AND executing_controller_id IS NULL
          AND redemption_csr_fingerprint IS NULL
          AND terminal_audit_log_id IS NULL
          AND pending_review_audit_log_id IS NULL)
        OR
        (state IN ('consumed_admitted', 'consumed_pending_review')
          AND consumed_at IS NOT NULL
          AND outcome_reason IS NOT NULL
          AND executing_controller_id IS NOT NULL
          AND redemption_csr_fingerprint IS NOT NULL
          AND terminal_audit_log_id IS NOT NULL
          AND pending_review_audit_log_id IS NULL)
        OR
        (state IN ('revoked', 'expired')
          AND consumed_at IS NULL
          AND outcome_reason IS NOT NULL
          AND terminal_audit_log_id IS NOT NULL
          AND (
            (executing_controller_id IS NULL
              AND redemption_csr_fingerprint IS NULL
              AND pending_review_audit_log_id IS NULL)
            OR
            (executing_controller_id IS NOT NULL
              AND redemption_csr_fingerprint IS NOT NULL
              AND pending_review_audit_log_id IS NOT NULL)
          ))
        """
      )
    )
  end

  def down do
    drop(table(:node_admission_preauthorizations))
    drop(table(:node_admission_modes))
  end
end
