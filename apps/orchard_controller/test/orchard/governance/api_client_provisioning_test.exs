defmodule Orchard.Governance.ApiClientProvisioningTest.CollisionSecret do
  alias Orchard.Governance.ApiKeySecret

  @token "orch_bulk_collision.fixedsecret"

  def generate do
    %{
      token: @token,
      token_prefix: "orch_bulk_collision",
      secret_hash: ApiKeySecret.hash(@token)
    }
  end
end

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

  test "same API Client name with mixed external_ref presence is rejected", %{tenant: tenant} do
    rows = [
      row(tenant, api_client: "client-mixed-ref", external_ref: "external-a", key_name: "one"),
      row(tenant, api_client: "client-mixed-ref", key_name: "two")
    ]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)

    assert Enum.any?(errors, fn error ->
             error.field == "external_ref" and
               error.message =~ "must consistently use the same External Reference"
           end)
  end

  test "same API Client name with multiple external_ref values is rejected", %{tenant: tenant} do
    rows = [
      row(tenant,
        api_client: "client-conflicting-ref",
        external_ref: "external-a",
        key_name: "one"
      ),
      row(tenant,
        api_client: "client-conflicting-ref",
        external_ref: "external-b",
        key_name: "two"
      )
    ]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)

    assert Enum.any?(errors, fn error ->
             error.field == "external_ref" and
               error.message =~ "must consistently use the same External Reference"
           end)
  end

  test "same external_ref under multiple API Client names is rejected", %{tenant: tenant} do
    rows = [
      row(tenant, api_client: "client-ref-a", external_ref: "external-conflict", key_name: "one"),
      row(tenant, api_client: "client-ref-b", external_ref: "external-conflict", key_name: "two")
    ]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)

    assert Enum.any?(errors, fn error ->
             error.field == "api_client" and error.message =~ "belongs to multiple API Clients"
           end)
  end

  test "same existing API Client resolved by different identities is rejected", %{tenant: tenant} do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-resolved-identity",
        owner_contact: "owner@example.com",
        external_ref: "resolved-identity-ref"
      })

    rows = [
      row(tenant, api_client: api_client.name, key_name: "one"),
      row(tenant,
        api_client: "client-resolved-identity-alias",
        external_ref: api_client.external_ref,
        key_name: "two"
      )
    ]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)

    assert Enum.any?(errors, fn error ->
             error.field == "api_client" and
               error.message =~ "same existing API Client through multiple identities"
           end)
  end

  test "rotation rejects ambiguous identity before creating output", %{tenant: tenant} do
    rows = [
      row(tenant,
        api_client: "client-rotation-identity",
        external_ref: "rotation-external",
        key_name: "production"
      ),
      row(tenant, api_client: "client-rotation-identity", key_name: "production")
    ]

    assert {:error, errors} = Governance.bulk_apply_api_clients(rows, rotation: true)

    assert Enum.any?(errors, fn error ->
             error.field == "external_ref" and
               error.message =~ "must consistently use the same External Reference"
           end)

    refute service_account_exists?(tenant.id, "client-rotation-identity")
    assert Repo.aggregate(ProvisioningBatch, :count, :id) == 0
  end

  test "rotation rejects resolved identity conflict before returning revoked output", %{
    tenant: tenant
  } do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-rotation-resolved",
        owner_contact: "owner@example.com",
        external_ref: "rotation-resolved-ref"
      })

    rows = [
      row(tenant, api_client: api_client.name, key_name: "production"),
      row(tenant,
        api_client: "client-rotation-resolved-alias",
        external_ref: api_client.external_ref,
        key_name: "production"
      )
    ]

    assert {:error, errors} = Governance.bulk_apply_api_clients(rows, rotation: true)

    assert Enum.any?(errors, fn error ->
             error.field == "api_client" and
               error.message =~ "same existing API Client through multiple identities"
           end)

    assert Repo.aggregate(
             from(api_key in ApiKey, where: api_key.service_account_id == ^api_client.id),
             :count,
             :id
           ) == 0

    assert Repo.aggregate(ProvisioningBatch, :count, :id) == 0
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

    applied_audit_log =
      Repo.get_by!(AuditLog,
        action: "provisioning_batch.applied",
        target_type: "provisioning_batch",
        target_id: batch.id
      )

    assert applied_audit_log.payload["api_clients_created_count"] == 1
    assert applied_audit_log.payload["api_clients_updated_count"] == 0
    assert applied_audit_log.payload["api_tokens_created_count"] == 1
    assert applied_audit_log.payload["api_tokens_rotated_count"] == 0
    assert applied_audit_log.payload["api_tokens_revoked_count"] == 0

    refute inspect(batch) =~ output_row.api_token
    refute inspect(Repo.all(AuditLog)) =~ output_row.api_token
  end

  test "sparse rerun preserves omitted API Client metadata columns", %{tenant: tenant} do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-sparse",
        owner_contact: "owner@example.com",
        owner_name: "Original Owner",
        team: "Platform",
        external_ref: "sparse-ref",
        description: "Existing description",
        purpose: "Existing purpose",
        metadata: %{"cost_center" => "ml", "tier" => "gold"}
      })

    rows = [
      row(tenant,
        api_client: api_client.name,
        owner_contact: "new-owner@example.com",
        key_name: "secondary"
      )
    ]

    assert {:ok, _result} = Governance.bulk_apply_api_clients(rows)

    updated = Repo.get!(ServiceAccount, api_client.id)
    assert updated.owner_contact == "new-owner@example.com"
    assert updated.owner_name == "Original Owner"
    assert updated.team == "Platform"
    assert updated.external_ref == "sparse-ref"
    assert updated.description == "Existing description"
    assert updated.purpose == "Existing purpose"
    assert updated.metadata == %{"cost_center" => "ml", "tier" => "gold"}
  end

  test "explicit blank API Client metadata columns clear existing values", %{tenant: tenant} do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-clear",
        owner_contact: "owner@example.com",
        owner_name: "Original Owner",
        team: "Platform",
        external_ref: "clear-ref",
        description: "Existing description",
        purpose: "Existing purpose",
        metadata: %{"cost_center" => "ml"}
      })

    rows = [
      row(tenant,
        api_client: api_client.name,
        owner_contact: "new-owner@example.com",
        key_name: "secondary",
        owner_name: "",
        team: "",
        external_ref: "",
        description: "",
        purpose: "",
        metadata_json: ""
      )
    ]

    assert {:ok, _result} = Governance.bulk_apply_api_clients(rows)

    updated = Repo.get!(ServiceAccount, api_client.id)
    assert updated.owner_contact == "new-owner@example.com"
    assert updated.owner_name == nil
    assert updated.team == nil
    assert updated.external_ref == nil
    assert updated.description == nil
    assert updated.purpose == nil
    assert updated.metadata == %{}
  end

  test "present metadata_json replaces existing API Client metadata", %{tenant: tenant} do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-replace-metadata",
        owner_contact: "owner@example.com",
        metadata: %{"cost_center" => "ml", "tier" => "gold"}
      })

    rows = [
      row(tenant,
        api_client: api_client.name,
        key_name: "secondary",
        metadata_json: Jason.encode!(%{"cost_center" => "platform"})
      )
    ]

    assert {:ok, _result} = Governance.bulk_apply_api_clients(rows)

    updated = Repo.get!(ServiceAccount, api_client.id)
    assert updated.metadata == %{"cost_center" => "platform"}
  end

  test "existing API Client name can gain a new external_ref", %{tenant: tenant} do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-add-ref",
        owner_contact: "owner@example.com",
        owner_name: "Original Owner",
        metadata: %{"cost_center" => "ml"}
      })

    rows = [
      row(tenant,
        api_client: api_client.name,
        key_name: "secondary",
        external_ref: "client-add-ref-external"
      )
    ]

    assert {:ok, plan} = Governance.bulk_validate_api_clients(rows)

    assert plan.counts == %{
             api_clients_created_count: 0,
             api_clients_updated_count: 1,
             api_tokens_created_count: 1,
             api_tokens_rotated_count: 0
           }

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows)
    assert [output_row] = result.output_rows
    assert output_row.external_ref == "client-add-ref-external"

    updated = Repo.get!(ServiceAccount, api_client.id)
    assert updated.external_ref == "client-add-ref-external"
    assert updated.owner_name == "Original Owner"
    assert updated.metadata == %{"cost_center" => "ml"}
  end

  test "existing API Client name can replace external_ref", %{tenant: tenant} do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-change-ref",
        owner_contact: "owner@example.com",
        external_ref: "client-change-ref-old"
      })

    rows = [
      row(tenant,
        api_client: api_client.name,
        key_name: "secondary",
        external_ref: "client-change-ref-new"
      )
    ]

    assert {:ok, plan} = Governance.bulk_validate_api_clients(rows)
    assert plan.counts.api_clients_created_count == 0
    assert plan.counts.api_clients_updated_count == 1

    assert {:ok, _result} = Governance.bulk_apply_api_clients(rows)

    updated = Repo.get!(ServiceAccount, api_client.id)
    assert updated.external_ref == "client-change-ref-new"

    refute Repo.get_by(ServiceAccount,
             tenant_id: tenant.id,
             external_ref: "client-change-ref-old"
           )
  end

  test "external_ref and API Client name conflicts are rejected", %{tenant: tenant} do
    {:ok, named_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-name-conflict",
        owner_contact: "owner@example.com",
        external_ref: "client-name-conflict-ref"
      })

    {:ok, ref_client} =
      Governance.upsert_api_client(tenant, %{
        name: "client-ref-conflict",
        owner_contact: "owner@example.com",
        external_ref: "client-ref-conflict-ref"
      })

    rows = [
      row(tenant,
        api_client: named_client.name,
        key_name: "secondary",
        external_ref: ref_client.external_ref
      )
    ]

    assert {:error, errors} = Governance.bulk_validate_api_clients(rows)

    assert Enum.any?(errors, fn error ->
             error.field == "external_ref" and
               error.message =~ "refer to different existing API Clients"
           end)

    assert Repo.get!(ServiceAccount, named_client.id).external_ref == "client-name-conflict-ref"
    assert Repo.get!(ServiceAccount, ref_client.id).name == "client-ref-conflict"
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

  test "post-validation apply failure persists redacted failed batch evidence", %{
    tenant: tenant
  } do
    %ApiKey{}
    |> ApiKey.tenant_direct_changeset(%{
      tenant_id: tenant.id,
      name: "collision-source",
      token_prefix: "orch_bulk_collision",
      secret_hash: ApiKeySecret.hash("orch_bulk_collision.fixedsecret")
    })
    |> Repo.insert!()

    rows = [row(tenant, api_client: "client-apply-failure", key_name: "production")]

    with_env(
      :governance_api_key_secret_impl,
      __MODULE__.CollisionSecret,
      fn ->
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Governance.bulk_apply_api_clients(rows)

        assert %{token_prefix: ["has already been taken"]} = errors_on(changeset)
      end
    )

    assert [batch] =
             Repo.all(
               from(batch in ProvisioningBatch,
                 where: batch.tenant_id == ^tenant.id and batch.status == :failed
               )
             )

    assert batch.row_count == 1
    assert batch.error_summary["reason"] == "apply_failed"
    assert batch.error_summary["errors"]["token_prefix"] == ["has already been taken"]

    audit_log =
      Repo.get_by!(AuditLog,
        action: "provisioning_batch.failed",
        target_type: "provisioning_batch",
        target_id: batch.id
      )

    assert audit_log.payload["error_summary"] == batch.error_summary
    refute inspect(batch) =~ "fixedsecret"
    refute inspect(audit_log) =~ "fixedsecret"
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

  test "expired token names can be reprovisioned without rotation", %{tenant: tenant} do
    expired_at = datetime_seconds_from_now(-3600)

    expired_rows = [
      row(tenant,
        api_client: "client-expired-rerun",
        key_name: "production",
        expires_at: DateTime.to_iso8601(expired_at)
      )
    ]

    assert {:ok, expired_result} = Governance.bulk_apply_api_clients(expired_rows)
    [expired_output] = expired_result.output_rows
    assert {:error, :api_key_expired} = Governance.authenticate_api_key(expired_output.api_token)

    rows = [row(tenant, api_client: "client-expired-rerun", key_name: "production")]

    assert {:ok, plan} = Governance.bulk_validate_api_clients(rows)
    assert plan.counts.api_tokens_created_count == 1
    assert plan.counts.api_tokens_rotated_count == 0

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows)
    [output] = result.output_rows

    assert output.api_token != expired_output.api_token
    assert result.batch.api_tokens_created_count == 1
    assert result.batch.api_tokens_rotated_count == 0
    assert result.batch.api_tokens_revoked_count == 0

    expired_key = Repo.get!(ApiKey, expired_output.api_token_id)
    assert expired_key.revoked_at == nil
    assert {:ok, auth_context} = Governance.authenticate_api_key(output.api_token)
    assert auth_context.principal_type == :service_account
  end

  test "rotation with only expired same-name tokens creates without rotating", %{
    tenant: tenant
  } do
    expired_at = datetime_seconds_from_now(-3600)

    expired_rows = [
      row(tenant,
        api_client: "client-expired-rotation",
        key_name: "production",
        expires_at: DateTime.to_iso8601(expired_at)
      )
    ]

    assert {:ok, expired_result} = Governance.bulk_apply_api_clients(expired_rows)
    [expired_output] = expired_result.output_rows
    rows = [row(tenant, api_client: "client-expired-rotation", key_name: "production")]

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows, rotation: true)

    assert result.batch.api_tokens_created_count == 1
    assert result.batch.api_tokens_rotated_count == 0
    assert result.batch.api_tokens_revoked_count == 0

    expired_key = Repo.get!(ApiKey, expired_output.api_token_id)
    assert expired_key.revoked_at == nil
    assert count_audit_logs("api_key.rotated") == 0
  end

  test "mixed rotation counts only rows with active replacements", %{tenant: tenant} do
    active_rows = [row(tenant, api_client: "client-mixed-rotation", key_name: "production")]

    assert {:ok, first_result} = Governance.bulk_apply_api_clients(active_rows)
    [first_output] = first_result.output_rows

    rows = [
      row(tenant, api_client: "client-mixed-rotation", key_name: "production"),
      row(tenant, api_client: "client-mixed-rotation-new", key_name: "production")
    ]

    assert {:ok, result} = Governance.bulk_apply_api_clients(rows, rotation: true)

    assert result.batch.api_tokens_created_count == 2
    assert result.batch.api_tokens_rotated_count == 1
    assert result.batch.api_tokens_revoked_count == 1
    assert count_audit_logs("api_key.rotated") == 1

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

  defp count_audit_logs(action) do
    Repo.aggregate(from(audit_log in AuditLog, where: audit_log.action == ^action), :count, :id)
  end

  defp datetime_seconds_from_now(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp with_env(key, value, fun) do
    previous = Application.get_env(:orchard_controller, key, :__missing__)
    Application.put_env(:orchard_controller, key, value)

    try do
      fun.()
    after
      case previous do
        :__missing__ -> Application.delete_env(:orchard_controller, key)
        previous -> Application.put_env(:orchard_controller, key, previous)
      end
    end
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
