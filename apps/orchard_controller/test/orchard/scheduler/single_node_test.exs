defmodule Orchard.Scheduler.SingleNodeTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Scheduler.SingleNode

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

  test "SPEC.md §5.5 reports loaded placement max concurrency for single-node queue admission" do
    Process.put(:single_node_status, %{
      runtime_model_placements: [
        placement("single-capacity-model", "v1", active_request_count: 1, max_concurrency: 2)
      ]
    })

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-capacity-model"),
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    assert schedule.queue_lane_capacity == 2
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
               [host: "127.0.0.1", port: 50_071],
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
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    assert schedule.queue_lane_capacity == 3
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
               [host: "127.0.0.1", port: 50_071],
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
               [host: "127.0.0.1", port: 50_071],
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
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )
  end

  test "keeps legacy single-slot same-model queue scheduling under active placement load" do
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

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-node-same-model-busy-model"),
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    refute Map.has_key?(schedule, :queue_lane_capacity)
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
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )
  end

  test "SPEC.md §5.5 returns model_busy when single-node placement capacity is invalid" do
    Process.put(:single_node_status, %{
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
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )
  end

  test "keeps conservative queue capacity when single-node status lacks placement capacity" do
    Process.put(:single_node_status, %{runtime_model_placements: []})

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request("single-legacy-model"),
               [host: "127.0.0.1", port: 50_071],
               status_client: StubClient
             )

    assert schedule.strategy == :single_node
    refute Map.has_key?(schedule, :queue_lane_capacity)
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
      placement_state: :PLACEMENT_STATE_LOADED,
      active_request_count: Keyword.fetch!(attrs, :active_request_count),
      max_concurrency: Keyword.fetch!(attrs, :max_concurrency)
    }
  end
end
