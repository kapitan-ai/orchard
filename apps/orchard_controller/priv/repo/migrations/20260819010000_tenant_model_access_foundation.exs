defmodule Orchard.Repo.Migrations.TenantModelAccessFoundation do
  use Ecto.Migration

  def up do
    create table(:routing_policies, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing))
      add(:name, :text, null: false)
      add(:allowed_pool_ids, {:array, :binary_id}, null: false, default: fragment("'{}'::uuid[]"))

      add(:preferred_pool_ids, {:array, :binary_id},
        null: false,
        default: fragment("'{}'::uuid[]")
      )

      add(:residency_preference, :text, null: false)
      add(:max_cold_start_ms, :integer, null: false, default: 15_000)
      add(:max_queue_wait_ms, :integer, null: false, default: 3_000)
      add(:priority, :integer, null: false, default: 100)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(
      unique_index(:routing_policies, [:tenant_id, :name],
        where: "tenant_id IS NOT NULL",
        name: :idx_routing_policies_tenant_name
      )
    )

    create(
      unique_index(:routing_policies, [:name],
        where: "tenant_id IS NULL",
        name: :idx_routing_policies_global_name
      )
    )

    create(
      constraint(:routing_policies, :routing_policies_name_not_blank,
        check: "length(btrim(name)) > 0"
      )
    )

    create(
      constraint(:routing_policies, :routing_policies_residency_preference_closed,
        check:
          "residency_preference IN ('required_loaded', 'prefer_loaded', 'allow_cold_load')"
      )
    )

    create(
      constraint(:routing_policies, :routing_policies_budgets_non_negative,
        check: "max_cold_start_ms >= 0 AND max_queue_wait_ms >= 0 AND priority >= 0"
      )
    )

    create(
      constraint(:routing_policies, :routing_policies_pool_constraints_deferred,
        check: "cardinality(allowed_pool_ids) = 0 AND cardinality(preferred_pool_ids) = 0"
      )
    )

    execute("""
    CREATE FUNCTION orchard_reject_routing_policy_tenant_change()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          CONSTRAINT = 'routing_policies_tenant_immutable',
          MESSAGE = 'routing policy tenant scope is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER routing_policies_tenant_immutable
    BEFORE UPDATE OF tenant_id ON routing_policies
    FOR EACH ROW
    EXECUTE FUNCTION orchard_reject_routing_policy_tenant_change()
    """)

    create table(:tenant_model_access, primary_key: false) do
      add(:tenant_id,
        references(:tenants, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:model_id,
        references(:models, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:enabled, :boolean, null: false, default: true)

      add(:routing_policy_id,
        references(:routing_policies, type: :binary_id, on_delete: :nothing)
      )

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(index(:tenant_model_access, [:tenant_id, :enabled]))
    create(index(:tenant_model_access, [:model_id]))
    create(index(:tenant_model_access, [:routing_policy_id]))

    execute("""
    CREATE FUNCTION orchard_enforce_tenant_model_access_policy_scope()
    RETURNS trigger AS $$
    DECLARE
      policy_tenant_id uuid;
    BEGIN
      IF NEW.routing_policy_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT tenant_id
      INTO policy_tenant_id
      FROM routing_policies
      WHERE id = NEW.routing_policy_id
      FOR KEY SHARE;

      IF FOUND AND policy_tenant_id IS NOT NULL AND policy_tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          CONSTRAINT = 'tenant_model_access_routing_policy_scope',
          MESSAGE = 'routing policy must be global or owned by the access tenant';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER tenant_model_access_routing_policy_scope
    BEFORE INSERT OR UPDATE OF tenant_id, routing_policy_id ON tenant_model_access
    FOR EACH ROW
    EXECUTE FUNCTION orchard_enforce_tenant_model_access_policy_scope()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS tenant_model_access_routing_policy_scope ON tenant_model_access"
    )

    execute("DROP FUNCTION IF EXISTS orchard_enforce_tenant_model_access_policy_scope()")
    drop(table(:tenant_model_access))

    execute("DROP TRIGGER IF EXISTS routing_policies_tenant_immutable ON routing_policies")
    execute("DROP FUNCTION IF EXISTS orchard_reject_routing_policy_tenant_change()")
    drop(table(:routing_policies))
  end
end
