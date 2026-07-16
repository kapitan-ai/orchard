defmodule Orchard.Repo.Migrations.DispatchCapacityFoundation do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TYPE node_dispatch_capacity_policy_state AS ENUM (
      'shadow_legacy',
      'approved_explicit',
      'enforcing'
    )
    """)

    execute("""
    CREATE TYPE dispatch_capacity_enforcement_phase AS ENUM (
      'pre_cutover',
      'enforcing'
    )
    """)

    execute("LOCK TABLE nodes, node_admission_decisions IN SHARE ROW EXCLUSIVE MODE")

    create table(:dispatch_capacity_authority, primary_key: false) do
      add(:singleton, :boolean, primary_key: true, default: true)

      add(:enforcement_phase, :dispatch_capacity_enforcement_phase,
        null: false,
        default: "pre_cutover"
      )

      add(:required_contract_version, :integer, null: false, default: 1)
      add(:cutover_by_actor_type, :text)
      add(:cutover_by_actor_id, :text)
      add(:cutover_at, :utc_datetime_usec)
      add(:cutover_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:dispatch_capacity_authority, :dispatch_capacity_authority_singleton,
        check: "singleton = true"
      )
    )

    create(
      constraint(
        :dispatch_capacity_authority,
        :dispatch_capacity_authority_required_contract_version,
        check: "required_contract_version > 0"
      )
    )

    create(
      constraint(:dispatch_capacity_authority, :dispatch_capacity_authority_phase_provenance,
        check: authority_phase_provenance_check()
      )
    )

    create table(:node_dispatch_capacity_policies, primary_key: false) do
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(
        :admission_decision_id,
        references(:node_admission_decisions, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:policy_state, :node_dispatch_capacity_policy_state, null: false)
      add(:controller_dispatch_ceiling, :integer)
      add(:approved_by_actor_type, :text)
      add(:approved_by_actor_id, :text)
      add(:approved_at, :utc_datetime_usec)
      add(:approval_reason, :text)
      add(:legacy_admitted_at, :utc_datetime_usec)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:node_dispatch_capacity_policies, [:admission_decision_id]))

    create(
      constraint(:node_dispatch_capacity_policies, :node_dispatch_capacity_policies_version,
        check: "version > 0"
      )
    )

    create(
      constraint(
        :node_dispatch_capacity_policies,
        :node_dispatch_capacity_policies_state_provenance,
        check: policy_state_provenance_check()
      )
    )

    execute("""
    CREATE FUNCTION orchard_validate_dispatch_capacity_policy_admission()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM node_admission_decisions
        WHERE id = NEW.admission_decision_id
          AND node_id = NEW.node_id
          AND decision = 'admitted'
      ) THEN
        RAISE EXCEPTION 'dispatch-capacity policy requires the same Node admitted decision'
          USING ERRCODE = 'foreign_key_violation',
                CONSTRAINT = 'node_dispatch_capacity_policies_admitted_decision';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER node_dispatch_capacity_policies_validate_admission
    BEFORE INSERT OR UPDATE OF node_id, admission_decision_id
    ON node_dispatch_capacity_policies
    FOR EACH ROW
    EXECUTE FUNCTION orchard_validate_dispatch_capacity_policy_admission()
    """)

    create table(:node_runtime_capacity_evidence, primary_key: false) do
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:runtime_concurrency_limit, :integer)
      add(:active_request_count, :integer)
      add(:validity, :text, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:node_runtime_capacity_evidence, :node_runtime_capacity_evidence_validity,
        check: "validity IN ('valid', 'missing', 'invalid')"
      )
    )

    create(
      constraint(
        :node_runtime_capacity_evidence,
        :node_runtime_capacity_evidence_value_validity,
        check: evidence_value_validity_check()
      )
    )

    create(index(:node_runtime_capacity_evidence, [:observed_at]))

    alter table(:controller_instances) do
      add(:software_version, :text)
      add(:dispatch_capacity_contract_version, :integer)
      add(:dispatch_capacity_consumers_ready, :boolean)
      add(:dispatch_capacity_capability_observed_at, :utc_datetime_usec)
    end

    create(
      constraint(
        :controller_instances,
        :controller_instances_dispatch_contract_version_positive,
        check:
          "dispatch_capacity_contract_version IS NULL OR " <>
            "dispatch_capacity_contract_version > 0"
      )
    )

    execute("""
    INSERT INTO dispatch_capacity_authority (
      singleton,
      enforcement_phase,
      required_contract_version,
      inserted_at,
      updated_at
    )
    VALUES (true, 'pre_cutover', 1, clock_timestamp(), clock_timestamp())
    """)

    execute(backfill_sql())

    execute("""
    CREATE FUNCTION orchard_require_dispatch_capacity_policy_for_admission()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.decision = 'admitted' AND NOT EXISTS (
        SELECT 1
        FROM node_dispatch_capacity_policies
        WHERE node_id = NEW.node_id
          AND admission_decision_id = NEW.id
          AND policy_state IN ('approved_explicit', 'enforcing')
      ) THEN
        RAISE EXCEPTION 'new Node Admission requires an explicit dispatch-capacity policy'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'node_admission_decisions_dispatch_capacity_policy';
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER node_admission_decisions_require_dispatch_capacity_policy
    AFTER INSERT ON node_admission_decisions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION orchard_require_dispatch_capacity_policy_for_admission()
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM dispatch_capacity_authority
        WHERE enforcement_phase <> 'pre_cutover'
           OR cutover_by_actor_type IS NOT NULL
           OR cutover_by_actor_id IS NOT NULL
           OR cutover_at IS NOT NULL
           OR cutover_reason IS NOT NULL
      ) OR EXISTS (
        SELECT 1
        FROM node_dispatch_capacity_policies
        WHERE policy_state <> 'shadow_legacy'
      ) OR EXISTS (
        SELECT 1 FROM node_runtime_capacity_evidence
      ) OR EXISTS (
        SELECT 1
        FROM controller_instances
        WHERE software_version IS NOT NULL
           OR dispatch_capacity_contract_version IS NOT NULL
           OR dispatch_capacity_consumers_ready IS NOT NULL
           OR dispatch_capacity_capability_observed_at IS NOT NULL
      ) THEN
        RAISE EXCEPTION
          'dispatch-capacity foundation rollback requires an explicit export and recovery plan';
      END IF;
    END;
    $$
    """)

    alter table(:controller_instances) do
      remove(:dispatch_capacity_capability_observed_at)
      remove(:dispatch_capacity_consumers_ready)
      remove(:dispatch_capacity_contract_version)
      remove(:software_version)
    end

    execute(
      "DROP TRIGGER IF EXISTS node_admission_decisions_require_dispatch_capacity_policy " <>
        "ON node_admission_decisions"
    )

    execute("DROP FUNCTION IF EXISTS orchard_require_dispatch_capacity_policy_for_admission()")
    drop(table(:node_runtime_capacity_evidence))

    execute(
      "DROP TRIGGER IF EXISTS node_dispatch_capacity_policies_validate_admission " <>
        "ON node_dispatch_capacity_policies"
    )

    execute("DROP FUNCTION IF EXISTS orchard_validate_dispatch_capacity_policy_admission()")
    drop(table(:node_dispatch_capacity_policies))
    drop(table(:dispatch_capacity_authority))
    execute("DROP TYPE dispatch_capacity_enforcement_phase")
    execute("DROP TYPE node_dispatch_capacity_policy_state")
  end

  @doc false
  def backfill_sql do
    """
    INSERT INTO node_dispatch_capacity_policies (
      node_id,
      admission_decision_id,
      policy_state,
      controller_dispatch_ceiling,
      legacy_admitted_at,
      version,
      inserted_at,
      updated_at
    )
    SELECT DISTINCT ON (nodes.id)
      nodes.id,
      decisions.id,
      'shadow_legacy',
      NULL,
      decisions.decided_at,
      1,
      NOW(),
      NOW()
    FROM nodes
    JOIN node_admission_decisions AS decisions
      ON decisions.node_id = nodes.id
     AND decisions.decision = 'admitted'
    WHERE nodes.state <> 'removed'
    ORDER BY nodes.id, decisions.decided_at DESC, decisions.id DESC
    ON CONFLICT (node_id) DO NOTHING
    """
  end

  defp authority_phase_provenance_check do
    """
    (enforcement_phase = 'pre_cutover'
      AND cutover_by_actor_type IS NULL
      AND cutover_by_actor_id IS NULL
      AND cutover_at IS NULL
      AND cutover_reason IS NULL)
    OR
    (enforcement_phase = 'enforcing'
      AND cutover_by_actor_type IS NOT NULL
      AND cutover_by_actor_id IS NOT NULL
      AND cutover_at IS NOT NULL
      AND NULLIF(BTRIM(cutover_reason), '') IS NOT NULL)
    """
  end

  defp policy_state_provenance_check do
    """
    (policy_state = 'shadow_legacy'
      AND controller_dispatch_ceiling IS NULL
      AND approved_by_actor_type IS NULL
      AND approved_by_actor_id IS NULL
      AND approved_at IS NULL
      AND approval_reason IS NULL
      AND legacy_admitted_at IS NOT NULL)
    OR
    (policy_state IN ('approved_explicit', 'enforcing')
      AND controller_dispatch_ceiling IS NOT NULL
      AND controller_dispatch_ceiling >= 0
      AND approved_by_actor_type IS NOT NULL
      AND approved_by_actor_id IS NOT NULL
      AND approved_at IS NOT NULL
      AND NULLIF(BTRIM(approval_reason), '') IS NOT NULL
      AND legacy_admitted_at IS NULL)
    """
  end

  defp evidence_value_validity_check do
    """
    (validity = 'valid'
      AND runtime_concurrency_limit > 0
      AND active_request_count >= 0)
    OR
    (validity = 'missing'
      AND (runtime_concurrency_limit IS NULL OR runtime_concurrency_limit > 0)
      AND (active_request_count IS NULL OR active_request_count >= 0)
      AND (runtime_concurrency_limit IS NULL OR active_request_count IS NULL))
    OR
    validity = 'invalid'
    """
  end
end
