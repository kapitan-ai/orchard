defmodule Orchard.Node.RuntimeServer do
  @moduledoc """
  Minimal node-runtime gRPC boundary for the M1 single-node runtime.
  """

  use GRPC.Server, service: Orchard.Cluster.V1.NodeRuntimeService.Service

  alias Orchard.Cluster.V1.{
    Accepted,
    CancelInferenceRequest,
    Completed,
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    InferenceEvent,
    StatusRequest,
    TokenUsage,
    UnloadModelRequest
  }

  alias Orchard.Node.Status

  @spec get_status(StatusRequest.t(), GRPC.Server.Stream.t()) ::
          Orchard.Cluster.V1.StatusResponse.t()
  def get_status(%StatusRequest{}, _stream), do: Status.current()

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t(), GRPC.Server.Stream.t()) ::
          Orchard.Cluster.V1.EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request, _stream) do
    Status.ensure_model_loaded(request)
  end

  @spec unload_model(UnloadModelRequest.t(), GRPC.Server.Stream.t()) :: Orchard.Cluster.V1.Ack.t()
  def unload_model(%UnloadModelRequest{} = request, _stream) do
    Status.unload_model(request)
  end

  @spec execute_inference(ExecuteInferenceRequest.t(), GRPC.Server.Stream.t()) :: :ok
  def execute_inference(%ExecuteInferenceRequest{} = request, stream) do
    :ok = Status.begin_request(request.request_id)

    try do
      send_accepted(stream)
      send_completed(stream, request.input_tokens)
      :ok
    after
      :ok = Status.finish_request(request.request_id)
    end
  end

  @spec cancel_inference(CancelInferenceRequest.t(), GRPC.Server.Stream.t()) ::
          Orchard.Cluster.V1.Ack.t()
  def cancel_inference(
        %CancelInferenceRequest{
          request_id: request_id,
          controller_session_id: controller_session_id
        },
        _stream
      ) do
    Status.cancel_request(request_id, controller_session_id)
  end

  defp send_accepted(stream) do
    GRPC.Server.send_reply(
      stream,
      %InferenceEvent{
        event: {:accepted, %Accepted{accepted_at_unix_ms: System.system_time(:millisecond)}}
      }
    )
  end

  defp send_completed(stream, input_tokens) do
    usage = %TokenUsage{
      input_tokens: input_tokens,
      output_tokens: 0,
      total_tokens: input_tokens
    }

    GRPC.Server.send_reply(
      stream,
      %InferenceEvent{
        event: {:completed, %Completed{finish_reason: :FINISH_REASON_STOP, usage: usage}}
      }
    )
  end
end
