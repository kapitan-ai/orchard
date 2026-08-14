defmodule Orchard.DispatchCapacity.FiveConsumerConformanceTest do
  use ExUnit.Case, async: true

  alias Orchard.DispatchCapacity.{AllocationAuthority, ConformanceFixture}
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.Inference.QueueManager

  @consumers [
    Orchard.Scheduler.MultiNode,
    Orchard.Scheduler.SingleNode,
    Orchard.Nodes,
    Orchard.Inference.QueueManager,
    Orchard.Dispatch.RequestDispatcher
  ]

  test "SPEC 4.6.2 all five consumers return one shared capacity evaluation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    input = ConformanceFixture.input()

    results =
      Enum.map(@consumers, & &1.evaluate_dispatch_capacity(authority, node_id, input))

    assert Enum.uniq(results) == [hd(results)]

    assert Map.take(hd(results), [
             :runtime_concurrency_enforcement_limit,
             :controller_dispatch_ceiling,
             :effective_dispatch_limit,
             :controller_accounted_allocation,
             :dispatch_headroom,
             :placement_capacity,
             :placement_headroom,
             :authority_phase,
             :policy_state,
             :management_class,
             :authority_decision,
             :available_slots,
             :eligible?,
             :reason_codes
           ]) == %{
             runtime_concurrency_enforcement_limit: 4,
             controller_dispatch_ceiling: 2,
             effective_dispatch_limit: 2,
             controller_accounted_allocation: 0,
             dispatch_headroom: 2,
             placement_capacity: {:valid, 0, 3},
             placement_headroom: 3,
             authority_phase: :enforcing,
             policy_state: :enforcing,
             management_class: :production_managed,
             authority_decision: :f11_enforcing,
             available_slots: 2,
             eligible?: true,
             reason_codes: []
           }
  end

  test "SPEC 4.9 all five consumers use temporary legacy slots without Dispatch Headroom" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()

    input = %Input{
      authority_phase: :pre_cutover,
      policy_presence: :present,
      policy_state: :shadow_legacy,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 2},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: :missing,
      controller_accounted_allocation: 99,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 1,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "legacy-conformance-claim",
               input,
               authority: authority
             )

    results =
      Enum.map(@consumers, & &1.evaluate_dispatch_capacity(authority, node_id, input))

    assert Enum.uniq(results) == [hd(results)]
    assert hd(results).authority_decision == :legacy_pre_cutover
    assert hd(results).dispatch_headroom == 0
    assert hd(results).legacy_pre_cutover_claim_count == 1
    assert hd(results).available_slots == 1
    assert hd(results).eligible?
    assert :released = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end
end
