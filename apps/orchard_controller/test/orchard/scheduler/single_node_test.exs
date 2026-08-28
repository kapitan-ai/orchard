defmodule Orchard.Scheduler.SingleNodeTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.CircuitBreakers
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.RuntimeEndpoint.Target
  alias Orchard.Scheduler.SingleNode

  defmodule RuntimeEndpointStubClient do
    @moduledoc false

    def connect(target) do
      send(self(), {:runtime_endpoint_connect, target})
      {:error, :unavailable}
    end

    def status(_channel, _opts), do: {:error, :unavailable}
    def disconnect(_channel), do: :ok
  end

  defmodule StubClient do
    @moduledoc false

    def connect(target), do: {:ok, target}

    def status(_target, _opts) do
      case Process.get(:single_node_status) do
        nil -> {:error, :unavailable}
        response -> {:ok, response}
      end
    end

    def disconnect(_channel), do: :ok
  end

  defmodule CountingClient do
    @moduledoc false

    def connect(target) do
      send(Process.get({__MODULE__, :owner}), {:single_node_connect, target})
      {:ok, target}
    end

    def status(channel, _opts) do
      send(Process.get({__MODULE__, :owner}), {:single_node_status, channel})
      {:ok, %{active_request_count: 0, max_concurrency: 1}}
    end

    def disconnect(_channel), do: :ok
  end

  defmodule UnavailableBreakerEvaluator do
    @moduledoc false

    def evaluate(_target), do: {:error, :breaker_state_invalid}
  end

  setup do
    Process.delete(:single_node_status)
    Process.put({CountingClient, :owner}, self())
    :ok
  end

  test "SPEC.md §5.5 and ADR 0019 exclude the prior Node before probing" do
    node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "10.0.0.8", port: 50_061, node_id: node_id)

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-prior-node-exclusion"),
               target,
               status_client: RuntimeEndpointStubClient,
               exclude_node_ids: [node_id],
               node_resolver: fn _target ->
                 {:ok, %Orchard.Nodes.Node{id: node_id, health: :healthy, state: :active}}
               end
             )

    assert [rejected] = decision.rejected_candidates
    assert rejected.node_id == node_id
    assert rejected.reason_codes == ["previous_attempt_node_excluded"]
    refute_received {:runtime_endpoint_connect, _target}
  end

  test "SPEC.md §5.5 fails closed when exclusions are present and durable identity is missing" do
    target = Target.grpc_compat(host: "10.0.0.9", port: 50_061)

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-missing-durable-identity"),
               target,
               status_client: RuntimeEndpointStubClient,
               exclude_node_ids: [Ecto.UUID.generate()],
               node_resolver: fn _target -> {:ok, nil} end
             )

    assert [rejected] = decision.rejected_candidates
    assert rejected.node_id == nil
    assert rejected.reason_codes == ["runtime_identity_mismatch"]
    refute_received {:runtime_endpoint_connect, _target}
  end

  test "SPEC.md §5.5 fails closed on conflicting durable identity before exclusion comparison" do
    resolved_node_id = Ecto.UUID.generate()
    target_node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "10.0.0.10", port: 50_061, node_id: target_node_id)

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-conflicting-durable-identity"),
               target,
               status_client: RuntimeEndpointStubClient,
               exclude_node_ids: [Ecto.UUID.generate()],
               node_resolver: fn _target ->
                 {:ok,
                  %Orchard.Nodes.Node{id: resolved_node_id, health: :healthy, state: :active}}
               end
             )

    assert [rejected] = decision.rejected_candidates
    assert rejected.node_id == resolved_node_id
    assert rejected.reason_codes == ["runtime_identity_mismatch"]
    refute_received {:runtime_endpoint_connect, _target}
  end

  test "ADR 0019 compares SingleNode exclusions as canonical UUIDs" do
    node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "10.0.0.11", port: 50_061)

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-canonical-exclusion"),
               target,
               status_client: RuntimeEndpointStubClient,
               exclude_node_ids: [String.upcase(node_id)],
               node_resolver: fn _target ->
                 {:ok, %Orchard.Nodes.Node{id: node_id, health: :healthy, state: :active}}
               end
             )

    assert [rejected] = decision.rejected_candidates
    assert rejected.reason_codes == ["previous_attempt_node_excluded"]
    refute_received {:runtime_endpoint_connect, _target}
  end

  test "SPEC.md §5.10 rejects an open canonical Node before status probing" do
    node = insert_breaker_node!()
    open_node_breaker!(node.id)

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-node-open-breaker"),
               SingleNode.target(),
               status_client: CountingClient,
               node_resolver: fn _target -> {:ok, node} end
             )

    assert hd(hd(decision.rejected_candidates).reason_codes) == "node_circuit_breaker_open"
    refute_received {:single_node_connect, _target}
    refute_received {:single_node_status, _channel}
  end

  test "SPEC.md §5.10 fails closed distinctly when durable breaker state is unavailable" do
    node = insert_breaker_node!()

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-node-breaker-read-failure"),
               SingleNode.target(),
               status_client: CountingClient,
               node_resolver: fn _target -> {:ok, node} end,
               circuit_breaker_evaluator: UnavailableBreakerEvaluator
             )

    assert hd(hd(decision.rejected_candidates).reason_codes) ==
             "dispatch_capacity_facts_unavailable"

    refute_received {:single_node_connect, _target}
  end

  test "SPEC.md §5.5 bounds loaded placement capacity by unmanaged aggregate fallback" do
    Process.put(:single_node_status, %{
      runtime_model_placements: [
        placement("single-capacity-model", "v1", active_request_count: 1, max_concurrency: 2)
      ]
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-capacity-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    assert schedule.queue_lane_capacity == 1
  end

  test "SPEC.md §5.5 constrains single-node queue capacity by node max concurrency" do
    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: [
        placement("single-node-capacity-model", "v1",
          active_request_count: 0,
          max_concurrency: 4
        )
      ]
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-node-capacity-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    assert schedule.queue_lane_capacity == 2
  end

  test "SPEC.md §5.5 accounts for unrelated single-node load in queue capacity" do
    Process.put(:single_node_status, %{
      active_request_count: 2,
      max_concurrency: 4,
      runtime_model_placements: [
        placement("single-unrelated-load-model", "v1",
          active_request_count: 1,
          max_concurrency: 4
        )
      ]
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-unrelated-load-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    assert schedule.queue_lane_capacity == 2
  end

  test "SPEC.md §5.5 returns model_busy when multi-slot single-node capacity is exhausted" do
    Process.put(:single_node_status, %{
      active_request_count: 2,
      max_concurrency: 2,
      runtime_model_placements: [
        placement("single-node-busy-model", "v1", active_request_count: 1, max_concurrency: 4)
      ]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-node-busy-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 returns model_busy when unrelated load exhausts single-node capacity" do
    Process.put(:single_node_status, %{
      active_request_count: 1,
      max_concurrency: 1,
      runtime_model_placements: [
        placement("single-node-unrelated-busy-model", "v1",
          active_request_count: 0,
          max_concurrency: 1
        )
      ]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-node-unrelated-busy-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 returns model_busy for cold request when single-node capacity is exhausted" do
    Process.put(:single_node_status, %{
      active_request_count: 1,
      max_concurrency: 1,
      runtime_model_placements: []
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-node-cold-busy-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 returns model_busy when single-slot single-node placement is exhausted" do
    Process.put(:single_node_status, %{
      active_request_count: 1,
      max_concurrency: 1,
      runtime_model_placements: [
        placement("single-node-same-model-busy-model", "v1",
          active_request_count: 1,
          max_concurrency: 1
        )
      ]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-node-same-model-busy-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 returns model_busy when the single-node placement is exhausted" do
    Process.put(:single_node_status, %{
      runtime_model_placements: [
        placement("single-busy-model", "v1", active_request_count: 2, max_concurrency: 2)
      ]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-busy-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 rejects invalid single-node placement capacity" do
    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 4,
      runtime_model_placements: [
        placement("single-invalid-capacity-model", "v1",
          active_request_count: 0,
          max_concurrency: 0
        )
      ]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-invalid-capacity-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 rejects duplicate single-node placement capacity" do
    duplicate =
      placement("single-duplicate-capacity-model", "v1",
        active_request_count: 0,
        max_concurrency: 4
      )

    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 4,
      runtime_model_placements: [duplicate, duplicate]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-duplicate-capacity-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 rejects malformed matching single-node placement capacity" do
    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 4,
      runtime_model_placements: [
        %{model_ref: %{model_id: "single-malformed-capacity-model", version: "v1"}}
      ]
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-malformed-capacity-model"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 rejects a loaded model with missing Placement Capacity" do
    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 4,
      loaded_models: [%{model_id: "single-loaded-missing-capacity", version: "v1"}],
      runtime_model_placements: []
    })

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-loaded-missing-capacity"),
               SingleNode.target(),
               status_client: StubClient
             )
  end

  test "SPEC.md §9.1 selected tier follows authoritative loaded state, not placement capacity" do
    unloaded_status = %{
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: [
        placement("single-tier-model", "v1", active_request_count: 0, max_concurrency: 2)
      ]
    }

    Process.put(:single_node_status, unloaded_status)

    assert {:ok, unloaded_schedule} =
             SingleNode.default_schedule(
               canonical_request("single-tier-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert unloaded_schedule.selected_tier == "cold"

    Process.put(
      :single_node_status,
      Map.put(unloaded_status, :loaded_models, [
        %{model_id: "single-tier-model", version: "v1"}
      ])
    )

    assert {:ok, loaded_schedule} =
             SingleNode.default_schedule(
               canonical_request("single-tier-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert loaded_schedule.selected_tier == "loaded"
  end

  test "SPEC.md §9.1 an unreachable single-node probe reports the cold tier" do
    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-unreachable-tier-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert schedule.selected_tier == "cold"
  end

  test "uses one conservative unmanaged slot when aggregate capacity is missing" do
    Process.put(:single_node_status, %{runtime_model_placements: []})

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-legacy-model"),
               SingleNode.target(),
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    assert schedule.queue_lane_capacity == 1
  end

  test "SPEC.md §4.6.2 fails closed when authority is down after a successful unmanaged probe" do
    Process.put(:single_node_status, %{runtime_model_placements: []})

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-authority-down-after-probe"),
               SingleNode.target(),
               status_client: StubClient,
               dispatch_capacity_authority: stopped_authority()
             )
  end

  test "SPEC.md §4.6.2 fails closed when authority is down after a failed unmanaged probe" do
    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-authority-down-after-probe-failure"),
               SingleNode.target(),
               status_client: StubClient,
               dispatch_capacity_authority: stopped_authority()
             )
  end

  test "SPEC.md §4.6.2 inventory failure cannot downgrade a target to unmanaged" do
    Process.put(:single_node_status, %{active_request_count: 0, max_concurrency: 2})

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(
               canonical_request("single-inventory-failure-model"),
               SingleNode.target(),
               status_client: StubClient,
               node_resolver: fn _target -> {:error, :node_inventory_unavailable} end
             )
  end

  test "SPEC.md §5.9 post-load provider probes fresh placement capacity" do
    model_id = "single-post-load-capacity-model"

    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(model_id),
               SingleNode.target(),
               status_client: StubClient
             )

    Process.put(:single_node_status, %{
      active_request_count: 1,
      max_concurrency: 2,
      runtime_model_placements: [
        placement(model_id, "v1", active_request_count: 1, max_concurrency: 1)
      ]
    })

    refreshed = schedule.dispatch_capacity_input_provider.()
    result = Evaluator.evaluate(refreshed)

    assert result.placement_capacity == {:valid, 1, 1}
    assert result.eligible? == false
    assert :placement_capacity_exhausted in result.reason_codes
  end

  test "SPEC.md §5.9 acquisition provider probes fresh aggregate capacity before loading" do
    model_id = "single-acquisition-capacity-model"

    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(model_id),
               SingleNode.target(),
               status_client: StubClient
             )

    Process.put(:single_node_status, %{
      active_request_count: 2,
      max_concurrency: 2,
      runtime_model_placements: []
    })

    refreshed = schedule.dispatch_capacity_acquisition_input_provider.()
    result = Evaluator.evaluate(refreshed)

    assert result.placement_capacity == :not_applicable
    refute result.eligible?
    assert :runtime_concurrency_limit_exhausted in result.reason_codes
  end

  test "SPEC.md §5.9 post-load provider rejects missing matching Placement Capacity" do
    model_id = "single-post-load-missing-placement-model"

    Process.put(:single_node_status, %{
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(model_id),
               SingleNode.target(),
               status_client: StubClient
             )

    refreshed = schedule.dispatch_capacity_input_provider.()
    result = Evaluator.evaluate(refreshed)

    assert result.placement_capacity == :unknown
    assert result.eligible? == false
    assert :placement_capacity_unknown in result.reason_codes
  end

  test "SPEC.md §5.5 probes a Runtime Endpoint target with the Runtime Endpoint client" do
    previous = Application.get_env(:orchard_controller, :inference, [])

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(previous, :runtime_endpoint_client_impl, RuntimeEndpointStubClient)
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :inference, previous) end)

    target = %Target{
      id: Ecto.UUID.generate(),
      transport: :beam,
      address: :"orchard_node_agent@127.0.0.1"
    }

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(canonical_request("beam-fallback-model"), target)

    assert_received {:runtime_endpoint_connect, ^target}
  end

  test "issue #128 probe failure returns model_busy with stable explanation" do
    node = insert_breaker_node!()

    assert {:error, :model_busy, decision} =
             SingleNode.default_schedule(
               canonical_request("single-explained-probe-failure"),
               SingleNode.target(),
               status_client: StubClient,
               node_resolver: fn _target -> {:ok, node} end
             )

    assert decision.strategy == :single_node
    assert length(decision.rejected_candidates) == 1

    codes = hd(decision.rejected_candidates).reason_codes
    assert "transport_unreachable" in codes
    assert hd(decision.rejected_candidates).node_id == node.id
  end

  defp canonical_request(model_id) do
    CanonicalRequest.new(%{
      internal_id: "int_#{System.unique_integer([:positive])}",
      public_id: "pub_#{System.unique_integer([:positive])}",
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %ModelRef{model_id: model_id, version: "v1"},
      rendered_prompt: "hello"
    })
  end

  defp placement(model_id, version, attrs) do
    %{
      model_ref: %{model_id: model_id, version: version},
      active_request_count: Keyword.fetch!(attrs, :active_request_count),
      max_concurrency: Keyword.fetch!(attrs, :max_concurrency)
    }
  end

  defp stopped_authority do
    {pid, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    pid
  end

  defp insert_breaker_node! do
    unique = System.unique_integer([:positive])

    %Orchard.Nodes.Node{}
    |> Orchard.Nodes.Node.changeset(%{
      id: Ecto.UUID.generate(),
      hostname: "single-breaker-node-#{unique}.local",
      display_name: "single-breaker-node-#{unique}",
      advertise_addr: "10.253.0.#{rem(unique, 254) + 1}",
      rpc_port: 9444,
      state: :active,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp open_node_breaker!(node_id) do
    now = DateTime.utc_now()

    for offset <- [2, 1, 0] do
      assert {:ok, _decision} =
               CircuitBreakers.record_failure(
                 %{
                   failure_id: Ecto.UUID.generate(),
                   node_id: node_id,
                   failure_class: "worker_or_node_loss",
                   occurred_at: DateTime.add(now, -offset, :second)
                 },
                 now: now
               )
    end
  end
end
