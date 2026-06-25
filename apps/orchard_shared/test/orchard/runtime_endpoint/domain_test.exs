defmodule Orchard.RuntimeEndpoint.DomainTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.{
    ModelRef,
    Observation,
    Operation,
    Placement,
    PlacementCapacity,
    Target
  }

  test "known placement capacity can prove spare capacity" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: 1,
        max_concurrency: 2,
        source: :compatibility_status
      })

    assert capacity.status == :known
    assert PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "placement capacity preserves explicit zero values" do
    capacity =
      PlacementCapacity.new(%{
        "active_request_count" => 1,
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: 0,
        max_concurrency: 2,
        source: :compatibility_status
      })

    assert capacity.status == :known
    assert capacity.active_request_count == 0
    assert PlacementCapacity.spare?(capacity)
  end

  test "known placement capacity can prove full capacity" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: 2,
        max_concurrency: 2,
        source: :compatibility_status
      })

    assert capacity.status == :known
    assert PlacementCapacity.full?(capacity)
    refute PlacementCapacity.spare?(capacity)
  end

  test "unknown placement capacity cannot prove eligibility" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        source: :missing_compatibility_status
      })

    assert capacity.status == :unknown
    refute PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "malformed placement capacity is invalid and cannot prove eligibility" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: "1",
        max_concurrency: 0,
        source: :malformed
      })

    assert capacity.status == :invalid
    refute PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "runtime endpoint observations expose loaded placement capacity" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    observation =
      Observation.new(%{
        target: Target.grpc_compat(host: "127.0.0.1", port: 50_061),
        placements: [
          %{
            model_ref: model_ref,
            state: :loaded,
            capacity: %{
              active_request_count: 1,
              max_concurrency: 2,
              source: :compatibility_status
            }
          }
        ]
      })

    assert %Placement{} = Observation.loaded_placement(observation, model_ref)

    assert PlacementCapacity.spare?(Observation.placement_capacity_for(observation, model_ref))
  end

  test "target normalization preserves default gRPC fallback and admits explicit BEAM targets" do
    grpc_target = Target.normalize(host: "127.0.0.1", port: 50_071)

    assert grpc_target.transport == :grpc_compat
    assert grpc_target.address == [host: "127.0.0.1", port: 50_071]

    beam_target =
      Target.normalize(%{
        transport: :beam,
        node_id: "node-1",
        address: :orchard_node_agent@localhost,
        metadata: %{role: :node_agent}
      })

    assert beam_target.transport == :beam
    assert beam_target.node_id == "node-1"
    assert beam_target.address == :orchard_node_agent@localhost
    assert beam_target.metadata == %{role: :node_agent}
  end

  test "BEAM target normalization keeps node_id nil unless explicitly configured" do
    target =
      Target.normalize(%{
        transport: :beam,
        id: "source-dev-node-agent",
        address: :orchard_node_agent@localhost
      })

    assert target.id == "source-dev-node-agent"
    assert target.transport == :beam
    assert target.node_id == nil
    assert target.address == :orchard_node_agent@localhost
  end

  test "runtime endpoint observations prefer metadata node identity without target node_id" do
    node_id = "550e8400-e29b-41d4-a716-446655440000"

    observation =
      Observation.new(%{
        target:
          Target.normalize(%{
            transport: :beam,
            id: "source-dev-node-agent",
            address: :orchard_node_agent@localhost
          }),
        metadata: %{node_id: node_id}
      })

    assert Observation.node_id(observation) == node_id
  end

  test "target normalization rejects malformed configured BEAM node names" do
    assert_raise ArgumentError, fn ->
      Target.normalize(transport: :beam, node_id: "node-1", address: "not a node")
    end
  end

  test "operation constructors validate scalar request shape without enforcing policy" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    request =
      Operation.ExecuteRequest.new!(%{
        request_id: "req_123",
        controller_session_id: "session_123",
        model_ref: model_ref,
        rendered_prompt_utf8: "hello",
        input_tokens: 1,
        params: %{max_output_tokens: 4},
        metadata_json: "{}",
        prompt_token_ids: [1, 2, 3],
        artifact_sha256: "sha256:abc",
        artifact_source_uri: "file:///models/phi-3",
        preload: true
      })

    assert request.model_ref == model_ref
    assert request.prompt_token_ids == [1, 2, 3]
    assert request.preload
  end

  test "operation constructors preserve explicit false and zero values" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    load_request =
      Operation.EnsureModelLoadedRequest.new!(%{
        "preload" => true,
        model_ref: model_ref,
        preload: false
      })

    execute_request =
      Operation.ExecuteRequest.new!(%{
        "input_tokens" => 4,
        request_id: "req_123",
        controller_session_id: "session_123",
        model_ref: model_ref,
        rendered_prompt_utf8: "",
        input_tokens: 0
      })

    refute load_request.preload
    assert execute_request.input_tokens == 0
  end
end
