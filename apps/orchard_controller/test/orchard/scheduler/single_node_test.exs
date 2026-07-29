defmodule Orchard.Scheduler.SingleNodeTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
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

  setup do
    Process.delete(:single_node_status)
    :ok
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
             SingleNode.default_schedule(
               canonical_request("single-loaded-missing-capacity"),
               SingleNode.target(),
               status_client: StubClient
             )
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

    assert {:error, :model_busy} =
             SingleNode.default_schedule(
               canonical_request("single-authority-down-after-probe"),
               SingleNode.target(),
               status_client: StubClient,
               dispatch_capacity_authority: stopped_authority()
             )
  end

  test "SPEC.md §4.6.2 fails closed when authority is down after a failed unmanaged probe" do
    assert {:error, :model_busy} =
             SingleNode.default_schedule(
               canonical_request("single-authority-down-after-probe-failure"),
               SingleNode.target(),
               status_client: StubClient,
               dispatch_capacity_authority: stopped_authority()
             )
  end

  test "SPEC.md §4.6.2 inventory failure cannot downgrade a target to unmanaged" do
    Process.put(:single_node_status, %{active_request_count: 0, max_concurrency: 2})

    assert {:error, :model_busy} =
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

    assert {:error, :model_busy} =
             SingleNode.default_schedule(canonical_request("beam-fallback-model"), target)

    assert_received {:runtime_endpoint_connect, ^target}
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
end
