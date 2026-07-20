defmodule Orchard.DispatchCapacity.DiagnosticsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Orchard.DispatchCapacity.{Authority, CapacityEvidence, Diagnostics, Policy}
  alias Orchard.Nodes.Node

  @now ~U[2026-07-16 08:00:00.000000Z]

  test "SPEC.md section 7.3.5 distinguishes missing policy without synthesizing one" do
    snapshot = snapshot(policy: nil)

    assert snapshot.counterfactual?
    refute snapshot.consumers_ready?
    assert snapshot.evaluation.authority_decision == :fail_closed
    assert snapshot.evaluation.controller_dispatch_ceiling == nil
    assert snapshot.evaluation.effective_dispatch_limit == 0
    assert snapshot.evaluation.dispatch_headroom == 0
    assert snapshot.evaluation.reason_codes == [:controller_dispatch_ceiling_missing]
  end

  test "SPEC.md section 7.3.5 exposes shadow legacy slots separately" do
    snapshot = snapshot(policy: shadow_policy(), temporary_legacy_claim_count: 1)

    assert snapshot.evaluation.policy_state == :shadow_legacy
    assert snapshot.evaluation.effective_dispatch_limit == 0
    assert snapshot.evaluation.dispatch_headroom == 0
    assert snapshot.evaluation.available_slots == 2

    assert snapshot.evaluation.reason_codes == [
             :dispatch_ceiling_not_approved,
             :dispatch_capacity_pre_cutover_legacy
           ]
  end

  test "SPEC.md section 7.3.5 labels an approved ceiling as not yet enforcing" do
    snapshot = snapshot(policy: approved_policy(2))

    assert snapshot.evaluation.controller_dispatch_ceiling == 2
    assert snapshot.evaluation.effective_dispatch_limit == 0
    assert snapshot.evaluation.dispatch_headroom == 0

    assert snapshot.evaluation.reason_codes == [
             :controller_dispatch_ceiling_not_yet_enforcing,
             :dispatch_capacity_pre_cutover_legacy
           ]
  end

  test "SPEC.md section 7.3.5 preserves an explicit zero ceiling" do
    snapshot = snapshot(policy: approved_policy(0))

    assert snapshot.evaluation.controller_dispatch_ceiling == 0

    assert snapshot.evaluation.reason_codes == [
             :controller_dispatch_ceiling_not_yet_enforcing,
             :dispatch_capacity_pre_cutover_legacy,
             :controller_dispatch_ceiling_zero
           ]
  end

  test "SPEC.md section 7.3.5 reports stale aggregate evidence" do
    evidence = evidence(observed_at: DateTime.add(@now, -31, :second))
    snapshot = snapshot(policy: approved_policy(2), evidence: evidence)

    assert snapshot.evaluation.available_slots == 0
    assert :runtime_capacity_observation_stale in snapshot.evaluation.reason_codes
  end

  test "SPEC.md section 7.3.5 reports malformed aggregate evidence with stable precedence" do
    evidence =
      evidence(validity: :invalid, runtime_concurrency_limit: -1, active_request_count: -1)

    snapshot = snapshot(policy: approved_policy(2), evidence: evidence)

    assert snapshot.evaluation.reason_codes == [
             :runtime_concurrency_limit_unknown,
             :runtime_active_request_count_legacy_fallback,
             :controller_dispatch_ceiling_not_yet_enforcing,
             :dispatch_capacity_pre_cutover_legacy
           ]
  end

  test "SPEC.md section 7.3.5 a saturated legacy node grants no slots on its reported active count" do
    evidence =
      evidence(validity: :missing, runtime_concurrency_limit: nil, active_request_count: 3)

    snapshot = snapshot(policy: approved_policy(2), evidence: evidence)

    assert snapshot.evaluation.available_slots == 0
    refute snapshot.evaluation.eligible?
    assert :runtime_concurrency_limit_exhausted in snapshot.evaluation.reason_codes
    refute :runtime_active_request_count_legacy_fallback in snapshot.evaluation.reason_codes
  end

  test "SPEC.md section 7.3.5 exposes degraded health without changing legacy eligibility" do
    snapshot = snapshot(policy: approved_policy(2), node: node_fixture(health: :degraded))

    assert snapshot.evaluation.eligible?
    assert :node_health_degraded in snapshot.evaluation.reason_codes
  end

  test "SPEC.md section 7.3.5 exposes invalid Controller-owned management classification" do
    snapshot = snapshot(policy: approved_policy(2), management_classification: {:error, :invalid})

    assert snapshot.evaluation.authority_decision == :fail_closed
    assert snapshot.evaluation.management_class == :invalid
    assert hd(snapshot.evaluation.reason_codes) == :runtime_endpoint_management_class_invalid
  end

  test "operator snapshots fail closed when persistence is unavailable or an ID is not durable" do
    log =
      capture_log(fn ->
        [snapshot] =
          Diagnostics.snapshots([node_fixture(id: "support-bundle-node")]) |> Map.values()

        assert snapshot.counterfactual?
        assert snapshot.evaluation.authority_decision == :fail_closed
        assert :controller_dispatch_ceiling_missing in snapshot.evaluation.reason_codes
      end)

    assert log =~ "could not read the dispatch-capacity authority"
    assert log =~ "fell back to fail-closed facts"
  end

  test "operator snapshot preserves the public string-keyed map input contract" do
    node = %{
      "id" => "550e8400-e29b-41d4-a716-446655440000",
      "state" => :active,
      "health" => :healthy,
      "last_heartbeat_at" => @now
    }

    snapshot =
      Diagnostics.snapshot(node,
        authority: authority(),
        policy: approved_policy(2),
        evidence: evidence(),
        management_classification: {:ok, :production_managed},
        controller_accounted_allocation: 0,
        placement_capacity: :not_applicable,
        now: @now,
        freshness_threshold_ms: 30_000
      )

    assert snapshot.evaluation.authority_decision == :legacy_pre_cutover
    assert snapshot.evaluation.eligible?
  end

  test "SPEC.md section 7.3.5 keeps an admitted Node identity trusted without capacity evidence" do
    snapshot = snapshot(evidence: nil)

    refute :runtime_endpoint_identity_untrusted in snapshot.evaluation.reason_codes
    assert :runtime_capacity_observation_stale in snapshot.evaluation.reason_codes
  end

  defp snapshot(overrides) do
    node = Keyword.get(overrides, :node, node_fixture())

    Diagnostics.snapshot(node,
      authority: Keyword.get(overrides, :authority, authority()),
      policy: Keyword.get(overrides, :policy, approved_policy(2)),
      evidence: Keyword.get(overrides, :evidence, evidence()),
      management_classification:
        Keyword.get(overrides, :management_classification, {:ok, :production_managed}),
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: Keyword.get(overrides, :temporary_legacy_claim_count, 0),
      now: @now,
      freshness_threshold_ms: 30_000
    )
  end

  defp authority do
    %Authority{singleton: true, enforcement_phase: :pre_cutover, required_contract_version: 1}
  end

  defp shadow_policy do
    %Policy{policy_state: :shadow_legacy, controller_dispatch_ceiling: nil, version: 1}
  end

  defp approved_policy(ceiling) do
    %Policy{
      policy_state: :approved_explicit,
      controller_dispatch_ceiling: ceiling,
      version: 1
    }
  end

  defp evidence(overrides \\ []) do
    struct!(
      CapacityEvidence,
      Keyword.merge(
        [
          validity: :valid,
          runtime_concurrency_limit: 4,
          active_request_count: 1,
          observed_at: @now
        ],
        overrides
      )
    )
  end

  defp node_fixture(overrides \\ []) do
    struct!(
      Node,
      Keyword.merge(
        [
          id: "550e8400-e29b-41d4-a716-446655440000",
          state: :active,
          health: :healthy,
          last_heartbeat_at: @now
        ],
        overrides
      )
    )
  end
end
