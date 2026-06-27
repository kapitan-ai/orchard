defmodule Orchard.Repo.Migrations.M2A1BApiClientProvisioning do
  use Ecto.Migration

  def up do
    create table(:service_accounts, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :text, null: false)
      add(:owner_contact, :text, null: false)
      add(:owner_name, :text)
      add(:team, :text)
      add(:external_ref, :text)
      add(:description, :text)
      add(:purpose, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:disabled_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:service_accounts, [:tenant_id, :name]))

    create(
      unique_index(:service_accounts, [:tenant_id, :external_ref],
        where: "external_ref IS NOT NULL",
        name: :idx_service_accounts_tenant_external_ref
      )
    )

    create(index(:service_accounts, [:tenant_id, :team]))

    create constraint(:service_accounts, :service_accounts_name_not_blank,
             check: "length(btrim(name)) > 0"
           )

    create constraint(:service_accounts, :service_accounts_owner_contact_not_blank,
             check: "length(btrim(owner_contact)) > 0"
           )

    alter table(:api_keys) do
      add(
        :service_account_id,
        references(:service_accounts, type: :binary_id, on_delete: :nilify_all)
      )

      add(:expires_at, :utc_datetime_usec)
    end

    execute("ALTER TABLE api_keys ALTER COLUMN tenant_id DROP NOT NULL")

    create constraint(:api_keys, :api_keys_exactly_one_owner,
             check:
               "(tenant_id IS NOT NULL AND service_account_id IS NULL) OR (tenant_id IS NULL AND service_account_id IS NOT NULL)"
           )

    create(index(:api_keys, [:service_account_id, :inserted_at]))

    create(
      unique_index(:api_keys, [:service_account_id, :name],
        where: "service_account_id IS NOT NULL AND revoked_at IS NULL",
        name: :idx_api_keys_service_account_active_name
      )
    )

    create table(:role_bindings, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:principal_type, :text, null: false)
      add(:principal_id, :binary_id, null: false)
      add(:role, :text, null: false)
      add(:tenant_scope_id, references(:tenants, type: :binary_id, on_delete: :delete_all))
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create constraint(:role_bindings, :role_bindings_principal_type_check,
             check: "principal_type IN ('tenant', 'service_account', 'api_key')"
           )

    create constraint(:role_bindings, :role_bindings_role_check,
             check: "role IN ('admin', 'operator', 'tenant_admin', 'inference_client')"
           )

    create constraint(:role_bindings, :role_bindings_inference_client_tenant_scope,
             check: "role <> 'inference_client' OR tenant_scope_id IS NOT NULL"
           )

    create(
      unique_index(:role_bindings, [:principal_type, :principal_id, :role, :tenant_scope_id],
        name: :idx_role_bindings_unique_assignment
      )
    )

    create table(:provisioning_batches, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:actor_type, :text, null: false, default: "operator")
      add(:actor_id, :text)
      add(:status, :text, null: false)
      add(:row_count, :integer, null: false, default: 0)
      add(:api_clients_created_count, :integer, null: false, default: 0)
      add(:api_clients_updated_count, :integer, null: false, default: 0)
      add(:api_tokens_created_count, :integer, null: false, default: 0)
      add(:api_tokens_rotated_count, :integer, null: false, default: 0)
      add(:api_tokens_revoked_count, :integer, null: false, default: 0)
      add(:input_sha256, :text)
      add(:error_summary, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create constraint(:provisioning_batches, :provisioning_batches_status_check,
             check: "status IN ('applying', 'applied', 'failed', 'output_failed')"
           )

    create constraint(:provisioning_batches, :provisioning_batches_counts_non_negative,
             check:
               "row_count >= 0 AND api_clients_created_count >= 0 AND api_clients_updated_count >= 0 AND api_tokens_created_count >= 0 AND api_tokens_rotated_count >= 0 AND api_tokens_revoked_count >= 0"
           )

    create(index(:provisioning_batches, [:tenant_id, :inserted_at]))

    alter table(:requests) do
      add(:principal_type, :text, null: false, default: "tenant")
    end

    create constraint(:requests, :requests_principal_type_check,
             check: "principal_type IN ('tenant', 'service_account')"
           )
  end

  def down do
    drop(constraint(:requests, :requests_principal_type_check))

    alter table(:requests) do
      remove(:principal_type)
    end

    drop_if_exists(index(:provisioning_batches, [:tenant_id, :inserted_at]))
    drop(constraint(:provisioning_batches, :provisioning_batches_counts_non_negative))
    drop(constraint(:provisioning_batches, :provisioning_batches_status_check))
    drop(table(:provisioning_batches))

    drop_if_exists(index(:role_bindings, [:principal_type, :principal_id, :role, :tenant_scope_id],
      name: :idx_role_bindings_unique_assignment
    ))

    drop(constraint(:role_bindings, :role_bindings_inference_client_tenant_scope))
    drop(constraint(:role_bindings, :role_bindings_role_check))
    drop(constraint(:role_bindings, :role_bindings_principal_type_check))
    drop(table(:role_bindings))

    drop_if_exists(
      index(:api_keys, [:service_account_id, :name],
        name: :idx_api_keys_service_account_active_name
      )
    )

    drop_if_exists(index(:api_keys, [:service_account_id, :inserted_at]))
    drop(constraint(:api_keys, :api_keys_exactly_one_owner))

    alter table(:api_keys) do
      remove(:expires_at)
      remove(:service_account_id)
    end

    execute("ALTER TABLE api_keys ALTER COLUMN tenant_id SET NOT NULL")

    drop_if_exists(index(:service_accounts, [:tenant_id, :team]))

    drop_if_exists(
      index(:service_accounts, [:tenant_id, :external_ref],
        name: :idx_service_accounts_tenant_external_ref
      )
    )

    drop_if_exists(index(:service_accounts, [:tenant_id, :name]))
    drop(constraint(:service_accounts, :service_accounts_owner_contact_not_blank))
    drop(constraint(:service_accounts, :service_accounts_name_not_blank))
    drop(table(:service_accounts))
  end
end
