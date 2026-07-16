defmodule Orchard.RuntimeEndpoint.GrpcCompatibilityMapperTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{
    Ack,
    EnsureModelLoadedResponse,
    GenerationParams,
    RuntimeHealth,
    RuntimeModelPlacement,
    RuntimeNodeMetadata,
    ScorePrefixCacheResponse,
    StatusResponse
  }

  alias Orchard.Cluster.V1.ModelRef, as: RPCModelRef

  alias Orchard.RuntimeEndpoint.{
    GrpcCompatibilityMapper,
    GrpcMapping,
    Observation,
    Operation,
    PlacementCapacity,
    Target
  }

  @model_id "mlx-community/phi-3"
  @version "main"

  test "maps status response placements to runtime endpoint observations" do
    node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "127.0.0.1", port: 50_071)

    response =
      status_response(
        node_id: node_id,
        worker_state: :WORKER_STATE_BUSY,
        active_request_count: 3,
        loaded_models: [rpc_model_ref()],
        runtime_health: %RuntimeHealth{ready: true, health_code: "ok"},
        runtime_model_placements: [
          %RuntimeModelPlacement{
            model_ref: rpc_model_ref(),
            active_request_count: 1,
            max_concurrency: 2
          }
        ],
        supports_prompt_token_ids: true
      )

    observation = GrpcCompatibilityMapper.observation_from_status(target, response)

    assert observation.endpoint_id == "grpc_compat:127.0.0.1:50071"
    assert observation.target == target
    assert observation.availability == :available
    assert observation.worker_state == :busy
    assert observation.aggregate_active_request_count == 3
    assert observation.metadata.node_id == node_id
    assert observation.health.ready == true
    assert observation.supports_prompt_token_ids == true

    assert [placement] = observation.placements
    assert placement.model_ref == domain_model_ref()
    assert placement.state == :loaded

    assert %PlacementCapacity{
             status: :known,
             active_request_count: 1,
             max_concurrency: 2,
             source: :grpc_compatibility_status
           } = placement.capacity

    assert PlacementCapacity.spare?(placement.capacity)
  end

  test "maps loaded placement without placement capacity as unknown" do
    observation =
      GrpcCompatibilityMapper.observation_from_status(
        [host: "127.0.0.1", port: 50_071],
        status_response(loaded_models: [rpc_model_ref()])
      )

    capacity = Observation.placement_capacity_for(observation, domain_model_ref())

    assert capacity.status == :unknown
    refute PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "SPEC.md §4.6.2 preserves malformed aggregate evidence before scheduler fallback" do
    observation =
      GrpcCompatibilityMapper.observation_from_status(
        [host: "127.0.0.1", port: 50_071],
        %{active_request_count: -1, max_concurrency: 4}
      )

    assert observation.aggregate_active_request_count == 0
    assert observation.aggregate_max_concurrency == 4

    assert observation.aggregate_capacity_evidence == %{
             active_request_count: nil,
             runtime_concurrency_limit: 4,
             validity: :invalid
           }
  end

  test "SPEC.md §12.4 legacy zero max_concurrency is unknown rather than malformed" do
    observation =
      GrpcCompatibilityMapper.observation_from_status(
        [host: "127.0.0.1", port: 50_071],
        %{active_request_count: 3, max_concurrency: 0}
      )

    assert observation.aggregate_max_concurrency == nil

    assert observation.aggregate_capacity_evidence == %{
             active_request_count: 3,
             runtime_concurrency_limit: nil,
             validity: :missing
           }
  end

  test "duplicate, malformed, and nonmatching placement capacity cannot prove spare capacity" do
    cases = [
      {
        [
          %RuntimeModelPlacement{
            model_ref: rpc_model_ref(),
            active_request_count: 0,
            max_concurrency: 2
          },
          %RuntimeModelPlacement{
            model_ref: rpc_model_ref(),
            active_request_count: 1,
            max_concurrency: 2
          }
        ],
        :invalid
      },
      {
        [
          %{
            model_ref: %{model_id: @model_id, version: @version},
            active_request_count: "1",
            max_concurrency: 2
          }
        ],
        :invalid
      },
      {
        [
          %RuntimeModelPlacement{
            model_ref: %RPCModelRef{model_id: "other-model", version: @version},
            active_request_count: 0,
            max_concurrency: 2
          }
        ],
        :unknown
      }
    ]

    for {placements, expected_status} <- cases do
      observation =
        GrpcCompatibilityMapper.observation_from_status(
          [host: "127.0.0.1", port: 50_071],
          status_response(
            loaded_models: [rpc_model_ref()],
            runtime_model_placements: placements
          )
        )

      capacity = Observation.placement_capacity_for(observation, domain_model_ref())

      assert capacity.status == expected_status
      refute PlacementCapacity.spare?(capacity)
    end
  end

  test "maps ensure model loaded requests and responses" do
    request =
      Operation.EnsureModelLoadedRequest.new!(
        model_ref: %{model_id: @model_id, version: @version},
        node_id: "node-1",
        artifact_sha256: "sha",
        preload: true,
        deadline_unix_ms: 123,
        artifact_source_uri: "file:///models/phi"
      )

    proto = GrpcMapping.ensure_model_loaded_request_to_proto(request)

    assert proto.node_id == "node-1"
    assert proto.model_id == @model_id
    assert proto.version == @version
    assert proto.artifact_sha256 == "sha"
    assert proto.preload == true
    assert proto.deadline_unix_ms == 123
    assert proto.artifact_source_uri == "file:///models/phi"

    loaded =
      GrpcMapping.ensure_model_loaded_result_from_response(%EnsureModelLoadedResponse{
        already_loaded: true,
        placement_state: :PLACEMENT_STATE_LOADED,
        worker_supports_prompt_token_ids: true
      })

    assert loaded.already_loaded == true
    assert loaded.placement_state == :loaded
    assert loaded.worker_supports_prompt_token_ids == true

    failed =
      GrpcMapping.ensure_model_loaded_result_from_response(%EnsureModelLoadedResponse{
        placement_state: :PLACEMENT_STATE_FAILED,
        failure_category: :MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED,
        failure_code: "oom",
        failure_message: "not enough memory"
      })

    assert failed.placement_state == :failed
    assert failed.failure_category == :resource_exhausted
    assert failed.failure_code == "oom"
    assert failed.failure_message == "not enough memory"
  end

  test "maps execute inference requests" do
    request =
      Operation.ExecuteRequest.new!(
        request_id: "req-1",
        controller_session_id: "session-1",
        model_ref: %{model_id: @model_id, version: @version},
        rendered_prompt_utf8: "hello",
        input_tokens: 2,
        params: %{
          max_output_tokens: 16,
          temperature: 0.2,
          top_p: 0.9,
          stop_sequences: ["stop"],
          tools_json: "{}",
          tool_choice_json: "{\"type\":\"auto\"}"
        },
        deadline_unix_ms: 456,
        metadata_json: "{\"tenant\":\"default\"}",
        cache_affinity_fingerprint: "fp",
        prompt_token_ids: [1, 2, 3]
      )

    proto = GrpcCompatibilityMapper.execute_request_to_proto(request)

    assert proto.request_id == "req-1"
    assert proto.controller_session_id == "session-1"
    assert proto.model_id == @model_id
    assert proto.version == @version
    assert proto.rendered_prompt_utf8 == "hello"
    assert proto.input_tokens == 2

    assert proto.params == %GenerationParams{
             max_output_tokens: 16,
             temperature: 0.2,
             top_p: 0.9,
             stop_sequences: ["stop"],
             tools_json: "{}",
             tool_choice_json: "{\"type\":\"auto\"}"
           }

    assert proto.deadline_unix_ms == 456
    assert proto.metadata_json == "{\"tenant\":\"default\"}"
    assert proto.cache_affinity_fingerprint == "fp"
    assert proto.prompt_token_ids == [1, 2, 3]
  end

  test "maps prefix cache score requests and responses" do
    request =
      Operation.PrefixCacheScoreRequest.new!(
        request_id: "req-score",
        controller_session_id: "session-score",
        model_ref: %{model_id: @model_id, version: @version},
        cache_affinity_fingerprint: "fingerprint",
        deadline_unix_ms: 789
      )

    proto = GrpcCompatibilityMapper.prefix_cache_score_request_to_proto(request)

    assert proto.request_id == "req-score"
    assert proto.controller_session_id == "session-score"
    assert proto.model_ref == rpc_model_ref()
    assert proto.cache_affinity_fingerprint == "fingerprint"
    assert proto.deadline_unix_ms == 789

    result =
      GrpcCompatibilityMapper.prefix_cache_score_result_from_response(%ScorePrefixCacheResponse{
        status_code: "ok",
        status_message: "resident",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 999
      })

    assert result.status_code == "ok"
    assert result.status_message == "resident"
    assert result.resident_fingerprint_match == true
    assert result.score_tier == "resident_fingerprint"
    assert result.session_started_unix_ms == 999
  end

  test "maps unload requests and acks" do
    request =
      Operation.UnloadModelRequest.new!(
        model_ref: %{model_id: @model_id, version: @version},
        force: true,
        evict: true
      )

    proto = GrpcMapping.unload_model_request_to_proto(request)

    assert proto.model_id == @model_id
    assert proto.version == @version
    assert proto.force == true
    assert proto.evict == true

    assert %Operation.Ack{ok: true, message: "done"} =
             GrpcCompatibilityMapper.ack_from_response(%Ack{ok: true, message: "done"})
  end

  defp status_response(opts) do
    node_id = Keyword.get(opts, :node_id, Ecto.UUID.generate())

    %StatusResponse{
      worker_state: Keyword.get(opts, :worker_state, :WORKER_STATE_IDLE),
      loaded_models: Keyword.get(opts, :loaded_models, []),
      active_request_count: Keyword.get(opts, :active_request_count, 0),
      node_metadata: %RuntimeNodeMetadata{
        node_id: node_id,
        display_name: "node-#{String.slice(node_id, 0, 8)}",
        hostname: "node.local",
        agent_version: "0.1.0",
        listen_host: "127.0.0.1",
        listen_port: 50_071,
        worker_backend: "mlx"
      },
      runtime_health: Keyword.get(opts, :runtime_health),
      runtime_model_placements: Keyword.get(opts, :runtime_model_placements, []),
      supports_prompt_token_ids: Keyword.get(opts, :supports_prompt_token_ids, false)
    }
  end

  defp rpc_model_ref do
    %RPCModelRef{model_id: @model_id, version: @version}
  end

  defp domain_model_ref do
    %Orchard.RuntimeEndpoint.ModelRef{model_id: @model_id, version: @version}
  end
end
