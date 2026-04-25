defmodule Orchard.Node.RuntimeServer do
  @moduledoc """
  Minimal node-runtime gRPC boundary for the M1 single-node runtime.
  """

  use GRPC.Server, service: Orchard.Cluster.V1.NodeRuntimeService.Service

  alias Orchard.Cluster.V1.Accepted
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.InferenceEvent
  alias Orchard.Cluster.V1.InferenceEventMapper
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.StatusRequest
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.InferenceEvent, as: DomainInferenceEvent
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
    case Status.prepare_request(request, self()) do
      :ok ->
        send_accepted(stream)

        case Status.start_request(request) do
          :ok ->
            forward_runtime_events(stream, request.request_id)

          {:error, reason} ->
            send_failed(stream, reason)
        end

      {:error, reason} ->
        send_failed(stream, reason)
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

  @spec score_prefix_cache(ScorePrefixCacheRequest.t(), GRPC.Server.Stream.t()) ::
          ScorePrefixCacheResponse.t()
  def score_prefix_cache(%ScorePrefixCacheRequest{} = request, _stream) do
    Status.score_prefix_cache(request)
  end

  defp forward_runtime_events(stream, request_id) do
    receive do
      {:node_runtime_event, ^request_id, %DomainInferenceEvent{} = event} ->
        GRPC.Server.send_reply(stream, InferenceEventMapper.to_proto(event))

        if DomainInferenceEvent.terminal?(event) do
          :ok
        else
          forward_runtime_events(stream, request_id)
        end
    end
  end

  defp send_accepted(stream) do
    GRPC.Server.send_reply(
      stream,
      %InferenceEvent{
        event: {:accepted, %Accepted{accepted_at_unix_ms: System.system_time(:millisecond)}}
      }
    )
  end

  defp send_failed(stream, reason) do
    {code, message} = normalize_failure_reason(reason)
    failed_event = DomainInferenceEvent.failed(code, message, false)
    GRPC.Server.send_reply(stream, InferenceEventMapper.to_proto(failed_event))
    :ok
  end

  defp normalize_failure_reason(:model_busy),
    do: {"model_busy", "model already has an active request"}

  defp normalize_failure_reason(:model_not_loaded),
    do: {"model_not_loaded", "model is not loaded"}

  defp normalize_failure_reason(:request_already_active),
    do: {"request_already_active", "request is already active"}

  defp normalize_failure_reason(:request_not_prepared),
    do: {"request_not_prepared", "request is not prepared"}

  defp normalize_failure_reason(:worker_unavailable),
    do: {"worker_unavailable", "worker process became unavailable"}

  defp normalize_failure_reason(reason),
    do: {"runtime_error", "runtime request failed: #{inspect(reason)}"}
end
