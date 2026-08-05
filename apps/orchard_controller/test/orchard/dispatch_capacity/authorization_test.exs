defmodule Orchard.DispatchCapacity.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Orchard.DispatchCapacity.{Authority, Authorization, CapacityEvidence, Policy}
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.Nodes.Node
  alias Orchard.RuntimeEndpoint.{Observation, Target}

  @now ~U[2026-07-20 09:00:00.000000Z]

  test "SPEC 4.6.2 assembles production authorization only from Controller-owned facts" do
    node = active_node()

    assert {:ok, input} =
             Authorization.input(node,
               authority: %Authority{enforcement_phase: :enforcing},
               policy: %Policy{policy_state: :enforcing, controller_dispatch_ceiling: 2},
               evidence: evidence(node.id),
               placement_capacity: {:valid, 0, 2},
               now: @now
             )

    result = Evaluator.evaluate(input)

    assert result.authority_decision == :f11_enforcing
    assert result.available_slots == 2
    assert result.eligible?
  end

  test "SPEC 4.6.2 missing production policy remains a fail-closed evaluation" do
    node = active_node()

    assert {:ok, input} =
             Authorization.input(node,
               authority: %Authority{enforcement_phase: :enforcing},
               policy: nil,
               evidence: evidence(node.id),
               now: @now
             )

    result = Evaluator.evaluate(input)

    refute result.eligible?
    assert result.authority_decision == :fail_closed
    assert :controller_dispatch_ceiling_missing in result.reason_codes
  end

  test "SPEC 4.6.1 accepts only an explicitly classified unmanaged source-development target" do
    target =
      Target.normalize(
        transport: :beam,
        address: "orchard_node_agent@127.0.0.1",
        metadata: %{source_dev: true}
      )

    assert {:ok, input} =
             Authorization.unmanaged_input(target, %{
               active_request_count: 0,
               max_concurrency: 1
             })

    result = Evaluator.evaluate(input)

    assert result.authority_decision == :unmanaged_source_development
    assert result.available_slots == 1
    assert result.eligible?

    unclassified = Target.grpc_compat(host: "127.0.0.1", port: 50_071)

    assert {:error, :dispatch_capacity_management_class_missing} =
             Authorization.unmanaged_input(unclassified, %{
               active_request_count: 0,
               max_concurrency: 1
             })
  end

  test "SPEC 4.6.1 fails an unmanaged target closed when its live observation is stale" do
    target =
      Target.normalize(
        transport: :beam,
        address: "orchard_node_agent@127.0.0.1",
        metadata: %{source_dev: true}
      )

    observation =
      Observation.new(%{
        target: target,
        observed_at: DateTime.add(@now, -600, :second),
        availability: :available,
        aggregate_active_request_count: 0,
        aggregate_max_concurrency: 1
      })

    assert {:ok, input} =
             Authorization.unmanaged_input(target, observation,
               now: @now,
               freshness_threshold_ms: 30_000
             )

    refute input.capacity_observation_fresh?

    result = Evaluator.evaluate(input)

    refute result.eligible?
    assert :runtime_capacity_observation_stale in result.reason_codes
  end

  test "SPEC 4.6.2 rejects live production evidence for a different Node identity" do
    node = active_node()
    other_node_id = Ecto.UUID.generate()

    observation =
      Observation.new(%{
        target: Target.beam(other_node_id, address: "orchard_node_agent@127.0.0.1"),
        observed_at: @now,
        availability: :available,
        aggregate_active_request_count: 0,
        aggregate_max_concurrency: 2
      })

    assert {:error, :dispatch_capacity_facts_unavailable} =
             Authorization.input_for_node_observation(node.id, observation,
               node_fetcher: fn _node_id -> {:ok, node} end,
               authority: %Authority{enforcement_phase: :enforcing},
               policy: %Policy{policy_state: :enforcing, controller_dispatch_ceiling: 2},
               now: @now
             )
  end

  test "SPEC 4.6.2 rejects identity-matching observations without current authenticated evidence" do
    node = active_node()

    observation =
      Observation.new(%{
        target: Target.beam(node.id, address: "orchard_node_agent@127.0.0.1"),
        observed_at: @now,
        availability: :available,
        aggregate_active_request_count: 0,
        aggregate_max_concurrency: 2
      })

    assert {:error, :dispatch_capacity_facts_unavailable} =
             Authorization.input_for_node_observation(node.id, observation,
               node_fetcher: fn _node_id -> {:ok, node} end,
               authority: %Authority{enforcement_phase: :enforcing},
               policy: %Policy{policy_state: :enforcing, controller_dispatch_ceiling: 2},
               evidence: nil,
               minimum_evidence_observed_at: @now,
               now: @now
             )
  end

  test "ADR 0013 live availability cannot improve Controller-owned degraded health" do
    node = %{active_node() | health: :degraded}

    observation =
      Observation.new(%{
        target: Target.beam(node.id, address: "orchard_node_agent@127.0.0.1"),
        observed_at: @now,
        availability: :available,
        aggregate_active_request_count: 0,
        aggregate_max_concurrency: 2
      })

    assert {:ok, input} =
             Authorization.input_for_observation(node, observation,
               authority: %Authority{enforcement_phase: :enforcing},
               policy: %Policy{policy_state: :enforcing, controller_dispatch_ceiling: 2},
               evidence: evidence(node.id),
               now: @now
             )

    assert input.health == :degraded
    result = Evaluator.evaluate(input)
    refute result.eligible?
    assert :node_health_degraded in result.reason_codes
  end

  test "SPEC 4.6.2 current authenticated evidence authorizes newer live capacity operands" do
    node = active_node()
    observed_at = DateTime.add(@now, 1, :second)

    observation =
      Observation.new(%{
        target: Target.beam(node.id, address: "orchard_node_agent@127.0.0.1"),
        observed_at: observed_at,
        availability: :available,
        aggregate_active_request_count: 1,
        aggregate_max_concurrency: 4
      })

    assert {:ok, input} =
             Authorization.input_for_node_observation(node.id, observation,
               node_fetcher: fn _node_id -> {:ok, node} end,
               authority: %Authority{enforcement_phase: :enforcing},
               policy: %Policy{policy_state: :enforcing, controller_dispatch_ceiling: 3},
               evidence: evidence(node.id),
               now: observed_at
             )

    assert input.runtime_concurrency_limit == {:valid, 4}
    assert input.aggregate_active_count == {:valid, 1}
    assert input.observation_time == observed_at
    assert input.capacity_observation_fresh?

    result = Evaluator.evaluate(input)
    assert result.available_slots == 3
    assert result.eligible?
  end

  defp active_node do
    %Node{
      id: Ecto.UUID.generate(),
      state: :active,
      health: :healthy,
      last_heartbeat_at: @now
    }
  end

  defp evidence(node_id) do
    %CapacityEvidence{
      node_id: node_id,
      validity: :valid,
      runtime_concurrency_limit: 2,
      active_request_count: 0,
      observed_at: @now
    }
  end
end
