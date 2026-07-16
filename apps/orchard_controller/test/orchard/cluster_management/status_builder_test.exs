defmodule Orchard.ClusterManagement.StatusBuilderTest do
  use Orchard.DataCase, async: false

  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.DispatchCapacity.Diagnostics.Snapshot, as: CapacitySnapshot
  alias Orchard.DispatchCapacity.Evaluator.Result, as: CapacityResult
  alias Orchard.Nodes
  alias Orchard.Nodes.AdmissionCandidate
  alias Orchard.Nodes.Node
  alias Orchard.Repo

  import Orchard.TestSupport.ToolRegistryTestSupport, only: [with_inference_overrides: 2]

  describe "node status" do
    test "active fresh healthy node is schedulable" do
      node =
        insert_node!(%{
          state: :active,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        })

      status = StatusBuilder.node_status_map(node)

      assert status.scheduling.eligible == true
      assert status.scheduling.reason_codes == []
      assert status.lifecycle.state == "active"
      assert status.admission.category == "admitted"
      assert status.freshness.status == "fresh"
    end

    test "registered node is not admitted and not schedulable" do
      node =
        insert_node!(%{
          state: :registered,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        })

      status = StatusBuilder.node_status_map(node)

      assert status.admission.category == "pending_registered"
      assert status.scheduling.eligible == false
      assert status.scheduling.reason_codes == ["node_not_admitted"]
    end

    test "stale active node reports observation freshness reason" do
      node =
        insert_node!(%{
          state: :active,
          health: :healthy,
          last_heartbeat_at: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      status = StatusBuilder.node_status_map(node)

      assert status.scheduling.eligible == false
      assert "node_observation_stale" in status.scheduling.reason_codes
      assert status.freshness.status == "unreachable"
    end

    test "heartbeat between the two thresholds is reported as stale but remains schedulable" do
      with_inference_overrides(
        [node_freshness_threshold_ms: 30_000, node_unreachable_threshold_ms: 15_000],
        fn ->
          node =
            insert_node!(%{
              state: :active,
              health: :healthy,
              last_heartbeat_at: DateTime.add(DateTime.utc_now(), -20, :second)
            })

          status = StatusBuilder.node_status_map(node)

          assert status.freshness.status == "stale"
          assert status.scheduling.eligible == true
          assert status.scheduling.reason_codes == []
          assert Enum.map(Nodes.schedulable_nodes(), & &1.id) == [node.id]
        end
      )
    end

    test "heartbeat past the freshness cutoff is ineligible even when unreachable threshold is longer" do
      with_inference_overrides(
        [node_freshness_threshold_ms: 15_000, node_unreachable_threshold_ms: 60_000],
        fn ->
          node =
            insert_node!(%{
              state: :active,
              health: :healthy,
              last_heartbeat_at: DateTime.add(DateTime.utc_now(), -30, :second)
            })

          status = StatusBuilder.node_status_map(node)

          assert status.freshness.status == "stale"
          assert status.scheduling.eligible == false
          assert "node_observation_stale" in status.scheduling.reason_codes
          assert Nodes.schedulable_nodes() == []
        end
      )
    end

    test "unknown node state resolves without infinite recursion" do
      status =
        StatusBuilder.node_status_map(%{
          id: Ecto.UUID.generate(),
          state: nil,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        })

      assert status.admission.category == "pending_registered"
    end

    test "shared Node status exposes the injected counterfactual capacity snapshot" do
      node = %Node{
        id: Ecto.UUID.generate(),
        state: :active,
        health: :healthy,
        last_heartbeat_at: DateTime.utc_now()
      }

      capacity = %CapacitySnapshot{
        counterfactual?: true,
        consumers_ready?: false,
        evaluation: capacity_result()
      }

      status =
        StatusBuilder.node_status_map(node,
          latest_decision: nil,
          dispatch_capacity_snapshot: capacity
        )

      assert status.dispatch_capacity.counterfactual
      assert status.dispatch_capacity.mode == "counterfactual"
      refute status.dispatch_capacity.consumers_ready
      assert status.dispatch_capacity.authority_phase == "pre_cutover"
      assert status.dispatch_capacity.controller_dispatch_ceiling == 2
      assert status.dispatch_capacity.effective_dispatch_limit == 0
      assert status.dispatch_capacity.dispatch_headroom == 0
      assert status.dispatch_capacity.temporary_legacy_available_slots == 3
    end

    test "node_status_maps threads batched admission decisions" do
      node = insert_node!(%{state: :registered, health: :healthy})

      assert {:ok, _rejected} =
               Nodes.reject_admission(node.id, %{reason: "needs review"})

      assert [status] = StatusBuilder.node_status_maps([node])
      assert status.admission.category == "rejected"
      assert status.admission.latest_decision == "rejected"
    end
  end

  describe "candidate status" do
    test "observed admission candidate is never schedulable" do
      candidate = insert_candidate!()

      status = StatusBuilder.candidate_status_map(candidate)

      assert status.resource.type == "admission_candidate"
      assert status.admission.category == "pending_observed"
      assert status.lifecycle.state == nil
      assert status.transport.status == "reachable"
      assert status.scheduling.eligible == false
      assert status.scheduling.reason_codes == ["node_not_registered", "trust_not_established"]
    end
  end

  defp insert_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      %{
        id: Ecto.UUID.generate(),
        hostname: "node-#{unique}.local",
        display_name: "node-#{unique}",
        advertise_addr: "10.30.#{rem(unique, 200)}.#{rem(unique, 250) + 1}",
        rpc_port: 50_071,
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{}
      }
      |> Map.merge(overrides)

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp capacity_result do
    %CapacityResult{
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
      temporary_legacy_available_slots: 3,
      legacy_pre_cutover_limit: 4,
      legacy_pre_cutover_reported_allocation: 1,
      legacy_pre_cutover_claim_count: 0,
      legacy_pre_cutover_available_slots: 3,
      eligible?: true,
      observation_time: DateTime.utc_now(),
      reason_codes: [
        :controller_dispatch_ceiling_not_yet_enforcing,
        :dispatch_capacity_pre_cutover_legacy
      ]
    }
  end

  defp insert_candidate! do
    unique = System.unique_integer([:positive])

    attrs = %{
      source: :runtime_endpoint_observation,
      admission_category: :pending_observed,
      observed_identity: %{
        "claimed_node_id" => Ecto.UUID.generate(),
        "display_name" => "candidate-#{unique}",
        "hostname" => "candidate-#{unique}.local"
      },
      target_ref: "10.0.0.#{rem(unique, 200) + 1}:50071",
      endpoint_transport: :grpc,
      endpoint_target: "10.0.0.#{rem(unique, 200) + 1}:50071",
      inventory: %{"capabilities" => %{}},
      compatibility_evidence: %{"metadata" => "partial"},
      last_observed_at: DateTime.utc_now()
    }

    %AdmissionCandidate{}
    |> AdmissionCandidate.changeset(attrs)
    |> Repo.insert!()
  end
end
