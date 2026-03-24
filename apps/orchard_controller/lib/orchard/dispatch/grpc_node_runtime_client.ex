defmodule Orchard.Dispatch.GrpcNodeRuntimeClient do
  @moduledoc """
  Real gRPC client for controller → node-agent dispatch over the
  `NodeRuntimeService` contract.
  """

  alias Orchard.Cluster.V1.{
    Ack,
    CancelInferenceRequest,
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest,
    InferenceEventMapper,
    NodeRuntimeService,
    StatusRequest,
    StatusResponse
  }

  alias Orchard.InferenceEvent

  @rpc_timeout_ms 5_000

  @doc """
  Open a gRPC channel to the given target.

  Target is `[host: host, port: port]` from config.
  Returns `{:ok, channel}` or `{:error, reason}`.
  """
  @spec connect(keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect(target) do
    host = Keyword.fetch!(target, :host)
    port = Keyword.fetch!(target, :port)
    address = "#{host}:#{port}"

    case GRPC.Stub.connect(address) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  @doc "Disconnect a gRPC channel."
  @spec disconnect(GRPC.Channel.t()) :: :ok
  def disconnect(channel) do
    case GRPC.Stub.disconnect(channel) do
      {:ok, _channel} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Get the node-agent status.

  Options:
  - `:timeout` — RPC timeout in milliseconds (default: #{@rpc_timeout_ms})
  """
  @spec status(GRPC.Channel.t(), keyword()) :: {:ok, StatusResponse.t()} | {:error, term()}
  def status(channel, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @rpc_timeout_ms)

    case NodeRuntimeService.Stub.get_status(channel, %StatusRequest{}, timeout: timeout) do
      {:ok, %StatusResponse{} = response} -> {:ok, response}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc "Ask the node-agent to ensure a model is loaded."
  @spec ensure_model_loaded(GRPC.Channel.t(), EnsureModelLoadedRequest.t(), keyword()) ::
          {:ok, EnsureModelLoadedResponse.t()} | {:error, term()}
  def ensure_model_loaded(channel, %EnsureModelLoadedRequest{} = request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @rpc_timeout_ms)

    case NodeRuntimeService.Stub.ensure_model_loaded(channel, request, timeout: timeout) do
      {:ok, %EnsureModelLoadedResponse{} = response} -> {:ok, response}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Start a server-streaming ExecuteInference call.

  Streams inference events to the calling process as
  `{:dispatch_event, request_id, event}` messages.

  Returns `{:ok, task_ref}` where `task_ref` is a reference that will
  receive a `{:dispatch_done, task_ref, result}` message when the
  stream completes.

  The result is `:ok` on normal completion or `{:error, reason}` on failure.
  """
  @spec execute_inference(GRPC.Channel.t(), ExecuteInferenceRequest.t(), keyword()) ::
          {:ok, reference()}
  def execute_inference(channel, %ExecuteInferenceRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    task_ref = make_ref()

    Task.start(fn ->
      result = stream_inference_events(channel, request, owner, task_ref)
      send(owner, {:dispatch_done, task_ref, result})
    end)

    {:ok, task_ref}
  end

  @doc "Send a cancellation request to the node-agent."
  @spec cancel_inference(GRPC.Channel.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def cancel_inference(channel, request_id, controller_session_id \\ nil) do
    case NodeRuntimeService.Stub.cancel_inference(
           channel,
           %CancelInferenceRequest{
             request_id: request_id,
             controller_session_id: controller_session_id || ""
           },
           timeout: @rpc_timeout_ms
         ) do
      {:ok, %Ack{ok: true}} -> :ok
      {:ok, %Ack{ok: false, message: message}} -> {:error, {:cancel_rejected, message}}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  # -- Private ---------------------------------------------------------------

  defp stream_inference_events(channel, request, owner, task_ref) do
    case NodeRuntimeService.Stub.execute_inference(channel, request, timeout: :infinity) do
      {:ok, stream} ->
        consume_stream(stream, owner, task_ref, request.request_id)

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp consume_stream(stream, owner, task_ref, request_id) do
    Enum.reduce_while(stream, :ok, fn item, _acc ->
      handle_stream_item(item, owner, task_ref, request_id)
    end)
  end

  defp handle_stream_item({:ok, proto_event}, owner, task_ref, request_id) do
    case InferenceEventMapper.from_proto(proto_event) do
      {:ok, event} ->
        send(owner, {:dispatch_event, task_ref, request_id, event})

        if InferenceEvent.terminal?(event) do
          {:halt, :ok}
        else
          {:cont, :ok}
        end

      {:error, reason} ->
        send(
          owner,
          {:dispatch_event, task_ref, request_id,
           InferenceEvent.failed(
             "dispatch_invalid_event",
             "node emitted an invalid event: #{inspect(reason)}",
             false
           )}
        )

        {:halt, :ok}
    end
  end

  defp handle_stream_item({:error, reason}, owner, task_ref, request_id) do
    error = normalize_error(reason)

    unless error == :node_unavailable do
      send(
        owner,
        {:dispatch_event, task_ref, request_id,
         InferenceEvent.failed(
           "dispatch_stream_error",
           "node stream failed: #{inspect(error)}",
           false
         )}
      )
    end

    {:halt, {:error, error}}
  end

  defp normalize_error(%GRPC.RPCError{status: status})
       when status in [:unavailable, :cancelled] do
    :node_unavailable
  end

  defp normalize_error(%GRPC.RPCError{status: :deadline_exceeded}) do
    :node_timeout
  end

  defp normalize_error(%GRPC.RPCError{status: status, message: message}) do
    {:rpc_error, status, message}
  end

  defp normalize_error(other), do: {:rpc_error, inspect(other)}
end
