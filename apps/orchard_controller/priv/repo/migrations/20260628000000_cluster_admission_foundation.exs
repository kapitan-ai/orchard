defmodule Orchard.Repo.Migrations.ClusterAdmissionFoundation do
  use Ecto.Migration

  @legacy_tenant_id "00000000-0000-0000-0000-000000000000"

  def up do
    execute("""
    CREATE TYPE node_admission_decision_kind AS ENUM (
      'rejected',
      'rejection_cleared',
      'admitted'
    )
    """)

    alter table(:audit_logs) do
      add(:scope, :text, null: false, default: "tenant")
    end

    execute("ALTER TABLE audit_logs ALTER COLUMN tenant_id DROP NOT NULL")

    create(
      constraint(:audit_logs, :audit_logs_scope_tenant_consistency,
        check:
          "(scope = 'tenant' AND tenant_id IS NOT NULL) OR " <>
            "(scope = 'cluster' AND tenant_id IS NULL)"
      )
    )

    create(
      index(:audit_logs, [:occurred_at],
        name: :idx_audit_logs_cluster_occurred_at,
        where: "scope = 'cluster'"
      )
    )

    create table(:node_admission_candidates, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :nilify_all))
      add(:source, :text, null: false)
      add(:admission_category, :text, null: false)
      add(:observed_identity, :map, null: false, default: %{})
      add(:target_ref, :text)
      add(:endpoint_transport, :text)
      add(:endpoint_target, :text)
      add(:inventory, :map, null: false, default: %{})
      add(:compatibility_evidence, :map, null: false, default: %{})
      add(:last_observed_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(
      constraint(:node_admission_candidates, :node_admission_candidates_source,
        check:
          "source IN (" <>
            "'runtime_endpoint_observation', " <>
            "'provisioned_placeholder', " <>
            "'registered_node')"
      )
    )

    create(
      constraint(:node_admission_candidates, :node_admission_candidates_admission_category,
        check:
          "admission_category IN (" <>
            "'pending_observed', " <>
            "'pending_provisioned', " <>
            "'pending_registered', " <>
            "'rejected', " <>
            "'admitted')"
      )
    )

    create(
      constraint(:node_admission_candidates, :node_admission_candidates_endpoint_transport,
        check: "endpoint_transport IS NULL OR endpoint_transport IN ('grpc', 'beam', 'external')"
      )
    )

    create(
      constraint(:node_admission_candidates, :node_admission_candidates_observed_timestamp,
        check: "source <> 'runtime_endpoint_observation' OR last_observed_at IS NOT NULL"
      )
    )

    execute("""
    CREATE INDEX idx_node_admission_candidates_category_observed
    ON node_admission_candidates(admission_category, last_observed_at DESC NULLS LAST)
    """)

    create(
      index(:node_admission_candidates, [:node_id],
        name: :idx_node_admission_candidates_node,
        where: "node_id IS NOT NULL"
      )
    )

    execute("""
    CREATE INDEX idx_node_admission_candidates_open_target_ref
    ON node_admission_candidates(target_ref)
    WHERE node_id IS NULL
      AND target_ref IS NOT NULL
      AND admission_category IN ('pending_observed', 'rejected')
    """)

    execute("""
    CREATE UNIQUE INDEX idx_node_admission_candidates_open_observed_identity_unique
    ON node_admission_candidates (
      source,
      endpoint_transport,
      endpoint_target,
      ((observed_identity->>'claimed_node_id'))
    )
    WHERE source = 'runtime_endpoint_observation'
      AND admission_category IN ('pending_observed', 'rejected')
      AND endpoint_transport IS NOT NULL
      AND endpoint_target IS NOT NULL
      AND observed_identity ? 'claimed_node_id'
    """)

    create table(:node_admission_decisions, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :candidate_id,
        references(:node_admission_candidates, type: :binary_id, on_delete: :nilify_all)
      )

      add(:node_id, references(:nodes, type: :binary_id, on_delete: :nilify_all))
      add(:decision, :node_admission_decision_kind, null: false)
      add(:actor_type, :text, null: false)
      add(:actor_id, :text)
      add(:reason, :text)
      add(:observed_identity, :map, null: false, default: %{})
      add(:target_ref, :text)
      add(:audit_log_id, references(:audit_logs, type: :bigint, on_delete: :nilify_all))
      add(:metadata, :map, null: false, default: %{})
      add(:decided_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    execute("""
    CREATE INDEX idx_node_admission_decisions_candidate_decided
    ON node_admission_decisions(candidate_id, decided_at DESC)
    WHERE candidate_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX idx_node_admission_decisions_node_decided
    ON node_admission_decisions(node_id, decided_at DESC)
    WHERE node_id IS NOT NULL
    """)

    create(
      index(:node_admission_decisions, [:audit_log_id],
        name: :idx_node_admission_decisions_audit_log,
        where: "audit_log_id IS NOT NULL"
      )
    )

    execute("""
    CREATE FUNCTION orchard_reject_node_admission_decision_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'node_admission_decisions is append-only';
      END IF;

      IF pg_trigger_depth() > 1
         AND OLD.id IS NOT DISTINCT FROM NEW.id
         AND OLD.decision IS NOT DISTINCT FROM NEW.decision
         AND OLD.actor_type IS NOT DISTINCT FROM NEW.actor_type
         AND OLD.actor_id IS NOT DISTINCT FROM NEW.actor_id
         AND OLD.reason IS NOT DISTINCT FROM NEW.reason
         AND OLD.observed_identity IS NOT DISTINCT FROM NEW.observed_identity
         AND OLD.target_ref IS NOT DISTINCT FROM NEW.target_ref
         AND OLD.metadata IS NOT DISTINCT FROM NEW.metadata
         AND OLD.decided_at IS NOT DISTINCT FROM NEW.decided_at
         AND OLD.inserted_at IS NOT DISTINCT FROM NEW.inserted_at
         AND (NEW.candidate_id IS NULL OR NEW.candidate_id IS NOT DISTINCT FROM OLD.candidate_id)
         AND (NEW.node_id IS NULL OR NEW.node_id IS NOT DISTINCT FROM OLD.node_id)
         AND (NEW.audit_log_id IS NULL OR NEW.audit_log_id IS NOT DISTINCT FROM OLD.audit_log_id)
      THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'node_admission_decisions is append-only';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER node_admission_decisions_append_only
    BEFORE UPDATE OR DELETE ON node_admission_decisions
    FOR EACH ROW
    EXECUTE FUNCTION orchard_reject_node_admission_decision_mutation()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS node_admission_decisions_append_only ON node_admission_decisions"
    )

    execute("DROP FUNCTION IF EXISTS orchard_reject_node_admission_decision_mutation()")

    drop_if_exists(table(:node_admission_decisions))
    drop_if_exists(table(:node_admission_candidates))
    drop_if_exists(index(:audit_logs, [:occurred_at], name: :idx_audit_logs_cluster_occurred_at))
    drop_if_exists(constraint(:audit_logs, :audit_logs_scope_tenant_consistency))

    execute("ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_append_only")

    execute("""
    UPDATE audit_logs
    SET tenant_id = '#{@legacy_tenant_id}',
        scope = 'tenant',
        payload = COALESCE(payload, '{}'::jsonb) || '{"legacy_cluster_scope": true}'::jsonb
    WHERE scope = 'cluster'
    """)

    execute("ALTER TABLE audit_logs ENABLE TRIGGER audit_logs_append_only")

    alter table(:audit_logs) do
      remove(:scope)
    end

    execute("ALTER TABLE audit_logs ALTER COLUMN tenant_id SET NOT NULL")

    execute("DROP TYPE IF EXISTS node_admission_decision_kind")
  end
end
