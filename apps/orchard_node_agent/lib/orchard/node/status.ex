defmodule Orchard.Node.Status do
  @moduledoc """
  Thin facade over the node-agent runtime state owned by `Orchard.Node.ModelManager`.
  """

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Node.ModelManager

  @spec current() :: StatusResponse.t()
  def current, do: ModelManager.current()

  @spec reset() :: :ok
  def reset, do: ModelManager.reset()

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t()) :: EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request) do
    ModelManager.ensure_model_loaded(request)
  end

  @spec unload_model(UnloadModelRequest.t()) :: Ack.t()
  def unload_model(%UnloadModelRequest{} = request) do
    ModelManager.unload_model(request)
  end

  @spec prepare_request(ExecuteInferenceRequest.t(), pid()) :: :ok | {:error, term()}
  def prepare_request(%ExecuteInferenceRequest{} = request, subscriber) when is_pid(subscriber) do
    ModelManager.prepare_request(request, subscriber)
  end

  @spec start_request(ExecuteInferenceRequest.t()) :: :ok | {:error, term()}
  def start_request(%ExecuteInferenceRequest{} = request) do
    ModelManager.start_request(request)
  end

  @spec cancel_request(String.t(), String.t() | nil) :: Ack.t()
  def cancel_request(request_id, controller_session_id \\ nil) when is_binary(request_id) do
    ModelManager.cancel_request(request_id, controller_session_id)
  end
end
