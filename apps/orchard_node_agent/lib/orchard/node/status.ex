defmodule Orchard.Node.Status do
  @moduledoc """
  Thin facade over the node-agent runtime state owned by `Orchard.Node.ModelManager`.
  """

  require Logger

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Licensing
  alias Orchard.Licensing.Gate
  alias Orchard.Node.ModelLoadFailure
  alias Orchard.Node.ModelManager

  @license_denial_logged_key {__MODULE__, :license_denial_logged?}

  @spec current() :: StatusResponse.t()
  def current, do: ModelManager.current()

  @spec reset() :: :ok
  def reset, do: ModelManager.reset()

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t()) :: EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request) do
    case Gate.check() do
      :ok ->
        ModelManager.ensure_model_loaded(request)

      {:error, %Licensing{} = status} ->
        status
        |> license_invalid_message()
        |> then(&ModelLoadFailure.to_response({:license_invalid, &1}))
    end
  end

  @spec unload_model(UnloadModelRequest.t()) :: Ack.t()
  def unload_model(%UnloadModelRequest{} = request) do
    ModelManager.unload_model(request)
  end

  @spec prepare_request(ExecuteInferenceRequest.t(), pid()) :: :ok | {:error, term()}
  def prepare_request(%ExecuteInferenceRequest{} = request, subscriber) when is_pid(subscriber) do
    case Gate.check() do
      :ok ->
        ModelManager.prepare_request(request, subscriber)

      {:error, %Licensing{} = status} ->
        log_license_denial_once(status)
        {:error, :license_invalid}
    end
  end

  @spec start_request(ExecuteInferenceRequest.t()) :: :ok | {:error, term()}
  def start_request(%ExecuteInferenceRequest{} = request) do
    case Gate.check() do
      :ok ->
        ModelManager.start_request(request)

      {:error, %Licensing{} = status} ->
        cleanup_prepared_request(request)
        log_license_denial_once(status)
        {:error, :license_invalid}
    end
  end

  @spec cancel_request(String.t(), String.t() | nil) :: Ack.t()
  def cancel_request(request_id, controller_session_id \\ nil) when is_binary(request_id) do
    ModelManager.cancel_request(request_id, controller_session_id)
  end

  @spec score_prefix_cache(ScorePrefixCacheRequest.t()) :: ScorePrefixCacheResponse.t()
  def score_prefix_cache(%ScorePrefixCacheRequest{} = request) do
    ModelManager.score_prefix_cache(request)
  end

  defp license_invalid_message(%Licensing{} = status) do
    denial = Gate.denial(status)
    "Node-agent license invalid: #{denial.message} #{denial.activation_guidance}"
  end

  defp cleanup_prepared_request(%ExecuteInferenceRequest{} = request) do
    _ = ModelManager.cancel_request(request.request_id, request.controller_session_id)
    :ok
  end

  defp log_license_denial_once(%Licensing{} = status) do
    unless :persistent_term.get(@license_denial_logged_key, false) do
      :persistent_term.put(@license_denial_logged_key, true)
      Logger.warning(license_invalid_message(status))
    end
  end
end
