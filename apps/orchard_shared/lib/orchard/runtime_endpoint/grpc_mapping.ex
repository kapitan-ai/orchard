defmodule Orchard.RuntimeEndpoint.GrpcMapping do
  @moduledoc false

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    GenerationParams,
    UnloadModelRequest
  }

  alias Orchard.RuntimeEndpoint.Operation

  @spec ensure_model_loaded_request_to_proto(Operation.EnsureModelLoadedRequest.t()) ::
          EnsureModelLoadedRequest.t()
  def ensure_model_loaded_request_to_proto(%Operation.EnsureModelLoadedRequest{} = request) do
    %EnsureModelLoadedRequest{
      node_id: request.node_id || "",
      model_id: request.model_ref.model_id,
      version: request.model_ref.version,
      artifact_sha256: request.artifact_sha256 || "",
      preload: request.preload,
      deadline_unix_ms: request.deadline_unix_ms || 0,
      artifact_source_uri: request.artifact_source_uri || ""
    }
  end

  @spec ensure_model_loaded_result_from_response(EnsureModelLoadedResponse.t()) ::
          Operation.EnsureModelLoadedResult.t()
  def ensure_model_loaded_result_from_response(%EnsureModelLoadedResponse{} = response) do
    %Operation.EnsureModelLoadedResult{
      already_loaded: response.already_loaded,
      placement_state: normalize_placement_state(response.placement_state),
      failure_category: normalize_failure_category(response.failure_category),
      failure_code: empty_to_nil(response.failure_code),
      failure_message: empty_to_nil(response.failure_message),
      worker_supports_prompt_token_ids: response.worker_supports_prompt_token_ids
    }
  end

  @spec unload_model_request_to_proto(Operation.UnloadModelRequest.t()) :: UnloadModelRequest.t()
  def unload_model_request_to_proto(%Operation.UnloadModelRequest{} = request) do
    %UnloadModelRequest{
      model_id: request.model_ref.model_id,
      version: request.model_ref.version,
      force: request.force,
      evict: request.evict
    }
  end

  @spec normalize_placement_state(term()) :: atom()
  def normalize_placement_state(:PLACEMENT_STATE_ABSENT), do: :absent
  def normalize_placement_state(:PLACEMENT_STATE_DOWNLOADING), do: :downloading
  def normalize_placement_state(:PLACEMENT_STATE_DOWNLOADED), do: :downloaded
  def normalize_placement_state(:PLACEMENT_STATE_VERIFYING), do: :verifying
  def normalize_placement_state(:PLACEMENT_STATE_CACHED), do: :cached
  def normalize_placement_state(:PLACEMENT_STATE_LOADING), do: :loading
  def normalize_placement_state(:PLACEMENT_STATE_LOADED), do: :loaded
  def normalize_placement_state(:PLACEMENT_STATE_UNLOADING), do: :unloading
  def normalize_placement_state(:PLACEMENT_STATE_EVICTED), do: :evicted
  def normalize_placement_state(:PLACEMENT_STATE_FAILED), do: :failed
  def normalize_placement_state(:PLACEMENT_STATE_UNSPECIFIED), do: :unknown
  def normalize_placement_state(1), do: :absent
  def normalize_placement_state(2), do: :downloading
  def normalize_placement_state(3), do: :downloaded
  def normalize_placement_state(4), do: :verifying
  def normalize_placement_state(5), do: :cached
  def normalize_placement_state(6), do: :loading
  def normalize_placement_state(7), do: :loaded
  def normalize_placement_state(8), do: :unloading
  def normalize_placement_state(9), do: :evicted
  def normalize_placement_state(10), do: :failed
  def normalize_placement_state(_state), do: :unknown

  @spec normalize_failure_category(term()) :: atom() | nil
  def normalize_failure_category(:MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID), do: :model_invalid

  def normalize_failure_category(:MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED),
    do: :acquisition_failed

  def normalize_failure_category(:MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE),
    do: :runtime_unavailable

  def normalize_failure_category(:MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT), do: :timeout

  def normalize_failure_category(:MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED),
    do: :resource_exhausted

  def normalize_failure_category(:MODEL_LOAD_FAILURE_CATEGORY_INTERNAL), do: :internal
  def normalize_failure_category(_category), do: nil

  @spec generation_params_to_proto(GenerationParams.t() | map() | term()) :: GenerationParams.t()
  def generation_params_to_proto(%GenerationParams{} = params), do: params

  def generation_params_to_proto(%{} = params) do
    %GenerationParams{
      max_output_tokens: non_negative_integer(Operation.value(params, :max_output_tokens)),
      temperature: float_value(Operation.value(params, :temperature)),
      top_p: float_value(Operation.value(params, :top_p)),
      stop_sequences: list_value(params, :stop_sequences),
      tools_json: Operation.value(params, :tools_json) || "",
      tool_choice_json: Operation.value(params, :tool_choice_json) || ""
    }
  end

  def generation_params_to_proto(_params), do: %GenerationParams{}

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp list_value(attrs, key) do
    case Operation.value(attrs, key) do
      values when is_list(values) -> values
      nil -> []
      value -> [value]
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp float_value(value) when is_float(value), do: value
  defp float_value(value) when is_integer(value), do: value / 1
  defp float_value(_value), do: 0.0
end
