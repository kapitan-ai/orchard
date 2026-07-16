defmodule Orchard.Repo.Migrations.GovernanceDbFoundationTest do
  @moduledoc """
  Regression test for the `20260320010000_m2a_1a_governance_db_foundation`
  migration.

  Executes the migration's DDL directly through raw SQL inside the sandboxed
  test transaction so we can verify `up -> down -> up` safety without using
  `Ecto.Migrator`.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "recreates governance tables and the legacy sentinel tenant across down/up" do
    run_down_sql()
    refute table_exists?("tenants")
    refute table_exists?("api_keys")
    refute table_exists?("audit_logs")

    run_up_sql()

    assert table_exists?("tenants")
    assert table_exists?("api_keys")
    assert table_exists?("audit_logs")

    assert fetch_legacy_tenant_rows() == [
             [
               Governance.legacy_tenant_id(),
               Governance.legacy_tenant_slug(),
               Governance.legacy_tenant_name()
             ]
           ]

    run_down_sql()

    refute table_exists?("tenants")
    refute table_exists?("api_keys")
    refute table_exists?("audit_logs")

    run_up_sql()

    assert fetch_legacy_tenant_rows() == [
             [
               Governance.legacy_tenant_id(),
               Governance.legacy_tenant_slug(),
               Governance.legacy_tenant_name()
             ]
           ]
  end

  defp run_up_sql do
    Repo.query!("""
    CREATE TABLE tenants (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      slug text NOT NULL,
      name text NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT NOW(),
      updated_at timestamp(6) without time zone NOT NULL DEFAULT NOW()
    )
    """)

    Repo.query!("CREATE UNIQUE INDEX tenants_slug_index ON tenants (slug)")

    Repo.query!("""
    INSERT INTO tenants (id, slug, name, inserted_at, updated_at)
    VALUES ('#{Governance.legacy_tenant_id()}', '#{Governance.legacy_tenant_slug()}', '#{Governance.legacy_tenant_name()}', NOW(), NOW())
    ON CONFLICT (id) DO UPDATE
    SET slug = EXCLUDED.slug,
        name = EXCLUDED.name,
        updated_at = NOW()
    """)

    Repo.query!("""
    CREATE TABLE api_keys (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id uuid NOT NULL REFERENCES tenants(id),
      name text NOT NULL,
      token_prefix text NOT NULL,
      secret_hash text NOT NULL,
      last_used_at timestamp(6) without time zone,
      revoked_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT NOW(),
      updated_at timestamp(6) without time zone NOT NULL DEFAULT NOW()
    )
    """)

    Repo.query!("CREATE UNIQUE INDEX api_keys_token_prefix_index ON api_keys (token_prefix)")

    Repo.query!(
      "CREATE INDEX api_keys_tenant_id_inserted_at_index ON api_keys (tenant_id, inserted_at)"
    )

    Repo.query!("""
    CREATE TABLE audit_logs (
      id bigserial PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id),
      api_key_id uuid REFERENCES api_keys(id) ON DELETE SET NULL,
      actor_type text NOT NULL,
      actor_id text,
      action text NOT NULL,
      target_type text NOT NULL,
      target_id text,
      occurred_at timestamp(6) without time zone NOT NULL DEFAULT NOW(),
      payload jsonb NOT NULL DEFAULT '{}'::jsonb
    )
    """)

    Repo.query!(
      "CREATE INDEX audit_logs_tenant_id_occurred_at_index ON audit_logs (tenant_id, occurred_at)"
    )

    Repo.query!("""
    CREATE FUNCTION orchard_reject_audit_log_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'audit_logs is append-only';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER audit_logs_append_only
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW
    EXECUTE FUNCTION orchard_reject_audit_log_mutation()
    """)
  end

  defp run_down_sql do
    Repo.query!("DROP TABLE IF EXISTS node_dispatch_capacity_policies")
    Repo.query!("DROP TABLE IF EXISTS node_admission_decisions")
    Repo.query!("DROP TABLE IF EXISTS node_admission_candidates")
    Repo.query!("DROP TABLE IF EXISTS provisioning_batches")
    Repo.query!("DROP TABLE IF EXISTS role_bindings")

    Repo.query!(
      "ALTER TABLE IF EXISTS requests DROP CONSTRAINT IF EXISTS requests_service_account_id_fkey"
    )

    Repo.query!("DROP TRIGGER IF EXISTS audit_logs_append_only ON audit_logs")
    Repo.query!("DROP FUNCTION IF EXISTS orchard_reject_audit_log_mutation()")
    Repo.query!("DROP TABLE IF EXISTS audit_logs")
    Repo.query!("DROP TABLE IF EXISTS api_keys")
    Repo.query!("DROP TABLE IF EXISTS service_accounts")
    Repo.query!("DROP TABLE IF EXISTS tenants")
  end

  defp table_exists?(table_name) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
        [table_name]
      )

    count > 0
  end

  defp fetch_legacy_tenant_rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text, slug, name FROM tenants WHERE id = '#{Governance.legacy_tenant_id()}' ORDER BY slug"
      )

    rows
  end
end
