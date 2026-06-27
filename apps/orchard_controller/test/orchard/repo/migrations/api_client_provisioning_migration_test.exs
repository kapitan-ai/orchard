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
    assert constraint_delete_action("requests", "requests_service_account_id_fkey") == "a"

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

  test "requests service_account_id restricts API Client deletion and preserves provenance", %{
    tenant: tenant
  } do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "migration-request-api-client-#{System.unique_integer([:positive])}",
        owner_contact: "owner@example.com"
      })

    public_id = "req_service_account_existing_#{System.unique_integer([:positive])}"

    assert {:ok, _result} =
             insert_request(%{
               public_id: public_id,
               tenant_id: tenant.id,
               principal_type: "service_account",
               service_account_id: api_client.id
             })

    assert {:error, %Postgrex.Error{postgres: %{constraint: "requests_service_account_id_fkey"}}} =
             Repo.query("DELETE FROM service_accounts WHERE id = $1", [
               dump_uuid(api_client.id)
             ])

    assert {"service_account", service_account_id} = select_request_principal(public_id)
    assert service_account_id == api_client.id
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

  test "service-account token names reject only overlapping active windows", %{
    tenant: tenant
  } do
    assert constraint_exists?("api_keys", "api_keys_service_account_active_name_no_overlap")

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "migration-window-api-client-#{System.unique_integer([:positive])}",
        owner_contact: "owner@example.com"
      })

    past =
      DateTime.utc_now()
      |> DateTime.add(-3600, :second)
      |> DateTime.truncate(:microsecond)

    assert {:ok, _expired_result} =
             Governance.create_api_client_api_token(api_client, %{
               name: "window-token",
               expires_at: past
             })

    assert {:ok, _active_result} =
             Governance.create_api_client_api_token(api_client, %{name: "window-token"})

    assert {:error, changeset} =
             Governance.create_api_client_api_token(api_client, %{name: "window-token"})

    assert %{name: ["has already been taken"]} = errors_on(changeset)
  end

  test "down migration keeps database-scoped btree_gist extension installed" do
    assert extension_exists?("btree_gist")
    assert constraint_exists?("api_keys", "api_keys_service_account_active_name_no_overlap")

    run_api_keys_down_overlap_constraint_sql()

    refute constraint_exists?("api_keys", "api_keys_service_account_active_name_no_overlap")
    assert extension_exists?("btree_gist")

    migration_source = File.read!(migration_path())
    refute migration_source =~ "DROP EXTENSION IF EXISTS btree_gist"
  end

  test "down migration backfills service-account token tenant ids before restoring not null", %{
    tenant: tenant
  } do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "migration-down-api-client-#{System.unique_integer([:positive])}",
        owner_contact: "owner@example.com"
      })

    assert {:ok, %{api_key: api_key}} =
             Governance.create_api_client_api_token(api_client, %{name: "rollback-token"})

    assert [[nil, api_client_id]] =
             select_api_key_owner_columns(api_key.id, ["tenant_id", "service_account_id"])

    assert Ecto.UUID.load!(api_client_id) == api_client.id

    run_api_keys_down_owner_sql()

    assert [[tenant_id]] = select_api_key_owner_columns(api_key.id, ["tenant_id"])
    assert Ecto.UUID.load!(tenant_id) == tenant.id
    assert column_not_null?("api_keys", "tenant_id")
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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

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

  defp select_request_principal(public_id) do
    %{rows: [[principal_type, service_account_id]]} =
      Repo.query!(
        "SELECT principal_type, service_account_id FROM requests WHERE public_id = $1",
        [public_id]
      )

    {principal_type, Ecto.UUID.load!(service_account_id)}
  end

  defp run_api_keys_down_overlap_constraint_sql do
    Repo.query!(
      "ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_service_account_active_name_no_overlap"
    )
  end

  defp run_api_keys_down_owner_sql do
    run_api_keys_down_overlap_constraint_sql()

    Repo.query!("DROP INDEX IF EXISTS api_keys_service_account_id_inserted_at_index")
    Repo.query!("ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_exactly_one_owner")

    Repo.query!("""
    UPDATE api_keys
    SET tenant_id = service_accounts.tenant_id,
        updated_at = NOW()
    FROM service_accounts
    WHERE api_keys.service_account_id = service_accounts.id
      AND api_keys.tenant_id IS NULL
    """)

    Repo.query!("ALTER TABLE api_keys DROP COLUMN expires_at")
    Repo.query!("ALTER TABLE api_keys DROP COLUMN service_account_id")
    Repo.query!("ALTER TABLE api_keys ALTER COLUMN tenant_id SET NOT NULL")
  end

  defp select_api_key_owner_columns(api_key_id, columns) do
    select = Enum.join(columns, ", ")

    %{rows: rows} =
      Repo.query!(
        "SELECT #{select} FROM api_keys WHERE id = $1",
        [dump_uuid(api_key_id)]
      )

    rows
  end

  defp column_not_null?(table_name, column_name) do
    %{rows: [[nullable]]} =
      Repo.query!(
        """
        SELECT is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table_name, column_name]
      )

    nullable == "NO"
  end

  defp extension_exists?(extension_name) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM pg_extension WHERE extname = $1",
        [extension_name]
      )

    count > 0
  end

  defp migration_path do
    Path.expand(
      "../../../../priv/repo/migrations/20260627000000_m2a_1b_api_client_provisioning.exs",
      __DIR__
    )
  end
end
