defmodule Orchard.Repo.Migrations.TenantModelAccessMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.{Governance, Models, Repo}

  setup do
    :ok = Sandbox.checkout(Repo)

    {:ok, tenant_a} = create_tenant("a")
    {:ok, tenant_b} = create_tenant("b")
    {:ok, model} = create_model()

    %{model: model, tenant_a: tenant_a, tenant_b: tenant_b}
  end

  test "SPEC.md §10.9 makes Tenant and Model the unique access identity", context do
    assert {:ok, _result} = insert_access(context.tenant_a.id, context.model.id, nil)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "tenant_model_access_pkey"}}} =
             insert_access(context.tenant_a.id, context.model.id, nil)
  end

  test "SPEC.md §10.9 accepts same-Tenant and explicit global routing policies", context do
    tenant_policy_id = insert_policy!(context.tenant_a.id, "tenant-policy")
    global_policy_id = insert_policy!(nil, "global-policy")

    assert {:ok, _result} =
             insert_access(context.tenant_a.id, context.model.id, tenant_policy_id)

    other_model = create_model!("global-policy-model")

    assert {:ok, _result} =
             insert_access(context.tenant_b.id, other_model.id, global_policy_id)
  end

  test "SPEC.md §10.9 rejects cross-Tenant routing policy attachment", context do
    policy_id = insert_policy!(context.tenant_a.id, "tenant-a-only")

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "tenant_model_access_routing_policy_scope"}
            }} = insert_access(context.tenant_b.id, context.model.id, policy_id)
  end

  test "ADR 0021 keeps routing policy Tenant scope immutable", context do
    policy_id = insert_policy!(context.tenant_a.id, "immutable-scope")

    assert {:error, %Postgrex.Error{postgres: %{constraint: "routing_policies_tenant_immutable"}}} =
             Repo.query("UPDATE routing_policies SET tenant_id = $1 WHERE id = $2", [
               dump_uuid(context.tenant_b.id),
               dump_uuid(policy_id)
             ])
  end

  test "ADR 0021 rejects pool constraints before scheduler enforcement", context do
    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "routing_policies_pool_constraints_deferred"}
            }} =
             Repo.query(
               """
               INSERT INTO routing_policies (
                 tenant_id,
                 name,
                 allowed_pool_ids,
                 preferred_pool_ids,
                 residency_preference,
                 max_cold_start_ms,
                 max_queue_wait_ms,
                 priority,
                 inserted_at,
                 updated_at
               )
               VALUES ($1, 'invalid-pools', ARRAY[$2]::uuid[], '{}'::uuid[],
                       'allow_cold_load', 15000, 3000, 100, NOW(), NOW())
               """,
               [dump_uuid(context.tenant_a.id), dump_uuid(Ecto.UUID.generate())]
             )
  end

  test "ADR 0021 requires an explicit routing policy residency preference", context do
    assert {:error, %Postgrex.Error{postgres: %{column: "residency_preference"}}} =
             Repo.query(
               """
               INSERT INTO routing_policies (
                 tenant_id,
                 name,
                 allowed_pool_ids,
                 preferred_pool_ids,
                 max_cold_start_ms,
                 max_queue_wait_ms,
                 priority,
                 inserted_at,
                 updated_at
               )
               VALUES ($1, 'missing-residency', '{}'::uuid[], '{}'::uuid[],
                       15000, 3000, 100, NOW(), NOW())
               """,
               [dump_uuid(context.tenant_a.id)]
             )
  end

  test "SPEC.md §10.9 rejects invalid routing policy budgets", context do
    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "routing_policies_budgets_non_negative"}}} =
             Repo.query(
               """
               INSERT INTO routing_policies (
                 tenant_id,
                 name,
                 allowed_pool_ids,
                 preferred_pool_ids,
                 residency_preference,
                 max_cold_start_ms,
                 max_queue_wait_ms,
                 priority,
                 inserted_at,
                 updated_at
               )
               VALUES ($1, 'negative-budget', '{}'::uuid[], '{}'::uuid[],
                       'allow_cold_load', -1, 3000, 100, NOW(), NOW())
               """,
               [dump_uuid(context.tenant_a.id)]
             )
  end

  test "SPEC.md §10.9 rejects invalid routing policy residency", context do
    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "routing_policies_residency_preference_closed"}
            }} =
             Repo.query(
               """
               INSERT INTO routing_policies (
                 tenant_id,
                 name,
                 allowed_pool_ids,
                 preferred_pool_ids,
                 residency_preference,
                 max_cold_start_ms,
                 max_queue_wait_ms,
                 priority,
                 inserted_at,
                 updated_at
               )
               VALUES ($1, 'invalid-residency', '{}'::uuid[], '{}'::uuid[],
                       'anywhere', 15000, 3000, 100, NOW(), NOW())
               """,
               [dump_uuid(context.tenant_a.id)]
             )
  end

  test "ADR 0021 restricts Tenant deletion while it owns a routing policy" do
    tenant_id = insert_tenant!("policy-owner")
    _policy_id = insert_policy!(tenant_id, "owned-policy")

    assert {:error, %Postgrex.Error{postgres: %{constraint: "routing_policies_tenant_id_fkey"}}} =
             Repo.query("DELETE FROM tenants WHERE id = $1", [dump_uuid(tenant_id)])
  end

  test "SPEC.md §10.9 cascades access when its Model is deleted", context do
    assert {:ok, _result} = insert_access(context.tenant_a.id, context.model.id, nil)
    assert access_count(context.tenant_a.id, context.model.id) == 1

    assert {:ok, _model} = Repo.delete(context.model)
    assert access_count(context.tenant_a.id, context.model.id) == 0
  end

  test "SPEC.md §10.9 restricts policy deletion while access references it", context do
    policy_id = insert_policy!(context.tenant_a.id, "retained-policy")
    assert {:ok, _result} = insert_access(context.tenant_a.id, context.model.id, policy_id)

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "tenant_model_access_routing_policy_id_fkey"}
            }} =
             Repo.query("DELETE FROM routing_policies WHERE id = $1", [dump_uuid(policy_id)])
  end

  test "SPEC.md §10.9 cascades access when its Tenant is deleted", context do
    tenant_id = insert_tenant!("cascade")

    assert {:ok, _result} = insert_access(tenant_id, context.model.id, nil)
    assert access_count(tenant_id, context.model.id) == 1

    assert {:ok, %{num_rows: 1}} =
             Repo.query("DELETE FROM tenants WHERE id = $1", [dump_uuid(tenant_id)])

    assert access_count(tenant_id, context.model.id) == 0
  end

  defp create_tenant(suffix) do
    Governance.create_tenant(%{
      slug: "tenant-model-migration-#{suffix}-#{System.unique_integer([:positive])}",
      name: "Tenant Model Migration #{suffix}"
    })
  end

  defp create_model do
    create_model("tenant-model-migration-#{System.unique_integer([:positive])}")
  end

  defp create_model!(model_id) do
    {:ok, model} = create_model(model_id)
    model
  end

  defp create_model(model_id) do
    Models.create_model(%{
      model_id: model_id,
      version: "v1",
      state: :active,
      format: "mlx",
      capabilities: ["chat"],
      tokenizer: %{},
      artifact_uri: "file:///tmp/#{model_id}",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1,
      resident_memory_bytes: 1,
      kv_cache_bytes_per_token: 1,
      prefill_workspace_bytes_per_token: 1,
      runtime_requirements: %{}
    })
  end

  defp insert_tenant!(suffix) do
    assert {:ok, %{rows: [[tenant_id]]}} =
             Repo.query(
               """
               INSERT INTO tenants (slug, name, request_body_capture_mode, inserted_at, updated_at)
               VALUES ($1, $2, 'metadata', NOW(), NOW())
               RETURNING id
               """,
               [
                 "tenant-model-raw-#{suffix}-#{System.unique_integer([:positive])}",
                 "Tenant Model Raw #{suffix}"
               ]
             )

    Ecto.UUID.load!(tenant_id)
  end

  defp insert_policy!(tenant_id, name) do
    assert {:ok, %{rows: [[policy_id]]}} =
             Repo.query(
               """
               INSERT INTO routing_policies (
                 tenant_id,
                 name,
                 allowed_pool_ids,
                 preferred_pool_ids,
                 residency_preference,
                 max_cold_start_ms,
                 max_queue_wait_ms,
                 priority,
                 inserted_at,
                 updated_at
               )
               VALUES ($1, $2, '{}'::uuid[], '{}'::uuid[],
                       'allow_cold_load', 15000, 3000, 100, NOW(), NOW())
               RETURNING id
               """,
               [dump_uuid(tenant_id), name]
             )

    Ecto.UUID.load!(policy_id)
  end

  defp insert_access(tenant_id, model_id, policy_id) do
    Repo.query(
      """
      INSERT INTO tenant_model_access (
        tenant_id,
        model_id,
        enabled,
        routing_policy_id,
        inserted_at,
        updated_at
      )
      VALUES ($1, $2, true, $3, NOW(), NOW())
      """,
      [dump_uuid(tenant_id), dump_uuid(model_id), dump_uuid(policy_id)]
    )
  end

  defp access_count(tenant_id, model_id) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM tenant_model_access WHERE tenant_id = $1 AND model_id = $2",
        [dump_uuid(tenant_id), dump_uuid(model_id)]
      )

    count
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(value), do: Ecto.UUID.dump!(value)
end
