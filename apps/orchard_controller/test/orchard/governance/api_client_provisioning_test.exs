defmodule Orchard.Governance.ApiClientProvisioningTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Orchard.Governance

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    AuditLog,
    ProvisioningBatch,
    RoleBinding,
    ServiceAccount
  }

  alias Orchard.Repo

  setup do
    slug = unique_slug("bulk-org")
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: "Bulk Org"})
    %{tenant: tenant}
  end

  test "SPEC.md §7.2.2 keeps tenant-direct API Tokens compatible", %{tenant: tenant} do
    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant, %{name: "direct-token"})

    assert {:ok, auth_context} = Governance.authenticate_api_key(token)
    assert auth_context.tenant_id == tenant.id
    assert auth_context.principal_type == :tenant
    assert auth_context.principal_id == tenant.id
    assert auth_context.service_account_id == nil
    assert auth_context.api_key_id == api_key.id
    assert :ok = Governance.authorize_public_inference(auth_context)
  end

  test "dry run validates a single-Organization CSV without mutating state", %{tenant: tenant} do
    rows = [row(tenant, api_client: "client-a", key_name: "prod-token")]

    assert {:ok, plan} =
             Governance.bulk_validate_api_clients(rows, input_sha256: "input-sha")

    assert plan.tenant.id == tenant.id
    assert plan.input_sha256 == "input-sha"

    assert plan.counts == %{
             api_clients_created_count: 1,
             api_clients_updated_count: 0,
             api_tokens_created_count: 1,
             api_tokens_rotated_count: 0
           }

    refute service_account_exists?(tenant.id, "client-a")
    assert Repo.aggregate(ProvisioningBatch, :count, :id) == 0
  end

  test "repeated new API Client rows count one created client and later updates", %{
    tenant: tenant
  } do
    rows = [
      row(tenant, api_client: "client-repeat", key_name: "production"),
      row(tenant, api_client: "client-repeat", key_name: "staging")
    ]

    assert {:ok, plan} = Governance.bulk_validate_api_clients(rows)

    assert plan.counts == %{
             api_clients_created_count: 1,
             api_clients_updated_count: 1,
             api_tokens_created_count: 2,
             api_tokens_rotated_count: 0
           }

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows)

    assert result.batch.api_clients_created_count == 1
    assert result.batch.api_clients_updated_count == 1
    assert result.batch.api_tokens_created_count == 2

    api_client = Repo.get_by!(ServiceAccount, tenant_id: tenant.id, name: "client-repeat")
    assert length(result.output_rows) == 2
    assert Enum.map(result.output_rows, & &1.api_client) == ["client-repeat", "client-repeat"]

    assert Repo.aggregate(
             from(api_key in ApiKey, where: api_key.service_account_id == ^api_client.id),
             :count,
             :id
           ) == 2
  end

  test "apply creates API Client access and returns one-time API Token output only in memory", %{
    tenant: tenant
  } do
    rows = [
      row(tenant,
        api_client: "client-b",
        external_ref: "hr-001",
        key_name: "production",
        metadata_json: Jason.encode!(%{cost_center: "ml"})
      )
    ]

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows, input_sha256: "input-sha")
    assert [output_row] = result.output_rows
    assert output_row.organization == tenant.slug
    assert output_row.api_client == "client-b"
    assert output_row.api_token =~ "orch_"

    batch = Repo.get!(ProvisioningBatch, result.batch.id)
    assert batch.status == :applied
    assert batch.input_sha256 == "input-sha"
    assert batch.row_count == 1
    assert batch.api_clients_created_count == 1
    assert batch.api_tokens_created_count == 1

    api_client = Repo.get_by!(ServiceAccount, tenant_id: tenant.id, external_ref: "hr-001")
    assert api_client.metadata == %{"cost_center" => "ml"}

    api_key = Repo.get!(ApiKey, output_row.api_token_id)
    assert api_key.service_account_id == api_client.id
    assert api_key.tenant_id == nil
    assert api_key.secret_hash != nil
    assert ApiKeySecret.verify(output_row.api_token, api_key.secret_hash)

    role_binding =
      Repo.get_by!(RoleBinding,
        principal_type: :service_account,
        principal_id: api_client.id,
        role: :inference_client,
        tenant_scope_id: tenant.id
      )

    assert role_binding.tenant_scope_id == tenant.id

    assert {:ok, auth_context} = Governance.authenticate_api_key(output_row.api_token)
    assert auth_context.tenant_id == tenant.id
    assert auth_context.principal_type == :service_account
    assert auth_context.principal_id == api_client.id
    assert auth_context.service_account_id == api_client.id
    assert :ok = Governance.authorize_public_inference(auth_context)

    assert {:ok, [listed_client]} = Governance.list_api_clients_for_tenant(tenant)
    assert listed_client.id == api_client.id
    assert [listed_token] = listed_client.api_keys
    assert listed_token.id == api_key.id
    assert listed_token.secret_hash == nil

    refute inspect(batch) =~ output_row.api_token
    refute inspect(Repo.all(AuditLog)) =~ output_row.api_token
  end

  test "marking output failure writes redacted provisioning batch audit", %{tenant: tenant} do
    rows = [row(tenant, api_client: "client-output-audit", key_name: "production")]

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows)

    assert {:ok, batch} =
             Governance.mark_provisioning_batch_output_failed(result.batch.id, %{
               "reason" => "disk full",
               "api_token" => "orch_plaintext.secret"
             })

    assert batch.status == :output_failed
    assert batch.error_summary == %{"api_token" => "[redacted]", "reason" => "disk full"}

    audit_log =
      Repo.get_by!(AuditLog,
        action: "provisioning_batch.output_failed",
        target_type: "provisioning_batch",
        target_id: batch.id
      )

    assert audit_log.payload["error_summary"] == %{
             "api_token" => "[redacted]",
             "reason" => "disk full"
           }

    refute inspect(audit_log) =~ "orch_plaintext.secret"
  end

  test "active token duplicates require explicit rotation", %{tenant: tenant} do
    rows = [row(tenant, api_client: "client-c", key_name: "production")]

    assert {:ok, first_result} = Governance.bulk_apply_api_clients(rows)
    [first_output] = first_result.output_rows

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)
    assert [%{field: "key_name", message: message}] = errors
    assert message =~ "Key Rotation"

    assert {:ok, rotated_result} = Governance.bulk_apply_api_clients(rows, rotation: true)
    [rotated_output] = rotated_result.output_rows

    assert rotated_output.api_token != first_output.api_token
    assert rotated_result.batch.api_tokens_rotated_count == 1
    assert rotated_result.batch.api_tokens_revoked_count == 1

    assert {:error, :api_key_revoked} = Governance.authenticate_api_key(first_output.api_token)
    assert {:ok, rotated_auth} = Governance.authenticate_api_key(rotated_output.api_token)
    assert rotated_auth.principal_type == :service_account

    first_key = Repo.get!(ApiKey, first_output.api_token_id)
    assert %DateTime{} = first_key.revoked_at
  end

  test "disabled API Clients cannot receive new bulk-provisioned API Tokens", %{
    tenant: tenant
  } do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-disabled",
        owner_contact: "disabled@example.com"
      })

    assert {:ok, _disabled} = Governance.disable_api_client(tenant, api_client)

    rows = [row(tenant, api_client: "client-disabled", key_name: "blocked")]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)
    assert [%{field: "api_client", message: "API Client is disabled."}] = errors

    assert {:error, :api_client_disabled} =
             Governance.create_api_client_api_token(api_client, %{name: "blocked"})
  end

  test "plaintext token fields are rejected from input metadata", %{tenant: tenant} do
    rows = [
      row(tenant,
        api_client: "client-secret-field",
        key_name: "production",
        metadata_json: Jason.encode!(%{api_token: "plaintext"})
      )
    ]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)
    assert [%{field: "metadata_json", message: message}] = errors
    assert message =~ "must not include plaintext token or secret fields"
  end

  test "direct API Client metadata rejects plaintext-like keys and permits token prefixes", %{
    tenant: tenant
  } do
    assert {:error, changeset} =
             Governance.upsert_api_client(tenant, %{
               name: "client-direct-secret",
               owner_contact: "owner@example.com",
               metadata: %{"access_token" => "plaintext"}
             })

    assert %{metadata: [message]} = errors_on(changeset)
    assert message =~ "must not include plaintext token or secret fields"

    assert {:ok, api_client} =
             Governance.upsert_api_client(tenant, %{
               name: "client-direct-safe",
               owner_contact: "owner@example.com",
               metadata: %{
                 "token_prefix" => "orch_safe",
                 "nested" => %{"api_token_prefixes" => ["orch_one", "orch_two"]}
               }
             })

    assert api_client.metadata == %{
             "token_prefix" => "orch_safe",
             "nested" => %{"api_token_prefixes" => ["orch_one", "orch_two"]}
           }
  end

  defp row(tenant, overrides) do
    %{
      "organization" => tenant.slug,
      "api_client" => "client-#{System.unique_integer([:positive])}",
      "owner_contact" => "owner@example.com",
      "key_name" => "primary"
    }
    |> Map.merge(stringify_keys(overrides))
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp service_account_exists?(tenant_id, name) do
    Repo.exists?(
      from(service_account in ServiceAccount,
        where: service_account.tenant_id == ^tenant_id and service_account.name == ^name
      )
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
