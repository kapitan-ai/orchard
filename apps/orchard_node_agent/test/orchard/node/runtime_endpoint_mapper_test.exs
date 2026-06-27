defmodule Orchard.Node.RuntimeEndpointMapperTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{
    RuntimeHealth,
    RuntimeModelPlacement,
    RuntimeNodeMetadata,
    ScorePrefixCacheResponse,
    StatusResponse
  }

  alias Orchard.Cluster.V1.ModelRef, as: RPCModelRef
  alias Orchard.Node.RuntimeEndpointMapper
  alias Orchard.RuntimeEndpoint.{ModelRef, Observation, Operation, PlacementCapacity, Target}

  test "maps node-agent status to Runtime Endpoint observation with placement capacity" do
    target = Target.beam("550e8400-e29b-41d4-a716-446655440000", address: :node_one@localhost)
    model_ref = %RPCModelRef{model_id: "mlx-community/phi-3", version: "main"}

    response = %StatusResponse{
      worker_state: :WORKER_STATE_IDLE,
      loaded_models: [model_ref],
      active_request_count: 1,
      max_concurrency: 2,
      node_metadata: %RuntimeNodeMetadata{node_id: "node-1", hostname: "worker.local"},
      runtime_health: %RuntimeHealth{ready: true, health_code: "ok"},
      runtime_model_placements: [
        %RuntimeModelPlacement{model_ref: model_ref, active_request_count: 1, max_concurrency: 2}
      ],
      supports_prompt_token_ids: true
    }

    observation = RuntimeEndpointMapper.observation_from_status(target, response)
    runtime_model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    capacity = Observation.placement_capacity_for(observation, runtime_model_ref)

    assert observation.target == target
    assert observation.availability == :available
    assert observation.worker_state == :idle
    assert observation.aggregate_active_request_count == 1
    assert observation.aggregate_max_concurrency == 2
    assert observation.metadata.node_id == "node-1"
    assert observation.supports_prompt_token_ids

    assert %PlacementCapacity{status: :known, active_request_count: 1, max_concurrency: 2} =
             capacity
  end

  test "maps source-dev BEAM target address shape into observation identity" do
    target =
      Target.beam("550e8400-e29b-41d4-a716-446655440000",
        address: :"orchard_node_agent@127.0.0.1",
        metadata: %{source_dev: true}
      )

    response = %StatusResponse{
      node_metadata: %RuntimeNodeMetadata{
        node_id: "node-source-dev",
        hostname: "127.0.0.1",
        listen_host: "127.0.0.1"
      },
      runtime_health: %RuntimeHealth{ready: true, health_code: "ok"}
    }

    observation = RuntimeEndpointMapper.observation_from_status(target, response)

    assert observation.endpoint_id == target.id
    assert observation.target == target
    assert observation.target.address == :"orchard_node_agent@127.0.0.1"
    assert observation.target.metadata.source_dev
    assert observation.metadata.node_id == "node-source-dev"
    assert observation.metadata.hostname == "127.0.0.1"
    assert observation.metadata.listen_host == "127.0.0.1"
    assert observation.availability == :available
  end

  test "maps prefix-cache score responses to Runtime Endpoint operation results" do
    response = %ScorePrefixCacheResponse{
      status_code: "ok",
      status_message: "resident",
      resident_fingerprint_match: true,
      score_tier: "resident",
      session_started_unix_ms: 123
    }

    assert %Operation.PrefixCacheScoreResult{
             status_code: "ok",
             status_message: "resident",
             resident_fingerprint_match: true,
             score_tier: "resident",
             session_started_unix_ms: 123
           } = RuntimeEndpointMapper.prefix_cache_score_result_from_response(response)
  end
end
