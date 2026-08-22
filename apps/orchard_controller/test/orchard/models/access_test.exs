defmodule Orchard.Models.AccessTest.InvalidAuditLog do
  alias Orchard.Governance.AuditLog

  def changeset(audit_log, attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:target_type)
    AuditLog.changeset(audit_log, attrs)
  end
end

defmodule Orchard.Models.AccessTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.{AuditLog, Tenant}
  alias Orchard.Models.{Access, RoutingPolicy, TenantModelAccess}

  setup do
    previous = Application.get_env(:orchard_controller, :governance_audit_log_impl)

    on_exit(fn ->
      if previous do
        Application.put_env(:orchard_controller, :governance_audit_log_impl, previous)
      else
        Application.delete_env(:orchard_controller, :governance_audit_log_impl)
      end
    end)

    tenant = create_tenant!("access-a")
    model = create_model!(%{state: :active})

    %{tenant: tenant, model: model}
  end

  describe "routing policies" do
    test "rejects a policy whose cold-path deadline exceeds the deployment ceiling" do
      changeset =
        RoutingPolicy.changeset(%RoutingPolicy{}, %{
          name: "too-long",
          residency_preference: :allow_cold_load,
          max_cold_start_ms: 998_000,
          max_queue_wait_ms: 3_000,
          priority: 10,
          allowed_pool_ids: [],
          preferred_pool_ids: []
        })

      assert "effective request deadline 1006000 ms exceeds deployment ceiling 1000000 ms" in errors_on(
               changeset
             ).max_cold_start_ms
    end

    test "accepts a policy exactly at the deployment ceiling" do
      changeset =
        RoutingPolicy.changeset(%RoutingPolicy{}, %{
          name: "at-ceiling",
          residency_preference: :allow_cold_load,
          max_cold_start_ms: 992_000,
          max_queue_wait_ms: 3_000,
          priority: 10,
          allowed_pool_ids: [],
          preferred_pool_ids: []
        })

      assert changeset.valid?
    end

    test "non-cold policies do not count unused queue or cold budgets" do
      changeset =
        RoutingPolicy.changeset(%RoutingPolicy{}, %{
          name: "loaded-only",
          residency_preference: :required_loaded,
          max_cold_start_ms: 2_000_000,
          max_queue_wait_ms: 2_000_000,
          priority: 10,
          allowed_pool_ids: [],
          preferred_pool_ids: []
        })

      assert changeset.valid?
    end

    test "SPEC.md §10.9 creates and lists Tenant and global policies with atomic audit", %{
      tenant: tenant
    } do
      assert {:ok, tenant_policy} =
               Access.create_routing_policy(policy_attrs(tenant.id, "tenant-policy"),
                 surface: :orchardctl
               )

      assert {:ok, global_policy} =
               Access.create_routing_policy(policy_attrs(nil, "global-policy"))

      assert {:ok, [listed_tenant]} = Access.list_routing_policies(tenant)
      assert listed_tenant.id == tenant_policy.id

      assert {:ok, [listed_global]} = Access.list_routing_policies(:global)
      assert listed_global.id == global_policy.id

      tenant_audit = audit_for!("routing_policy.created", tenant_policy.id)
      assert tenant_audit.scope == "tenant"
      assert tenant_audit.tenant_id == tenant.id
      assert tenant_audit.payload["surface"] == "orchardctl"

      global_audit = audit_for!("routing_policy.created", global_policy.id)
      assert global_audit.scope == "cluster"
      assert global_audit.tenant_id == nil
    end

    test "SPEC.md §10.9 rolls back policy creation when audit insertion fails", %{tenant: tenant} do
      Application.put_env(
        :orchard_controller,
        :governance_audit_log_impl,
        Orchard.Models.AccessTest.InvalidAuditLog
      )

      assert {:error, %Ecto.Changeset{}} =
               Access.create_routing_policy(policy_attrs(tenant.id, "rolled-back"))

      refute Repo.get_by(RoutingPolicy, tenant_id: tenant.id, name: "rolled-back")
    end
  end

  describe "model access lifecycle" do
    test "SPEC.md §5.2 and §6.6 grants deny-by-default access with canonical defaults", %{
      tenant: tenant,
      model: model
    } do
      assert {:error, :model_not_authorized} = Access.authorize(tenant.id, model.id)

      assert {:ok, %{outcome: :created, access: access}} =
               Access.grant_model_access(tenant, model, nil, surface: :orchardctl)

      assert access.enabled
      assert access.routing_policy_id == nil
      assert {:ok, resolution} = Access.authorize(tenant.id, model.id)

      assert resolution == [
               routing_policy_id: nil,
               allowed_pool_ids: [],
               residency_preference: :allow_cold_load,
               max_cold_start_ms: 15_000,
               queue_wait_ms: 3_000
             ]

      assert {:ok, %{outcome: :unchanged}} = Access.grant_model_access(tenant, model)
      assert audit_count("tenant_model_access.granted", access_target(tenant, model)) == 1
    end

    test "SPEC.md §10.9 attaches same-Tenant and global policies but rejects cross-Tenant policy",
         %{tenant: tenant, model: model} do
      other_tenant = create_tenant!("access-b")
      own_policy = create_policy!(tenant.id, "own")
      other_policy = create_policy!(other_tenant.id, "other")
      global_policy = create_policy!(nil, "global")

      assert {:error, :routing_policy_scope_mismatch} =
               Access.grant_model_access(tenant, model, other_policy.id)

      refute Repo.get_by(TenantModelAccess, tenant_id: tenant.id, model_id: model.id)

      assert {:ok, %{outcome: :created}} =
               Access.grant_model_access(tenant, model, own_policy.id)

      assert {:ok, own_resolution} = Access.authorize(tenant.id, model.id)
      assert own_resolution[:routing_policy_id] == own_policy.id
      assert own_resolution[:residency_preference] == :required_loaded
      assert own_resolution[:max_cold_start_ms] == 0

      assert {:ok, %{outcome: :policy_changed}} =
               Access.grant_model_access(tenant, model, global_policy.id)

      assert {:ok, global_resolution} = Access.authorize(tenant.id, model.id)
      assert global_resolution[:routing_policy_id] == global_policy.id
    end

    test "SPEC.md §10.9 disable preserves policy, re-enable can clear it, and no-ops do not audit",
         %{tenant: tenant, model: model} do
      policy = create_policy!(tenant.id, "preserved")
      assert {:ok, %{access: granted}} = Access.grant_model_access(tenant, model, policy.id)

      assert {:ok, %{outcome: :disabled, access: disabled}} =
               Access.disable_model_access(tenant, model)

      refute disabled.enabled
      assert disabled.routing_policy_id == policy.id
      assert {:error, :model_not_authorized} = Access.authorize(tenant.id, model.id)

      assert {:ok, %{outcome: :already_disabled}} = Access.disable_model_access(tenant, model)

      target = access_target(tenant, model)
      assert audit_count("tenant_model_access.disabled", target) == 1

      assert {:ok, %{outcome: :enabled, access: enabled}} =
               Access.grant_model_access(tenant, model)

      assert enabled.enabled
      assert enabled.routing_policy_id == nil
      assert audit_count("tenant_model_access.enabled", target) == 1
      assert granted.tenant_id == tenant.id
    end

    test "SPEC.md §10.9 revoke removes only access and repeated revoke is deterministic", %{
      tenant: tenant,
      model: model
    } do
      policy = create_policy!(tenant.id, "retained")
      assert {:ok, %{outcome: :created}} = Access.grant_model_access(tenant, model, policy.id)

      assert {:ok, %{outcome: :revoked}} = Access.revoke_model_access(tenant, model)
      assert Repo.get(RoutingPolicy, policy.id)
      refute Repo.get_by(TenantModelAccess, tenant_id: tenant.id, model_id: model.id)
      assert {:error, :model_not_authorized} = Access.authorize(tenant.id, model.id)

      assert {:ok, %{outcome: :not_granted}} = Access.revoke_model_access(tenant, model)
      assert audit_count("tenant_model_access.revoked", access_target(tenant, model)) == 1
    end

    test "SPEC.md §5.2 isolates authorization and listing between Tenants", %{
      tenant: tenant,
      model: model
    } do
      other_tenant = create_tenant!("access-c")
      assert {:ok, %{outcome: :created}} = Access.grant_model_access(tenant, model)

      assert {:ok, _resolution} = Access.authorize(tenant.id, model.id)
      assert {:error, :model_not_authorized} = Access.authorize(other_tenant.id, model.id)

      assert {:ok, [listed]} = Access.list_model_access(tenant)
      assert listed.model.id == model.id
      assert {:ok, []} = Access.list_model_access(other_tenant)
    end

    test "SPEC.md §10.9 concurrent grants are idempotent and write one audit row", %{
      tenant: tenant,
      model: model
    } do
      parent = self()
      start_ref = make_ref()

      task = fn ->
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:grant_ready, self()})

          receive do
            ^start_ref -> Access.grant_model_access(tenant, model)
          end
        end)
      end

      task_one = task.()
      task_two = task.()
      assert_receive {:grant_ready, _pid}, 1_000
      assert_receive {:grant_ready, _pid}, 1_000
      send(task_one.pid, start_ref)
      send(task_two.pid, start_ref)

      results = [Task.await(task_one, 5_000), Task.await(task_two, 5_000)]
      outcomes = Enum.map(results, fn {:ok, result} -> result.outcome end)
      assert Enum.sort(outcomes) == [:created, :unchanged]

      assert Repo.aggregate(
               from(access in TenantModelAccess,
                 where: access.tenant_id == ^tenant.id and access.model_id == ^model.id
               ),
               :count
             ) == 1

      assert audit_count("tenant_model_access.granted", access_target(tenant, model)) == 1
    end

    test "SPEC.md §10.9 rolls back grant state when audit insertion fails", %{
      tenant: tenant,
      model: model
    } do
      Application.put_env(
        :orchard_controller,
        :governance_audit_log_impl,
        Orchard.Models.AccessTest.InvalidAuditLog
      )

      assert {:error, %Ecto.Changeset{}} = Access.grant_model_access(tenant, model)
      refute Repo.get_by(TenantModelAccess, tenant_id: tenant.id, model_id: model.id)
    end
  end

  defp create_tenant!(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, tenant} = Governance.create_tenant(%{slug: "#{prefix}-#{suffix}", name: prefix})
    tenant
  end

  defp policy_attrs(tenant_id, name) do
    %{
      tenant_id: tenant_id,
      name: name,
      residency_preference: :required_loaded,
      max_cold_start_ms: 0,
      max_queue_wait_ms: 750,
      priority: 10,
      allowed_pool_ids: [],
      preferred_pool_ids: []
    }
  end

  defp create_policy!(tenant_id, name) do
    {:ok, policy} = Access.create_routing_policy(policy_attrs(tenant_id, name))
    policy
  end

  defp audit_for!(action, target_id) do
    Repo.get_by!(AuditLog, action: action, target_id: target_id)
  end

  defp audit_count(action, target_id) do
    Repo.aggregate(
      from(audit in AuditLog,
        where: audit.action == ^action and audit.target_id == ^target_id
      ),
      :count,
      :id
    )
  end

  defp access_target(%Tenant{id: tenant_id}, model), do: "#{tenant_id}:#{model.id}"
end
