defmodule Orchard.Node.RuntimeEndpointMapper do
  @moduledoc false

  alias Orchard.Cluster.V1.{
    Ack,
    ExecuteInferenceRequest,
    RuntimeHealth,
    RuntimeNodeMetadata,
    ScorePrefixCacheRequest,
    ScorePrefixCacheResponse,
    StatusResponse
  }

  alias Orchard.RuntimeEndpoint.GrpcMapping

  alias Orchard.RuntimeEndpoint.{
    ModelRef,
    Observation,
    Operation,
    Placement,
    PlacementCapacity,
    Target
  }

  @spec observation_from_status(Target.t() | nil, StatusResponse.t()) :: Observation.t()
  def observation_from_status(target, %StatusResponse{} = response) do
    metadata = metadata_from_proto(response.node_metadata)

    Observation.new(%{
      endpoint_id: endpoint_id(target, metadata),
      target: target,
      observed_at: DateTime.utc_now(),
      availability: availability_from_response(response.runtime_health),
      worker_state: normalize_worker_state(response.worker_state),
      aggregate_active_request_count: non_negative_integer(response.active_request_count),
      aggregate_max_concurrency: response.max_concurrency,
      metadata: metadata,
      health: health_from_response(response.runtime_health),
      placements: placements_from_status(response),
      hosted_tool_capabilities: response.hosted_tool_capabilities,
      hosted_tool_readiness: response.hosted_tool_readiness,
      runtime_memory_budgets: response.runtime_memory_budgets,
      runtime_prefix_cache_statuses: response.runtime_prefix_cache_statuses,
      supports_prompt_token_ids: response.supports_prompt_token_ids
    })
  end

  @spec ack_from_response(Ack.t()) :: Operation.Ack.t()
  def ack_from_response(%Ack{} = response) do
    %Operation.Ack{ok: response.ok, message: response.message || ""}
  end

  @spec execute_request_to_proto(Operation.ExecuteRequest.t()) :: ExecuteInferenceRequest.t()
  def execute_request_to_proto(%Operation.ExecuteRequest{} = request) do
    %ExecuteInferenceRequest{
      request_id: request.request_id,
      controller_session_id: request.controller_session_id,
      model_id: request.model_ref.model_id,
      version: request.model_ref.version,
      rendered_prompt_utf8: request.rendered_prompt_utf8,
      input_tokens: request.input_tokens,
      params: GrpcMapping.generation_params_to_proto(request.params),
      deadline_unix_ms: request.deadline_unix_ms || 0,
      metadata_json: request.metadata_json || "{}",
      cache_affinity_fingerprint: request.cache_affinity_fingerprint || "",
      prompt_token_ids: request.prompt_token_ids || []
    }
  end

  @spec prefix_cache_score_request_to_proto(Operation.PrefixCacheScoreRequest.t()) ::
          ScorePrefixCacheRequest.t()
  def prefix_cache_score_request_to_proto(%Operation.PrefixCacheScoreRequest{} = request) do
    %ScorePrefixCacheRequest{
      request_id: request.request_id,
      controller_session_id: request.controller_session_id,
      model_ref: model_ref_to_proto(request.model_ref),
      cache_affinity_fingerprint: request.cache_affinity_fingerprint,
      deadline_unix_ms: request.deadline_unix_ms || 0
    }
  end

  @spec prefix_cache_score_result_from_response(ScorePrefixCacheResponse.t()) ::
          Operation.PrefixCacheScoreResult.t()
  def prefix_cache_score_result_from_response(%ScorePrefixCacheResponse{} = response) do
    %Operation.PrefixCacheScoreResult{
      status_code: response.status_code || "unknown",
      status_message: response.status_message || "",
      resident_fingerprint_match: response.resident_fingerprint_match,
      score_tier: response.score_tier || "unknown",
      session_started_unix_ms: non_negative_integer(response.session_started_unix_ms)
    }
  end

  defp model_ref_to_proto(%ModelRef{} = model_ref) do
    %Orchard.Cluster.V1.ModelRef{model_id: model_ref.model_id, version: model_ref.version}
  end

  defp model_ref_from_proto(nil), do: nil

  defp model_ref_from_proto(%{} = model_ref) do
    case ModelRef.new(model_ref) do
      {:ok, normalized} -> normalized
      {:error, :invalid_model_ref} -> nil
    end
  end

  defp metadata_from_proto(%RuntimeNodeMetadata{} = metadata) do
    %{
      node_id: empty_to_nil(metadata.node_id),
      display_name: empty_to_nil(metadata.display_name),
      hostname: empty_to_nil(metadata.hostname),
      agent_version: empty_to_nil(metadata.agent_version),
      listen_host: empty_to_nil(metadata.listen_host),
      listen_port: non_negative_integer(metadata.listen_port),
      worker_backend: empty_to_nil(metadata.worker_backend)
    }
    |> compact_nil_values()
  end

  defp metadata_from_proto(nil), do: %{}

  defp availability_from_response(%RuntimeHealth{ready: true}), do: :available
  defp availability_from_response(%RuntimeHealth{ready: false}), do: :degraded
  defp availability_from_response(nil), do: :available
  defp availability_from_response(_health), do: :unknown

  defp health_from_response(%RuntimeHealth{} = health) do
    %{
      ready: health.ready,
      health_code: empty_to_nil(health.health_code),
      health_message: empty_to_nil(health.health_message),
      affected_model: model_ref_from_proto(health.affected_model)
    }
    |> compact_nil_values()
  end

  defp health_from_response(nil), do: %{}

  defp placements_from_status(%StatusResponse{} = response) do
    Enum.flat_map(response.loaded_models, fn proto_ref ->
      case model_ref_from_proto(proto_ref) do
        %ModelRef{} = model_ref ->
          [
            Placement.new(%{
              model_ref: model_ref,
              state: :loaded,
              capacity: placement_capacity(model_ref, response.runtime_model_placements)
            })
          ]

        nil ->
          []
      end
    end)
  end

  defp placement_capacity(%ModelRef{} = model_ref, placements) do
    case Enum.filter(placements, &ModelRef.equal?(&1.model_ref, model_ref)) do
      [placement] ->
        PlacementCapacity.new(%{
          model_ref: model_ref,
          active_request_count: placement.active_request_count,
          max_concurrency: placement.max_concurrency,
          source: :beam_runtime_endpoint_status
        })

      [] ->
        PlacementCapacity.unknown(model_ref, :beam_runtime_endpoint_status)

      _duplicates ->
        PlacementCapacity.new(%{
          model_ref: model_ref,
          active_request_count: :duplicate,
          max_concurrency: :duplicate,
          source: :duplicate_beam_runtime_endpoint_status
        })
    end
  end

  defp normalize_worker_state(:WORKER_STATE_STARTING), do: :starting
  defp normalize_worker_state(:WORKER_STATE_IDLE), do: :idle
  defp normalize_worker_state(:WORKER_STATE_BUSY), do: :busy
  defp normalize_worker_state(:WORKER_STATE_STOPPING), do: :stopping
  defp normalize_worker_state(:WORKER_STATE_FAILED), do: :failed
  defp normalize_worker_state(:WORKER_STATE_STOPPED), do: :stopped
  defp normalize_worker_state(_state), do: :unknown

  defp endpoint_id(%Target{id: id}, _metadata) when is_binary(id) and id != "", do: id

  defp endpoint_id(_target, %{node_id: node_id}) when is_binary(node_id) and node_id != "",
    do: "node:#{node_id}"

  defp endpoint_id(_target, _metadata), do: nil

  defp empty_to_nil(value) when value in [nil, ""], do: nil
  defp empty_to_nil(value), do: value
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
  defp compact_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
