defmodule Orchard.ClusterManagement.ContractTest do
  use ExUnit.Case, async: true

  alias Orchard.ClusterManagement.{
    ActionPreview,
    ControlPlaneStatus,
    NodeStatus,
    ReasonCodes,
    SchedulerExplanation
  }

  @fixture_dir Path.expand("../../fixtures/cluster_management", __DIR__)

  test "reason-code vocabularies expose accepted fixed codes" do
    assert "node_not_active" in ReasonCodes.scheduler_rejection_codes()
    assert "previous_attempt_node_excluded" in ReasonCodes.scheduler_rejection_codes()
    assert "lower_tier_not_considered" in ReasonCodes.scheduler_skip_codes()
    assert "node_not_pending_admission" in ReasonCodes.action_blocker_codes()
    assert "drain_not_running" in ReasonCodes.action_blocker_codes()
    assert "lifecycle_transition_invalid" in ReasonCodes.action_blocker_codes()
    assert "node_unhealthy" in ReasonCodes.action_blocker_codes()
    assert "requires_reason" in ReasonCodes.confirmation_requirement_codes()
    assert "active_requests_present" in ReasonCodes.consequence_codes()
    assert "future_scheduling_revoked" in ReasonCodes.consequence_codes()
    assert "no_rejoin_with_same_node_id" in ReasonCodes.consequence_codes()
    assert "control_plane" in ReasonCodes.support_scope_codes()
    legacy_scope = Enum.join(["ha", "lite"], "_")
    refute legacy_scope in ReasonCodes.support_scope_codes()
  end

  test "node status golden fixture matches shared JSON contract" do
    fixture = fixture!("node_status_v1.json")
    assert {:ok, status} = NodeStatus.new(fixture)
    assert fixture == json_round_trip(NodeStatus.to_map(status))
  end

  test "action preview golden fixture separates blockers, warnings, consequences, and confirmations" do
    fixture = fixture!("action_preview_v1.json")
    assert {:ok, preview} = ActionPreview.new(fixture)

    rendered = json_round_trip(ActionPreview.to_map(preview))

    assert fixture == rendered
    assert [%{"code" => "policy_required"}] = rendered["blockers"]
    assert [%{"code" => "legacy_metadata"}] = rendered["warnings"]
    assert rendered["consequence_codes"] == ["existing_requests_continue_until_deadline"]
    assert rendered["confirmation_requirements"] == ["requires_reason"]
  end

  test "lifecycle action preview golden fixture matches shared JSON contract" do
    fixture = fixture!("action_preview_lifecycle_v1.json")
    assert {:ok, preview} = ActionPreview.new(fixture)

    rendered = json_round_trip(ActionPreview.to_map(preview))

    assert fixture == rendered
    assert rendered["action"] == "node_lifecycle.decommission"

    assert rendered["consequence_codes"] == [
             "future_scheduling_revoked",
             "no_rejoin_with_same_node_id"
           ]

    assert rendered["confirmation_requirements"] == [
             "requires_yes_flag",
             "requires_typed_node_id",
             "requires_decommission_consequence_acknowledgement"
           ]
  end

  test "scheduler explanation golden fixture validates fixed rejected and skipped codes" do
    fixture = fixture!("scheduler_explanation_v1.json")
    assert {:ok, explanation} = SchedulerExplanation.new(fixture)
    assert fixture == json_round_trip(SchedulerExplanation.to_map(explanation))
  end

  test "control-plane status golden fixture matches shared JSON contract" do
    fixture = fixture!("control_plane_status_v1.json")
    assert {:ok, status} = ControlPlaneStatus.new(fixture)
    assert fixture == json_round_trip(ControlPlaneStatus.to_map(status))
  end

  test "node status rejects unknown scheduling reason codes" do
    assert {:error, {:unknown_code, :scheduler_rejection, "surprise_reason"}} =
             NodeStatus.new(%{
               resource: %{type: :node, id: "node-1"},
               scheduling: %{eligible: false, reason_codes: ["surprise_reason"]}
             })
  end

  test "node status preserves the complete counterfactual dispatch-capacity evaluation" do
    assert {:ok, status} =
             NodeStatus.new(%{
               resource: %{type: :node, id: "node-1"},
               dispatch_capacity: %{
                 mode: :counterfactual,
                 counterfactual: true,
                 consumers_ready: false,
                 runtime_concurrency_enforcement_limit: 4,
                 controller_dispatch_ceiling: 2,
                 effective_dispatch_limit: 0,
                 controller_accounted_allocation: 0,
                 dispatch_headroom: 0,
                 placement_capacity: :not_applicable,
                 placement_headroom: nil,
                 authority_phase: :pre_cutover,
                 policy_state: :approved_explicit,
                 management_class: :production_managed,
                 authority_decision: :legacy_pre_cutover,
                 available_slots: 3,
                 legacy_pre_cutover_limit: 4,
                 legacy_pre_cutover_reported_allocation: 1,
                 legacy_pre_cutover_claim_count: 0,
                 legacy_pre_cutover_available_slots: 3,
                 eligible: true,
                 observation_time: ~U[2026-07-16 08:00:00Z],
                 reason_codes: [
                   :controller_dispatch_ceiling_not_yet_enforcing,
                   :dispatch_capacity_pre_cutover_legacy
                 ]
               }
             })

    capacity = NodeStatus.to_map(status).dispatch_capacity

    assert capacity.mode == "counterfactual"
    assert capacity.counterfactual == true
    assert capacity.consumers_ready == false
    assert capacity.eligible == true
    assert capacity.effective_dispatch_limit == 0
    assert capacity.dispatch_headroom == 0
    assert capacity.controller_dispatch_ceiling == 2
  end

  test "node status keeps dispatch-capacity booleans as booleans in both directions" do
    status =
      NodeStatus.new!(%{
        resource: %{type: :node, id: "node-1"},
        dispatch_capacity: %{
          counterfactual: false,
          consumers_ready: true,
          eligible: false,
          reason_codes: []
        }
      })

    capacity = NodeStatus.to_map(status).dispatch_capacity

    assert capacity.counterfactual == false
    assert capacity.consumers_ready == true
    assert capacity.eligible == false
  end

  test "node status rejects unknown dispatch-capacity reason codes" do
    assert {:error, {:unknown_dispatch_capacity_reason_code, "surprise_capacity_reason"}} =
             NodeStatus.new(%{
               resource: %{type: :node, id: "node-1"},
               dispatch_capacity: %{reason_codes: [:surprise_capacity_reason]}
             })
  end

  test "scheduler explanation rejects free-text-only rejected candidates" do
    assert {:error, :rejected_candidate_reason_codes_required} =
             SchedulerExplanation.new(%{
               rejected_candidates: [
                 %{
                   node_id: "node-1",
                   message: "node is not active",
                   reason_codes: []
                 }
               ]
             })
  end

  test "scheduler explanation rejects unknown rejected candidate codes" do
    assert {:error, {:unknown_code, :scheduler_rejection, "made_up"}} =
             SchedulerExplanation.new(%{
               rejected_candidates: [
                 %{node_id: "node-1", reason_codes: ["made_up"]}
               ]
             })
  end

  test "scheduler explanation accepts shared dispatch-capacity rejection codes" do
    assert {:ok, explanation} =
             SchedulerExplanation.new(%{
               rejected_candidates: [
                 %{
                   node_id: "node-1",
                   reason_codes: [
                     "runtime_capacity_observation_stale",
                     "dispatch_capacity_pre_cutover_legacy"
                   ]
                 }
               ]
             })

    assert explanation.rejected_candidates == [
             %{
               node_id: "node-1",
               target_ref: nil,
               eligible: false,
               tier: nil,
               score: nil,
               components: %{},
               diagnostics: %{},
               reason_codes: [
                 "runtime_capacity_observation_stale",
                 "dispatch_capacity_pre_cutover_legacy"
               ]
             }
           ]
  end

  test "scheduler explanation accepts an unavailable dispatch-capacity fact rejection" do
    assert {:ok, explanation} =
             SchedulerExplanation.new(%{
               rejected_candidates: [
                 %{
                   node_id: "node-1",
                   reason_codes: ["dispatch_capacity_facts_unavailable"]
                 }
               ]
             })

    assert [%{reason_codes: ["dispatch_capacity_facts_unavailable"]}] =
             explanation.rejected_candidates
  end

  test "scheduler explanation preserves additive target source and eligibility fields" do
    assert {:ok, explanation} =
             SchedulerExplanation.new(%{
               rejected_candidates: [
                 %{
                   node_id: "node-rejected",
                   target_ref: "beam:node-rejected",
                   eligible: false,
                   diagnostics: %{candidate_source: "monitor_snapshot"},
                   reason_codes: ["dispatch_capacity_facts_unavailable"]
                 }
               ],
               skipped_candidates: [
                 %{
                   node_id: "node-skipped",
                   target_ref: "grpc_compat:127.0.0.1:50071",
                   eligible: true,
                   diagnostics: %{candidate_source: "bounded_compatibility_probe"},
                   reason_codes: ["lower_tier_not_considered"]
                 }
               ]
             })

    assert [
             %{
               target_ref: "beam:node-rejected",
               eligible: false,
               diagnostics: rejected_diagnostics
             }
           ] =
             explanation.rejected_candidates

    assert rejected_diagnostics == %{candidate_source: "monitor_snapshot"}

    assert [
             %{
               target_ref: "grpc_compat:127.0.0.1:50071",
               eligible: true,
               diagnostics: skipped_diagnostics
             }
           ] = explanation.skipped_candidates

    assert skipped_diagnostics == %{candidate_source: "bounded_compatibility_probe"}
  end

  test "scheduler explanation keeps skipped candidates out of rejection vocabulary" do
    assert {:error, {:unknown_code, :scheduler_skip, "node_not_active"}} =
             SchedulerExplanation.new(%{
               skipped_candidates: [
                 %{node_id: "node-1", reason_codes: ["node_not_active"]}
               ]
             })
  end

  test "action preview rejects confirmation requirements masquerading as blockers" do
    assert {:error, {:unknown_code, :action_blocker, "requires_reason"}} =
             ActionPreview.new(%{
               blockers: [%{code: "requires_reason"}],
               confirmation_requirements: []
             })
  end

  test "action preview rejects unknown consequence codes" do
    assert {:error, {:unknown_code, :consequence, "restart_everything"}} =
             ActionPreview.new(%{
               consequence_codes: ["restart_everything"]
             })
  end

  defp fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp json_round_trip(map) do
    map
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
