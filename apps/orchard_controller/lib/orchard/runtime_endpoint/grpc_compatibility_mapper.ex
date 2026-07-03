defmodule Orchard.RuntimeEndpoint.GrpcCompatibilityMapper do
  @moduledoc """
  Maps the gRPC `NodeRuntimeService` compatibility protocol to Runtime Endpoint structs.
  """

  alias Orchard.Cluster.V1.{
    Ack,
    ExecuteInferenceRequest,
    RuntimeHealth,
    RuntimeModelPlacement,
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

  @spec observation_from_status(Target.t() | keyword() | nil, StatusResponse.t() | map()) ::
          Observation.t()
  def observation_from_status(target, %{} = response) do
    target = normalize_target(target)
    metadata = metadata_from_response(response)

    Observation.new(%{
      endpoint_id: endpoint_id(target, metadata),
      target: target,
      observed_at: DateTime.utc_now(),
      availability: availability_from_response(response),
      worker_state: normalize_worker_state(value(response, :worker_state)),
      aggregate_active_request_count:
        non_negative_integer(value(response, :active_request_count)),
      aggregate_max_concurrency: value(response, :max_concurrency),
      metadata: metadata,
      health: health_from_response(value(response, :runtime_health)),
      placements: placements_from_status(response),
      hosted_tool_capabilities: list_value(response, :hosted_tool_capabilities),
      hosted_tool_readiness: list_value(response, :hosted_tool_readiness),
      runtime_memory_budgets: list_value(response, :runtime_memory_budgets),
      runtime_prefix_cache_statuses: list_value(response, :runtime_prefix_cache_statuses),
      supports_prompt_token_ids: value(response, :supports_prompt_token_ids) == true
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

  @spec cancel_request_to_proto(Operation.CancelRequest.t()) ::
          Orchard.Cluster.V1.CancelInferenceRequest.t()
  def cancel_request_to_proto(%Operation.CancelRequest{} = request) do
    %Orchard.Cluster.V1.CancelInferenceRequest{
      request_id: request.request_id,
      controller_session_id: request.controller_session_id
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

  @spec model_ref_to_proto(ModelRef.t()) :: Orchard.Cluster.V1.ModelRef.t()
  def model_ref_to_proto(%ModelRef{} = model_ref) do
    %Orchard.Cluster.V1.ModelRef{
      model_id: model_ref.model_id,
      version: model_ref.version
    }
  end

  @spec model_ref_from_proto(map() | nil) :: ModelRef.t() | nil
  def model_ref_from_proto(nil), do: nil

  def model_ref_from_proto(%{} = model_ref) do
    case ModelRef.new(model_ref) do
      {:ok, normalized} -> normalized
      {:error, :invalid_model_ref} -> nil
    end
  end

  @spec normalize_target(Target.t() | keyword() | map() | nil) :: Target.t() | nil
  def normalize_target(%Target{} = target), do: target

  def normalize_target(target) when is_list(target) or is_map(target) do
    Target.grpc_compat(target)
  end

  def normalize_target(nil), do: nil

  defp metadata_from_response(%{} = response) do
    response
    |> value(:node_metadata)
    |> metadata_from_proto()
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

  defp metadata_from_proto(%{} = metadata) do
    metadata
    |> Map.take([
      :node_id,
      "node_id",
      :display_name,
      "display_name",
      :hostname,
      "hostname",
      :agent_version,
      "agent_version",
      :listen_host,
      "listen_host",
      :listen_port,
      "listen_port",
      :worker_backend,
      "worker_backend"
    ])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_metadata_key(key), value)
    end)
    |> compact_nil_values()
  end

  defp availability_from_response(%{} = response) do
    case value(response, :runtime_health) do
      %RuntimeHealth{ready: true} -> :available
      %RuntimeHealth{ready: false} -> :degraded
      %{ready: true} -> :available
      %{"ready" => true} -> :available
      %{ready: false} -> :degraded
      %{"ready" => false} -> :degraded
      nil -> :available
      _other -> :unknown
    end
  end

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

  defp health_from_response(%{} = health) do
    %{
      ready: value(health, :ready),
      health_code: empty_to_nil(value(health, :health_code)),
      health_message: empty_to_nil(value(health, :health_message)),
      affected_model: model_ref_from_proto(value(health, :affected_model))
    }
    |> compact_nil_values()
  end

  defp placements_from_status(%{} = response) do
    placements = list_value(response, :runtime_model_placements)

    response
    |> list_value(:loaded_models)
    |> Enum.flat_map(fn proto_ref ->
      case model_ref_from_proto(proto_ref) do
        %ModelRef{} = model_ref ->
          [
            Placement.new(%{
              model_ref: model_ref,
              state: :loaded,
              capacity: placement_capacity(model_ref, placements)
            })
          ]

        nil ->
          []
      end
    end)
  end

  defp placement_capacity(%ModelRef{} = model_ref, placements) do
    matches = Enum.filter(placements, &model_ref_matches?(&1, model_ref))

    case matches do
      [placement] ->
        PlacementCapacity.new(%{
          model_ref: model_ref,
          active_request_count: value(placement, :active_request_count),
          max_concurrency: value(placement, :max_concurrency),
          source: :grpc_compatibility_status
        })

      [] ->
        PlacementCapacity.unknown(model_ref, :grpc_compatibility_status)

      _duplicates ->
        PlacementCapacity.new(%{
          model_ref: model_ref,
          active_request_count: :duplicate,
          max_concurrency: :duplicate,
          source: :duplicate_grpc_compatibility_status
        })
    end
  end

  defp model_ref_matches?(%RuntimeModelPlacement{} = placement, %ModelRef{} = model_ref) do
    ModelRef.equal?(placement.model_ref, model_ref)
  end

  defp model_ref_matches?(%{} = placement, %ModelRef{} = model_ref) do
    placement
    |> value(:model_ref)
    |> ModelRef.equal?(model_ref)
  end

  defp model_ref_matches?(_placement, _model_ref), do: false

  defp normalize_worker_state(:WORKER_STATE_STARTING), do: :starting
  defp normalize_worker_state(:WORKER_STATE_IDLE), do: :idle
  defp normalize_worker_state(:WORKER_STATE_BUSY), do: :busy
  defp normalize_worker_state(:WORKER_STATE_STOPPING), do: :stopping
  defp normalize_worker_state(:WORKER_STATE_FAILED), do: :failed
  defp normalize_worker_state(:WORKER_STATE_STOPPED), do: :stopped
  defp normalize_worker_state(:WORKER_STATE_UNSPECIFIED), do: :unknown
  defp normalize_worker_state(1), do: :starting
  defp normalize_worker_state(2), do: :idle
  defp normalize_worker_state(3), do: :busy
  defp normalize_worker_state(4), do: :stopping
  defp normalize_worker_state(5), do: :failed
  defp normalize_worker_state(6), do: :stopped
  defp normalize_worker_state(_other), do: :unknown

  defp endpoint_id(%Target{id: id}, _metadata) when is_binary(id) and id != "", do: id

  defp endpoint_id(_target, %{node_id: node_id}) when is_binary(node_id) and node_id != "",
    do: "node:#{node_id}"

  defp endpoint_id(_target, _metadata), do: nil

  defp normalize_metadata_key(key) when key in [:node_id, "node_id"], do: :node_id
  defp normalize_metadata_key(key) when key in [:display_name, "display_name"], do: :display_name
  defp normalize_metadata_key(key) when key in [:hostname, "hostname"], do: :hostname

  defp normalize_metadata_key(key) when key in [:agent_version, "agent_version"],
    do: :agent_version

  defp normalize_metadata_key(key) when key in [:listen_host, "listen_host"], do: :listen_host
  defp normalize_metadata_key(key) when key in [:listen_port, "listen_port"], do: :listen_port

  defp normalize_metadata_key(key) when key in [:worker_backend, "worker_backend"],
    do: :worker_backend

  defp list_value(attrs, key) do
    case value(attrs, key) do
      list when is_list(list) -> list
      nil -> []
      other -> [other]
    end
  end

  defp value(%{} = attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end

  defp empty_to_nil(value) when value in [nil, ""], do: nil
  defp empty_to_nil(value), do: value

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp compact_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
