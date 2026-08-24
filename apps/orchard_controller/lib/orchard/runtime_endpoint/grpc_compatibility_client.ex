defmodule Orchard.RuntimeEndpoint.GrpcCompatibilityClient do
  @moduledoc """
  Runtime Endpoint client backed by the gRPC `NodeRuntimeService` compatibility protocol.
  """

  @behaviour Orchard.RuntimeEndpoint.Client

  alias Orchard.Cluster.V1.{ScorePrefixCacheRequest, ScorePrefixCacheResponse}
  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: TransportClient
  alias Orchard.Nodes

  alias Orchard.RuntimeEndpoint.{
    GrpcCompatibilityMapper,
    GrpcMapping,
    GrpcMTLS,
    Operation,
    Target
  }

  defstruct [:channel, :target, :security]

  @type t :: %__MODULE__{
          channel: Orchard.GRPCTypes.channel(),
          target: Target.t(),
          security: GrpcMTLS.connection_security()
        }

  @impl true
  def connect(%Target{transport: :grpc_compat} = target) do
    with {:ok, security} <- GrpcMTLS.for_target(target),
         {:ok, channel} <- connect_transport(target, security) do
      {:ok, %__MODULE__{channel: channel, target: target, security: security}}
    end
  end

  def connect(%Target{} = target), do: {:error, {:unsupported_transport, target.transport}}

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
  def status(%__MODULE__{channel: channel, target: target, security: security}, opts \\ []) do
    case TransportClient.status(channel, opts) do
      {:ok, response} ->
        observation = GrpcCompatibilityMapper.observation_from_status(target, response)
        authenticated_status_result(target, observation, security)

      {:error, reason} ->
        transport_status_error(reason, security)
    end
  end

  @impl true
  def ensure_model_loaded(
        %__MODULE__{channel: channel},
        %Operation.EnsureModelLoadedRequest{} = request,
        opts \\ []
      ) do
    request = GrpcMapping.ensure_model_loaded_request_to_proto(request)

    with {:ok, response} <- TransportClient.ensure_model_loaded(channel, request, opts) do
      {:ok, GrpcMapping.ensure_model_loaded_result_from_response(response)}
    end
  end

  @impl true
  def unload_model(
        %__MODULE__{channel: channel},
        %Operation.UnloadModelRequest{} = request,
        opts \\ []
      ) do
    request = GrpcMapping.unload_model_request_to_proto(request)

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
        %__MODULE__{} = connection,
        %Operation.PrefixCacheScoreRequest{} = request,
        opts
      ) do
    request = GrpcCompatibilityMapper.prefix_cache_score_request_to_proto(request)
    score_prefix_cache(connection, request, opts)
  end

  def score_prefix_cache(target, %Operation.PrefixCacheScoreRequest{} = request, opts) do
    request = GrpcCompatibilityMapper.prefix_cache_score_request_to_proto(request)
    score_prefix_cache(target, request, opts)
  end

  def score_prefix_cache(
        %__MODULE__{channel: channel},
        %ScorePrefixCacheRequest{} = request,
        opts
      ) do
    map_prefix_cache_score(TransportClient.score_prefix_cache(channel, request, opts))
  end

  def score_prefix_cache(target, %ScorePrefixCacheRequest{} = request, opts) do
    target = target_from(target)

    case connect(target) do
      {:ok, connection} ->
        try do
          score_prefix_cache(connection, request, opts)
        after
          disconnect(connection)
        end

      {:error, _reason} ->
        {:ok,
         GrpcCompatibilityMapper.prefix_cache_score_result_from_response(
           %ScorePrefixCacheResponse{
             status_code: "error",
             status_message: "runtime endpoint unavailable",
             score_tier: "unknown"
           }
         )}
    end
  end

  defp map_prefix_cache_score({:ok, response}) do
    {:ok, GrpcCompatibilityMapper.prefix_cache_score_result_from_response(response)}
  end

  defp connect_transport(target, :plaintext_compatibility) do
    TransportClient.connect(target.address)
  end

  defp connect_transport(target, {:mutual_tls, credential, _peer}) do
    TransportClient.connect(target.address, cred: credential)
  end

  defp authenticated_status_result(_target, observation, :plaintext_compatibility) do
    {:ok, observation}
  end

  defp authenticated_status_result(target, observation, {:mutual_tls, _credential, peer}) do
    case Nodes.observe_authenticated_status(
           target,
           observation,
           observation.observed_at,
           peer
         ) do
      {:ok, _node} -> {:ok, observation}
      :noop -> {:error, :authenticated_observation_rejected}
    end
  end

  defp transport_status_error(reason, :plaintext_compatibility), do: {:error, reason}

  defp transport_status_error(_reason, {:mutual_tls, _credential, _peer}),
    do: {:error, :authenticated_transport_failed}

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

  defp target_from(%Target{} = target), do: target
  defp target_from(target), do: GrpcCompatibilityMapper.normalize_target(target)
end
