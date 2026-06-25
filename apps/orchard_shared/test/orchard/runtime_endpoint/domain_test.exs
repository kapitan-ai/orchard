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
end
