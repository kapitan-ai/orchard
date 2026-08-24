defmodule Orchard.Node.RuntimeServer do
  @moduledoc """
  Node-agent gRPC service boundary for status, model lifecycle, inference,
  cancellation, and scheduler cache probes.
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
  alias Orchard.Node
  alias Orchard.Node.Status
  alias Orchard.SentryContext

  @known_failure_reasons MapSet.new([
                           :model_busy,
                           :model_not_loaded,
                           :request_already_active,
                           :request_not_prepared,
                           :worker_unavailable
                         ])

  @spec get_status(StatusRequest.t(), Orchard.GRPCTypes.server_stream()) ::
          Orchard.Cluster.V1.StatusResponse.t()
  def get_status(%StatusRequest{}, _stream), do: Status.current()

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t(), Orchard.GRPCTypes.server_stream()) ::
          Orchard.Cluster.V1.EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request, _stream) do
    Status.ensure_model_loaded(request)
  end

  @spec unload_model(UnloadModelRequest.t(), Orchard.GRPCTypes.server_stream()) ::
          Orchard.Cluster.V1.Ack.t()
  def unload_model(%UnloadModelRequest{} = request, _stream) do
    Status.unload_model(request)
  end

  @spec execute_inference(ExecuteInferenceRequest.t(), Orchard.GRPCTypes.server_stream()) :: :ok
  def execute_inference(%ExecuteInferenceRequest{} = request, stream) do
    SentryContext.clear_all()

    # Completed requests clear process-local Sentry context for future gRPC
    # process reuse. Exceptions intentionally skip this branch so crash capture
    # can still see the request context set below.
    case do_execute_inference(request, stream) do
      result ->
        SentryContext.clear_all()
        result
    end
  end

  defp do_execute_inference(%ExecuteInferenceRequest{} = request, stream) do
    put_execute_request_context(request)

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
        put_prepare_request_failed_context(reason)
        send_failed(stream, reason)
    end
  end

  @spec cancel_inference(CancelInferenceRequest.t(), Orchard.GRPCTypes.server_stream()) ::
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

  @spec score_prefix_cache(ScorePrefixCacheRequest.t(), Orchard.GRPCTypes.server_stream()) ::
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

  @doc false
  @spec safe_failure_reason_code(term()) :: String.t()
  def safe_failure_reason_code(reason) when is_atom(reason) do
    if MapSet.member?(@known_failure_reasons, reason) do
      Atom.to_string(reason)
    else
      "runtime_error"
    end
  end

  def safe_failure_reason_code(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> then(fn value ->
      if value in [
           "model_busy",
           "model_not_loaded",
           "request_already_active",
           "request_not_prepared",
           "worker_unavailable"
         ] do
        value
      else
        "runtime_error"
      end
    end)
  end

  def safe_failure_reason_code(_reason), do: "runtime_error"

  defp put_execute_request_context(%ExecuteInferenceRequest{} = request) do
    if SentryContext.node_agent_enabled?() do
      SentryContext.put_tags(%{
        orchard_app: "node_agent",
        orchard_surface: "grpc",
        worker_backend: Node.worker_backend()
      })

      request
      |> SentryContext.build_node_request_extra()
      |> SentryContext.put_extra()

      SentryContext.add_breadcrumb(
        category: "orchard.grpc",
        message: "execute_inference.requested",
        level: :info
      )
    end
  end

  defp put_prepare_request_failed_context(reason) do
    if SentryContext.node_agent_enabled?() do
      SentryContext.add_breadcrumb(
        category: "orchard.grpc",
        message: "prepare_request.failed",
        level: :warning,
        data: %{reason: safe_failure_reason_code(reason)}
      )
    end
  end
end
