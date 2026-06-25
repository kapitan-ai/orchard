defmodule Orchard.RuntimeEndpoint.GrpcCompatibilityClient do
  @moduledoc """
  Runtime Endpoint client backed by the gRPC `NodeRuntimeService` compatibility protocol.
  """

  @behaviour Orchard.RuntimeEndpoint.Client

  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: TransportClient
  alias Orchard.RuntimeEndpoint.{GrpcCompatibilityMapper, Operation, Target}

  defstruct [:channel, :target]

  @type t :: %__MODULE__{channel: GRPC.Channel.t(), target: Target.t()}

  @impl true
  def connect(%Target{transport: :grpc_compat} = target) do
    with {:ok, channel} <- TransportClient.connect(target.address) do
      {:ok, %__MODULE__{channel: channel, target: target}}
    end
  end

  def connect(target) when is_list(target) or is_map(target) do
    target
    |> GrpcCompatibilityMapper.normalize_target()
    |> connect()
  end

  @impl true
  def disconnect(%__MODULE__{channel: channel}) do
    TransportClient.disconnect(channel)
  end

  @impl true
  def status(%__MODULE__{channel: channel, target: target}, opts \\ []) do
    with {:ok, response} <- TransportClient.status(channel, opts) do
      {:ok, GrpcCompatibilityMapper.observation_from_status(target, response)}
    end
  end

  @impl true
  def ensure_model_loaded(
        %__MODULE__{channel: channel},
        %Operation.EnsureModelLoadedRequest{} = request,
        opts \\ []
      ) do
    request = GrpcCompatibilityMapper.ensure_model_loaded_request_to_proto(request)

    with {:ok, response} <- TransportClient.ensure_model_loaded(channel, request, opts) do
      {:ok, GrpcCompatibilityMapper.ensure_model_loaded_result_from_response(response)}
    end
  end

  @impl true
  def unload_model(
        %__MODULE__{channel: channel},
        %Operation.UnloadModelRequest{} = request,
        opts \\ []
      ) do
    request = GrpcCompatibilityMapper.unload_model_request_to_proto(request)

    with {:ok, response} <- TransportClient.unload_model(channel, request, opts) do
      {:ok, GrpcCompatibilityMapper.ack_from_response(response)}
    end
  end

  @impl true
  def execute_inference(
        %__MODULE__{channel: channel},
        %Operation.ExecuteRequest{} = request,
        opts \\ []
      ) do
    owner = Keyword.get(opts, :owner, self())
    runtime_ref = make_ref()
    request = GrpcCompatibilityMapper.execute_request_to_proto(request)

    {:ok, _pid} =
      Task.start(fn ->
        relay_execute_stream(channel, request, owner, runtime_ref, opts)
      end)

    {:ok, runtime_ref}
  end

  @impl true
  def cancel_inference(connection, request, opts \\ [])

  def cancel_inference(
        %__MODULE__{channel: channel},
        %Operation.CancelRequest{} = request,
        _opts
      ) do
    TransportClient.cancel_inference(channel, request.request_id, request.controller_session_id)
  end

  def cancel_inference(%__MODULE__{channel: channel}, request_id, controller_session_id)
      when is_binary(request_id) do
    TransportClient.cancel_inference(channel, request_id, controller_session_id)
  end

  @impl true
  def score_prefix_cache(target_or_connection, request, opts \\ [])

  def score_prefix_cache(
        target_or_connection,
        %Operation.PrefixCacheScoreRequest{} = request,
        opts
      ) do
    target = target_from(target_or_connection)
    proto_request = GrpcCompatibilityMapper.prefix_cache_score_request_to_proto(request)

    with {:ok, response} <-
           TransportClient.score_prefix_cache(target.address, proto_request, opts) do
      {:ok, GrpcCompatibilityMapper.prefix_cache_score_result_from_response(response)}
    end
  end

  def score_prefix_cache(target_or_connection, %ScorePrefixCacheRequest{} = request, opts) do
    target = target_from(target_or_connection)

    with {:ok, response} <- TransportClient.score_prefix_cache(target.address, request, opts) do
      {:ok, GrpcCompatibilityMapper.prefix_cache_score_result_from_response(response)}
    end
  end

  defp relay_execute_stream(channel, request, owner, runtime_ref, opts) do
    relay_opts =
      opts
      |> Keyword.delete(:owner)
      |> Keyword.put(:owner, self())

    {:ok, transport_ref} = TransportClient.execute_inference(channel, request, relay_opts)
    relay_stream_messages(owner, runtime_ref, transport_ref)
  end

  defp relay_stream_messages(owner, runtime_ref, transport_ref) do
    receive do
      {:dispatch_event, ^transport_ref, request_id, event} ->
        send(owner, {:runtime_endpoint_event, runtime_ref, request_id, event})
        relay_stream_messages(owner, runtime_ref, transport_ref)

      {:dispatch_done, ^transport_ref, result} ->
        send(owner, {:runtime_endpoint_done, runtime_ref, result})
    end
  end

  defp target_from(%__MODULE__{target: target}), do: target
  defp target_from(%Target{} = target), do: target
  defp target_from(target), do: GrpcCompatibilityMapper.normalize_target(target)
end
