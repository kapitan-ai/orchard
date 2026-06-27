defmodule Orchard.Repo.Migrations.ApiClientProvisioningMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "api-client-migration-#{System.unique_integer([:positive])}",
        name: "API Client Migration"
      })

    %{tenant: tenant}
  end

  test "requests service_account_id references service_accounts while preserving tenant requests",
       %{
         tenant: tenant
       } do
    assert constraint_exists?("requests", "requests_service_account_id_fkey")

    assert {:ok, _result} =
             insert_request(%{
               public_id: "req_tenant_#{System.unique_integer([:positive])}",
               tenant_id: tenant.id,
               principal_type: "tenant",
               service_account_id: nil
             })

    assert {:error, %Postgrex.Error{postgres: %{constraint: "requests_service_account_id_fkey"}}} =
             insert_request(%{
               public_id: "req_service_account_#{System.unique_integer([:positive])}",
               tenant_id: tenant.id,
               principal_type: "service_account",
               service_account_id: Ecto.UUID.generate()
             })
  end

  test "service-account-owned API Tokens restrict Service Account deletion", %{
    tenant: tenant
  } do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "migration-api-client-#{System.unique_integer([:positive])}",
        owner_contact: "owner@example.com"
      })

    assert {:ok, _result} =
             Governance.create_api_client_api_token(api_client, %{name: "migration-token"})

    assert constraint_delete_action("api_keys", "api_keys_service_account_id_fkey") == "a"

    assert {:error, %Postgrex.Error{postgres: %{constraint: "api_keys_service_account_id_fkey"}}} =
             Repo.query("DELETE FROM service_accounts WHERE id = $1", [
               dump_uuid(api_client.id)
             ])
  end

  defp insert_request(attrs) do
    Repo.query(
      """
      INSERT INTO requests (
        public_id,
        endpoint,
        tenant_id,
        principal_type,
        service_account_id,
        requested_model,
        state,
        stream,
        payload_capture_mode,
        inserted_at,
        updated_at
      )
      VALUES ($1, 'chat_completions', $2, $3, $4, 'migration-test-model', 'received', false, 'metadata', NOW(), NOW())
      """,
      [
        attrs.public_id,
        dump_uuid(attrs.tenant_id),
        attrs.principal_type,
        dump_uuid(attrs.service_account_id)
      ]
    )
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(value), do: Ecto.UUID.dump!(value)

  defp constraint_exists?(table_name, constraint_name) do
    %{num_rows: count} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public' AND t.relname = $1 AND c.conname = $2
        """,
        [table_name, constraint_name]
      )

    count > 0
  end

  defp constraint_delete_action(table_name, constraint_name) do
    %{rows: [[action]]} =
      Repo.query!(
        """
        SELECT c.confdeltype
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public' AND t.relname = $1 AND c.conname = $2
        """,
        [table_name, constraint_name]
      )

    action
  end
end
