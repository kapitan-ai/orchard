defmodule Orchard.Repo.Migrations.M2A1AGovernanceDbFoundation do
  use Ecto.Migration

  @legacy_tenant_id "00000000-0000-0000-0000-000000000000"
  @legacy_tenant_slug "legacy"
  @legacy_tenant_name "Legacy Single Tenant"

  def up do
    create table(:tenants, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:slug, :text, null: false)
      add(:name, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:tenants, [:slug]))

    execute("""
    INSERT INTO tenants (id, slug, name, inserted_at, updated_at)
    VALUES ('#{@legacy_tenant_id}', '#{@legacy_tenant_slug}', '#{@legacy_tenant_name}', NOW(), NOW())
    ON CONFLICT (id) DO UPDATE
    SET slug = EXCLUDED.slug,
        name = EXCLUDED.name,
        updated_at = NOW()
    """)

    create table(:api_keys, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:tenant_id, references(:tenants, type: :binary_id), null: false)
      add(:name, :text, null: false)
      add(:token_prefix, :text, null: false)
      add(:secret_hash, :text, null: false)
      add(:last_used_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:api_keys, [:token_prefix]))
    create(index(:api_keys, [:tenant_id, :inserted_at]))

    create table(:audit_logs, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id), null: false)
      add(:api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all))
      add(:actor_type, :text, null: false)
      add(:actor_id, :text)
      add(:action, :text, null: false)
      add(:target_type, :text, null: false)
      add(:target_id, :text)
      add(:occurred_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:payload, :map, null: false, default: %{})
    end

    create(index(:audit_logs, [:tenant_id, :occurred_at]))

    execute("""
    CREATE FUNCTION orchard_reject_audit_log_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'audit_logs is append-only';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER audit_logs_append_only
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW
    EXECUTE FUNCTION orchard_reject_audit_log_mutation()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS audit_logs_append_only ON audit_logs")
    execute("DROP FUNCTION IF EXISTS orchard_reject_audit_log_mutation()")

    drop_if_exists(table(:audit_logs))
    drop_if_exists(table(:api_keys))
    drop_if_exists(table(:tenants))
  end
end
