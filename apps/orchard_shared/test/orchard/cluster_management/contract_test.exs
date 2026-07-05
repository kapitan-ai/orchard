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
    assert "lower_tier_not_considered" in ReasonCodes.scheduler_skip_codes()
    assert "node_not_pending_admission" in ReasonCodes.action_blocker_codes()
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
