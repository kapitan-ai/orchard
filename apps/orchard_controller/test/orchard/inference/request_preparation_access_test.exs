defmodule Orchard.Inference.RequestPreparationAccessTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Governance
  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.Models
  alias Orchard.Models.Access

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, tenant} = Governance.create_tenant(%{slug: "prepare-access-#{suffix}", name: "Prepare"})
    model = create_model!(%{state: :active, max_context_tokens: 8_192})

    %{tenant: tenant, model: model}
  end

  test "SPEC.md §5.2 denies an active ungranted Model after tokenization", %{
    tenant: tenant,
    model: model
  } do
    assert {:error, :model_not_authorized} =
             ChatOrchestrator.prepare(params_for(model, "hello"), tenant_id: tenant.id)
  end

  test "SPEC.md §5.2 authorized requests preserve the canonical default routing snapshot", %{
    tenant: tenant,
    model: model
  } do
    grant_model_access!(tenant, model)

    assert {:ok, canonical, returned_model} =
             ChatOrchestrator.prepare(params_for(model, "hello"), tenant_id: tenant.id)

    assert returned_model.id == model.id
    assert canonical.resolved_policy.routing_policy_id == nil
    assert canonical.resolved_policy.allowed_pool_ids == []
    assert canonical.resolved_policy.residency_preference == :allow_cold_load
    assert canonical.admission.max_cold_start_ms == 15_000
    assert canonical.admission.queue_wait_ms == 3_000
  end

  test "SPEC.md §5.2 snapshots explicit routing values before execution", %{
    tenant: tenant,
    model: model
  } do
    {:ok, policy} =
      Access.create_routing_policy(%{
        tenant_id: tenant.id,
        name: "loaded-only",
        allowed_pool_ids: [],
        preferred_pool_ids: [],
        residency_preference: :required_loaded,
        max_cold_start_ms: 0,
        max_queue_wait_ms: 900,
        priority: 1
      })

    assert {:ok, _result} = Access.grant_model_access(tenant, model, policy.id)

    assert {:ok, canonical, returned_model} =
             ChatOrchestrator.prepare(params_for(model, "hello"), tenant_id: tenant.id)

    assert returned_model.id == model.id
    assert canonical.resolved_policy.routing_policy_id == policy.id
    assert canonical.resolved_policy.allowed_pool_ids == []
    assert canonical.resolved_policy.residency_preference == :required_loaded
    assert canonical.admission.max_cold_start_ms == 0
    assert canonical.admission.queue_wait_ms == 900
  end

  test "SPEC.md §5.2 disable affects new checks without mutating an authorized snapshot", %{
    tenant: tenant,
    model: model
  } do
    grant_model_access!(tenant, model)

    assert {:ok, authorized, _returned_model} =
             ChatOrchestrator.prepare(params_for(model, "hello"), tenant_id: tenant.id)

    assert {:ok, %{outcome: :disabled}} = Access.disable_model_access(tenant, model)
    assert Models.list_active_models_for_tenant(tenant.id) == []

    assert {:error, :model_not_authorized} =
             ChatOrchestrator.prepare(params_for(model, "hello"), tenant_id: tenant.id)

    assert authorized.resolved_policy.routing_policy_id == nil
    assert authorized.resolved_policy.residency_preference == :allow_cold_load
    assert authorized.admission.max_cold_start_ms == 15_000
  end

  test "SPEC.md §5.2 context overflow precedes model authorization denial", %{
    tenant: tenant,
    model: model
  } do
    content = Enum.map_join(1..8_200, " ", &"word#{&1}")

    assert {:error, {:context_overflow, _detail}} =
             ChatOrchestrator.prepare(params_for(model, content), tenant_id: tenant.id)
  end

  test "SPEC.md §5.2 missing Model precedence remains model_not_found", %{tenant: tenant} do
    params = %{
      "model" => "missing/model@v1",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 1
    }

    assert {:error, {:model_not_found, _detail}} =
             ChatOrchestrator.prepare(params, tenant_id: tenant.id)
  end

  defp params_for(model, content) do
    %{
      "model" => "#{model.model_id}@#{model.version}",
      "messages" => [%{"role" => "user", "content" => content}],
      "max_tokens" => 1
    }
  end
end
