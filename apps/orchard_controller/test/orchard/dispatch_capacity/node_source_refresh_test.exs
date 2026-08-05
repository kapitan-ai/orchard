defmodule Orchard.DispatchCapacity.NodeSourceRefreshTest.QueueManager do
  @moduledoc false

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)
  def clear, do: :persistent_term.erase({__MODULE__, :test_pid})

  def refresh_node_capacity_sources(attrs) do
    send(:persistent_term.get({__MODULE__, :test_pid}), {:capacity_refreshed, attrs})
    :ok
  end

  def clear_capacity_sources(sources, opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), {:capacity_cleared, sources, opts})
    :ok
  end
end

defmodule Orchard.DispatchCapacity.NodeSourceRefreshTest do
  use Orchard.DataCase, async: false

  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionDecision, Node}

  @queue_manager Orchard.DispatchCapacity.NodeSourceRefreshTest.QueueManager

  setup do
    @queue_manager.configure(self())
    on_exit(&@queue_manager.clear/0)
    :ok
  end

  test "SPEC 4.6.2 Node refresh bounds eligible sources and clears ineligible sources" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = %{id: Ecto.UUID.generate()}

    refresh = %{
      clear_sources: [
        {:node, node.id},
        {:node, node.id, :placement},
        {:node, node.id, :cold}
      ],
      node_source: {:node, node.id},
      placement_source: {:node, node.id, :placement},
      cold_source: {:node, node.id, :cold},
      node_id: node.id,
      node_active: 0,
      node_max: 8,
      placements: [{"model-a", "v1", %{active: 0, max: 8}}],
      reserve_unassigned_node_grants?: true,
      reserve_unassigned_source_grants?: true
    }

    assert eligible =
             Nodes.refresh_dispatch_capacity_sources(node, enforcing_input(), refresh,
               authority: authority,
               queue_manager: @queue_manager
             )

    assert eligible.available_slots == 2

    assert_receive {:capacity_refreshed,
                    %{
                      node_active: 0,
                      node_max: 2,
                      dispatch_capacity_evaluation: ^eligible
                    }}

    ineligible_input = %{enforcing_input() | health: :unhealthy}

    assert ineligible =
             Nodes.refresh_dispatch_capacity_sources(node, ineligible_input, refresh,
               authority: authority,
               queue_manager: @queue_manager
             )

    refute ineligible.eligible?
    assert :node_health_unhealthy in ineligible.reason_codes
    clear_sources = refresh.clear_sources
    assert_receive {:capacity_cleared, ^clear_sources, [promote?: true]}
    refute_receive {:capacity_refreshed, _attrs}
  end

  test "SPEC 4.3 public Node observation refresh uses the shared bounded evaluation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    now = DateTime.utc_now()
    node = insert_node!(now)
    target = [host: node.advertise_addr, port: node.rpc_port]

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "test",
        listen_host: node.advertise_addr,
        listen_port: node.rpc_port,
        worker_backend: "mlx"
      },
      active_request_count: 0,
      max_concurrency: 8,
      runtime_model_placements: []
    }

    assert {:ok, _evidence} =
             Orchard.DispatchCapacity.record_capacity_evidence(node.id, %{
               active_request_count: 1,
               observed_at: now,
               runtime_concurrency_limit: 3,
               validity: :valid
             })

    assert {:ok, %Node{id: node_id}} =
             Nodes.observe_status(target, status, now,
               queue_manager: @queue_manager,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input: enforcing_input()
             )

    assert node_id == node.id

    assert_receive {:capacity_refreshed,
                    %{
                      node_id: ^node_id,
                      node_active: 0,
                      node_max: 2,
                      dispatch_capacity_evaluation: %{available_slots: 2, eligible?: true}
                    }}
  end

  test "SPEC 4.6.2 an unavailable authority clears Node queue sources instead of leaving them live" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    now = DateTime.utc_now()
    node = insert_node!(now)
    target = [host: node.advertise_addr, port: node.rpc_port]

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "test",
        listen_host: node.advertise_addr,
        listen_port: node.rpc_port,
        worker_backend: "mlx"
      },
      active_request_count: 0,
      max_concurrency: 8,
      runtime_model_placements: []
    }

    stop_supervised!(AllocationAuthority)

    assert {:ok, %Node{id: node_id}} =
             Nodes.observe_status(target, status, now,
               queue_manager: @queue_manager,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input: enforcing_input()
             )

    assert node_id == node.id

    expected_sources = [
      {:node, node.id},
      {:node, node.id, :placement},
      {:node, node.id, :cold}
    ]

    assert_receive {:capacity_cleared, cleared, [promote?: true]}
    assert Enum.sort(cleared) == Enum.sort(expected_sources)
    refute_receive {:capacity_refreshed, _attrs}
  end

  test "SPEC 4.3 default Node refresh evaluates the triggering observation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    now = DateTime.utc_now()
    node = insert_node!(now)
    approve_node!(node, now)
    target = [host: node.advertise_addr, port: node.rpc_port]

    assert {:ok, _evidence} =
             Orchard.DispatchCapacity.record_capacity_evidence(node.id, %{
               active_request_count: 1,
               observed_at: now,
               runtime_concurrency_limit: 3,
               validity: :valid
             })

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "test",
        listen_host: node.advertise_addr,
        listen_port: node.rpc_port,
        worker_backend: "mlx"
      },
      active_request_count: 1,
      max_concurrency: 3,
      runtime_model_placements: []
    }

    assert {:ok, %Node{id: node_id}} =
             Nodes.observe_status(target, status, now,
               queue_manager: @queue_manager,
               dispatch_capacity_authority: authority
             )

    assert_receive {:capacity_refreshed,
                    %{
                      node_id: ^node_id,
                      node_active: 0,
                      node_max: 2,
                      dispatch_capacity_evaluation: %{
                        available_slots: 2,
                        eligible?: true,
                        runtime_concurrency_enforcement_limit: 3,
                        legacy_pre_cutover_reported_allocation: 1
                      }
                    }}
  end

  defp insert_node!(now) do
    unique = System.unique_integer([:positive])

    %Node{}
    |> Node.changeset(%{
      id: Ecto.UUID.generate(),
      hostname: "refresh-#{unique}.local",
      display_name: "refresh-#{unique}",
      advertise_addr: "10.55.0.#{rem(unique, 200) + 1}",
      rpc_port: 50_071,
      connect_host: "10.55.0.#{rem(unique, 200) + 1}",
      connect_port: 50_071,
      state: :active,
      health: :healthy,
      capabilities: %{},
      last_heartbeat_at: DateTime.add(now, -1, :second)
    })
    |> Repo.insert!()
  end

  defp approve_node!(node, now) do
    {:ok, _result} =
      Repo.transaction(fn ->
        decision =
          %AdmissionDecision{}
          |> AdmissionDecision.changeset(%{
            node_id: node.id,
            decision: :admitted,
            actor_type: "system",
            actor_id: "node-refresh-test",
            observed_identity: %{},
            metadata: %{},
            decided_at: now
          })
          |> Repo.insert!()

        %Policy{}
        |> Policy.approved_explicit_changeset(%{
          node_id: node.id,
          admission_decision_id: decision.id,
          controller_dispatch_ceiling: 8,
          approved_by_actor_type: "system",
          approved_by_actor_id: "node-refresh-test",
          approved_at: now,
          approval_reason: "node refresh test fixture",
          version: 1
        })
        |> Repo.insert!()
      end)

    :ok
  end

  defp enforcing_input do
    %Input{
      authority_phase: :enforcing,
      policy_presence: :present,
      policy_state: :enforcing,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 8},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: {:valid, 2},
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end
end
