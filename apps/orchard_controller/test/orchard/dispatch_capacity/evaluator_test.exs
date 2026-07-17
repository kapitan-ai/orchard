defmodule Orchard.DispatchCapacity.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Orchard.ClusterManagement.{NodeStatus, ReasonCodes}
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.Evaluator.Input

  test "SPEC.md §7.3.1 every evaluator reason code renders on the shared status contract" do
    assert Evaluator.reason_precedence() ==
             Enum.map(ReasonCodes.dispatch_capacity_codes(), &String.to_existing_atom/1)

    assert {:ok, status} =
             NodeStatus.new(%{
               resource: %{type: "node", id: Ecto.UUID.generate()},
               dispatch_capacity: %{reason_codes: Evaluator.reason_precedence()}
             })

    assert status.dispatch_capacity.reason_codes == ReasonCodes.dispatch_capacity_codes()
  end

  describe "production phase-policy truth table" do
    test "returns the required decision for every phase-policy combination" do
      cases = [
        {:pre_cutover, :shadow_legacy, :missing, :legacy_pre_cutover,
         [:dispatch_ceiling_not_approved, :dispatch_capacity_pre_cutover_legacy]},
        {:pre_cutover, :approved_explicit, {:valid, 2}, :legacy_pre_cutover,
         [
           :controller_dispatch_ceiling_not_yet_enforcing,
           :dispatch_capacity_pre_cutover_legacy
         ]},
        {:pre_cutover, :enforcing, {:valid, 2}, :fail_closed,
         [:dispatch_capacity_phase_policy_mismatch]},
        {:enforcing, :shadow_legacy, :missing, :fail_closed,
         [:dispatch_capacity_phase_policy_mismatch]},
        {:enforcing, :approved_explicit, {:valid, 2}, :fail_closed,
         [:dispatch_capacity_phase_policy_mismatch]},
        {:enforcing, :enforcing, {:valid, 2}, :f11_enforcing, []}
      ]

      for {phase, policy, ceiling, decision, reasons} <- cases do
        result =
          evaluate(%{
            authority_phase: phase,
            policy_state: policy,
            controller_dispatch_ceiling: ceiling
          })

        assert result.authority_decision == decision
        assert result.reason_codes == reasons
      end
    end

    test "distinguishes missing, invalid, and shadow-mismatched policy" do
      assert evaluate(%{policy_presence: :missing}).reason_codes ==
               [:controller_dispatch_ceiling_missing]

      assert evaluate(%{controller_dispatch_ceiling: :missing}).reason_codes ==
               [:controller_dispatch_ceiling_missing]

      assert evaluate(%{controller_dispatch_ceiling: :invalid}).reason_codes ==
               [:controller_dispatch_ceiling_invalid]

      result =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: {:valid, 1}
        })

      assert result.reason_codes == [:dispatch_ceiling_shadow_mismatch]
    end

    test "reports phase-policy and ceiling integrity independently" do
      missing =
        evaluate(%{
          authority_phase: :enforcing,
          policy_state: :approved_explicit,
          controller_dispatch_ceiling: :missing
        })

      assert missing.reason_codes == [
               :dispatch_capacity_phase_policy_mismatch,
               :controller_dispatch_ceiling_missing
             ]

      invalid =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :enforcing,
          controller_dispatch_ceiling: :invalid
        })

      assert invalid.reason_codes == [
               :dispatch_capacity_phase_policy_mismatch,
               :controller_dispatch_ceiling_invalid
             ]
    end
  end

  describe "F11 authority" do
    test "uses runtime, ceiling, and equal bounds deterministically" do
      cases = [
        {2, 4, 1, 2, 1},
        {4, 2, 1, 2, 1},
        {3, 3, 1, 3, 2}
      ]

      for {runtime, ceiling, allocation, effective, headroom} <- cases do
        result =
          evaluate(%{
            runtime_concurrency_limit: {:valid, runtime},
            controller_dispatch_ceiling: {:valid, ceiling},
            controller_accounted_allocation: allocation
          })

        assert result.runtime_concurrency_enforcement_limit == runtime
        assert result.controller_dispatch_ceiling == ceiling
        assert result.effective_dispatch_limit == effective
        assert result.controller_accounted_allocation == allocation
        assert result.dispatch_headroom == headroom
        assert result.available_slots == headroom
        assert result.eligible?
        assert result.reason_codes == []
      end
    end

    test "preserves explicit zero and over-allocation after lowering" do
      zero = evaluate(%{controller_dispatch_ceiling: {:valid, 0}})

      assert zero.controller_dispatch_ceiling == 0
      assert zero.effective_dispatch_limit == 0
      assert zero.dispatch_headroom == 0
      refute zero.eligible?

      assert zero.reason_codes == [
               :controller_dispatch_ceiling_zero,
               :controller_dispatch_ceiling_exhausted,
               :dispatch_headroom_exhausted
             ]

      lowered =
        evaluate(%{
          runtime_concurrency_limit: {:valid, 4},
          controller_dispatch_ceiling: {:valid, 2},
          controller_accounted_allocation: 3
        })

      assert lowered.effective_dispatch_limit == 2
      assert lowered.controller_accounted_allocation == 3
      assert lowered.dispatch_headroom == 0

      assert lowered.reason_codes == [
               :controller_dispatch_ceiling_exhausted,
               :dispatch_headroom_exhausted
             ]
    end

    test "rejects an untagged Controller ceiling" do
      result = evaluate(%{controller_dispatch_ceiling: 2})

      assert result.authority_decision == :fail_closed
      assert result.controller_dispatch_ceiling == nil
      assert result.reason_codes == [:controller_dispatch_ceiling_invalid]
    end

    test "reports the binding exhaustion reason with deterministic equal-bound precedence" do
      runtime_bound =
        evaluate(%{
          runtime_concurrency_limit: {:valid, 2},
          controller_dispatch_ceiling: {:valid, 4},
          controller_accounted_allocation: 2
        })

      assert runtime_bound.reason_codes == [
               :runtime_concurrency_limit_exhausted,
               :dispatch_headroom_exhausted
             ]

      equal_bound =
        evaluate(%{
          runtime_concurrency_limit: {:valid, 2},
          controller_dispatch_ceiling: {:valid, 2},
          controller_accounted_allocation: 2
        })

      assert equal_bound.reason_codes == [
               :controller_dispatch_ceiling_exhausted,
               :dispatch_headroom_exhausted
             ]
    end

    test "fails closed independently for every production prerequisite" do
      cases = [
        {%{trusted_identity?: false}, :runtime_endpoint_identity_untrusted},
        {%{lifecycle_state: :removed}, :node_lifecycle_not_active},
        {%{health: :degraded}, :node_health_not_healthy},
        {%{health: :unhealthy}, :node_health_unhealthy},
        {%{health: :unknown}, :node_health_invalid},
        {%{heartbeat_fresh?: false}, :node_heartbeat_stale},
        {%{capacity_observation_fresh?: false}, :runtime_capacity_observation_stale},
        {%{runtime_concurrency_limit: :missing}, :runtime_concurrency_limit_unknown},
        {%{runtime_concurrency_limit: {:valid, 0}}, :runtime_concurrency_limit_unknown},
        {%{runtime_concurrency_limit: :invalid}, :runtime_concurrency_limit_unknown},
        {%{controller_accounted_allocation: :invalid}, :controller_accounted_allocation_invalid}
      ]

      for {overrides, reason} <- cases do
        result = evaluate(overrides)
        assert result.effective_dispatch_limit == 0
        assert result.dispatch_headroom == 0
        refute result.eligible?
        assert result.reason_codes == [reason]
      end
    end

    test "routing gates affect eligibility but not canonical arithmetic" do
      cases = [
        {:pool_eligible?, :pool_not_allowed},
        {:format_eligible?, :model_format_unsupported},
        {:memory_eligible?, :memory_headroom_insufficient},
        {:breaker_eligible?, :circuit_breaker_open}
      ]

      for {gate, reason} <- cases do
        result = evaluate(%{gate => false})
        assert result.effective_dispatch_limit == 2
        assert result.dispatch_headroom == 1
        refute result.eligible?
        assert result.reason_codes == [reason]
      end
    end
  end

  describe "pre-cutover and unmanaged legacy decisions" do
    test "keeps canonical values zero and subtracts reported work and claims" do
      result =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :approved_explicit,
          runtime_concurrency_limit: {:valid, 3},
          aggregate_active_count: {:valid, 1},
          temporary_legacy_claim_count: 1
        })

      assert result.authority_decision == :legacy_pre_cutover
      assert result.effective_dispatch_limit == 0
      assert result.dispatch_headroom == 0
      assert result.legacy_pre_cutover_limit == 3
      assert result.legacy_pre_cutover_reported_allocation == 1
      assert result.legacy_pre_cutover_claim_count == 1
      assert result.legacy_pre_cutover_available_slots == 1
      assert result.available_slots == 1
      assert result.eligible?

      assert result.reason_codes == [
               :controller_dispatch_ceiling_not_yet_enforcing,
               :dispatch_capacity_pre_cutover_legacy
             ]
    end

    test "treats an untagged active count as malformed and claims can exhaust slots" do
      fallback =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: :missing,
          runtime_concurrency_limit: {:valid, 2},
          aggregate_active_count: 1,
          temporary_legacy_claim_count: 1
        })

      assert fallback.legacy_pre_cutover_reported_allocation == 0
      assert fallback.available_slots == 1

      assert fallback.reason_codes == [
               :dispatch_ceiling_not_approved,
               :runtime_active_request_count_legacy_fallback,
               :dispatch_capacity_pre_cutover_legacy
             ]

      exhausted =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: :missing,
          runtime_concurrency_limit: {:valid, 2},
          aggregate_active_count: {:valid, 1},
          temporary_legacy_claim_count: 1
        })

      assert exhausted.available_slots == 0
      refute exhausted.eligible?

      assert exhausted.reason_codes == [
               :dispatch_ceiling_not_approved,
               :dispatch_capacity_pre_cutover_legacy,
               :runtime_concurrency_limit_exhausted
             ]
    end

    test "applies frozen fallbacks only with fresh evidence" do
      fallback =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: :missing,
          runtime_concurrency_limit: :invalid,
          aggregate_active_count: :missing,
          temporary_legacy_claim_count: 0
        })

      assert fallback.eligible?

      assert fallback.reason_codes == [
               :dispatch_ceiling_not_approved,
               :runtime_concurrency_limit_unknown,
               :runtime_active_request_count_legacy_fallback,
               :dispatch_capacity_pre_cutover_legacy
             ]

      stale =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: :missing,
          capacity_observation_fresh?: false,
          runtime_concurrency_limit: :invalid,
          aggregate_active_count: :missing
        })

      refute stale.eligible?

      assert stale.reason_codes == [
               :dispatch_ceiling_not_approved,
               :runtime_capacity_observation_stale,
               :dispatch_capacity_pre_cutover_legacy
             ]
    end

    test "allows degraded legacy health and fails for invalid claims" do
      degraded =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: :missing,
          health: :degraded
        })

      assert degraded.eligible?

      assert degraded.reason_codes == [
               :dispatch_ceiling_not_approved,
               :node_health_degraded,
               :dispatch_capacity_pre_cutover_legacy
             ]

      invalid_claims =
        evaluate(%{
          authority_phase: :pre_cutover,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: :missing,
          temporary_legacy_claim_count: :invalid
        })

      refute invalid_claims.eligible?

      assert invalid_claims.reason_codes == [
               :dispatch_ceiling_not_approved,
               :temporary_legacy_claim_count_invalid,
               :dispatch_capacity_pre_cutover_legacy
             ]
    end

    test "explicit unmanaged classes ignore production policy and do not expose a ceiling" do
      for {class, decision} <- [
            {:unmanaged_source_development, :unmanaged_source_development},
            {:unmanaged_compatibility, :unmanaged_compatibility}
          ] do
        result =
          evaluate(%{
            management_classification: {:ok, class},
            authority_phase: :invalid,
            policy_state: :missing,
            controller_dispatch_ceiling: {:valid, 9},
            runtime_concurrency_limit: {:valid, 3},
            aggregate_active_count: {:valid, 1}
          })

        assert result.authority_decision == decision
        assert result.controller_dispatch_ceiling == nil
        assert result.available_slots == 2
        assert result.eligible?
        assert result.reason_codes == []
      end
    end

    test "unmanaged fallback requires a fresh observation" do
      fallback =
        evaluate(%{
          management_classification: {:ok, :unmanaged_compatibility},
          runtime_concurrency_limit: :missing,
          aggregate_active_count: :invalid
        })

      assert fallback.available_slots == 1
      assert fallback.eligible?

      assert fallback.reason_codes == [
               :runtime_concurrency_limit_unknown,
               :runtime_active_request_count_legacy_fallback
             ]

      stale =
        evaluate(%{
          management_classification: {:ok, :unmanaged_compatibility},
          capacity_observation_fresh?: false,
          runtime_concurrency_limit: :missing,
          aggregate_active_count: :invalid
        })

      assert stale.available_slots == 0
      refute stale.eligible?
      assert stale.reason_codes == [:runtime_capacity_observation_stale]
    end

    test "invalid classification cannot obtain legacy fallback" do
      for {classification, reason} <- [
            {{:error, :runtime_endpoint_management_class_missing},
             :runtime_endpoint_management_class_missing},
            {{:error, :runtime_endpoint_management_class_invalid},
             :runtime_endpoint_management_class_invalid},
            {:malformed, :runtime_endpoint_management_class_invalid}
          ] do
        result =
          evaluate(%{
            management_classification: classification,
            runtime_concurrency_limit: :missing,
            aggregate_active_count: :missing
          })

        assert result.authority_decision == :fail_closed
        assert result.available_slots == 0
        refute result.eligible?
        assert result.reason_codes == [reason]
      end
    end
  end

  describe "placement bounds and reason order" do
    test "placement can reduce but never increase aggregate capacity" do
      tighter =
        evaluate(%{
          controller_accounted_allocation: 0,
          placement_capacity: {:valid, 1, 2}
        })

      assert tighter.dispatch_headroom == 2
      assert tighter.available_slots == 1
      assert tighter.placement_headroom == 1

      aggregate_tighter =
        evaluate(%{
          controller_accounted_allocation: 1,
          placement_capacity: {:valid, 0, 9}
        })

      assert aggregate_tighter.available_slots == 1
    end

    test "unknown, invalid, and exhausted placement fail eligibility" do
      cases = [
        {:unknown, [:placement_capacity_unknown]},
        {:invalid, [:placement_capacity_invalid]},
        {{:valid, 2, 2}, [:placement_capacity_exhausted]},
        {{:valid, -1, 2}, [:placement_capacity_invalid]}
      ]

      for {placement, reasons} <- cases do
        result = evaluate(%{placement_capacity: placement})
        assert result.available_slots == 0
        refute result.eligible?
        assert result.reason_codes == reasons
      end
    end

    test "orders and deduplicates reasons by stable precedence" do
      result =
        evaluate(%{
          management_classification: {:error, :runtime_endpoint_management_class_invalid},
          trusted_identity?: false,
          capacity_observation_fresh?: false,
          pool_eligible?: false,
          placement_capacity: :invalid
        })

      assert result.reason_codes == [
               :runtime_endpoint_management_class_invalid,
               :runtime_endpoint_identity_untrusted,
               :runtime_capacity_observation_stale,
               :pool_not_allowed,
               :placement_capacity_invalid
             ]
    end
  end

  defp evaluate(overrides) do
    defaults = %{
      authority_phase: :enforcing,
      policy_presence: :present,
      policy_state: :enforcing,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-16 00:00:00Z],
      runtime_concurrency_limit: {:valid, 4},
      aggregate_active_count: {:valid, 1},
      controller_dispatch_ceiling: {:valid, 2},
      controller_accounted_allocation: 1,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }

    defaults
    |> Map.merge(overrides)
    |> then(&struct!(Input, &1))
    |> Evaluator.evaluate()
  end
end
