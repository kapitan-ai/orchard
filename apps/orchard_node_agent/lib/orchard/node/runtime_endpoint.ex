defmodule Orchard.Node.RuntimeEndpoint do
  @moduledoc """
  First-party BEAM Runtime Endpoint facade served by the Node Agent.

  The facade maps transport-independent Runtime Endpoint operations onto the
  existing node-agent status, model lifecycle, request execution, cancellation,
  and prefix-cache scoring paths.
  """

  alias Orchard.InferenceEvent
  alias Orchard.Node.{RuntimeEndpointMapper, RuntimeServer, Status}
  alias Orchard.RuntimeEndpoint.{GrpcMapping, Operation, Target}

  @task_supervisor Orchard.Node.RuntimeEndpointTaskSupervisor

  @spec status(Target.t() | nil, keyword()) :: {:ok, Orchard.RuntimeEndpoint.Observation.t()}
  def status(target \\ nil, _opts \\ []) do
    {:ok, RuntimeEndpointMapper.observation_from_status(target, Status.current())}
  end

  @spec ensure_model_loaded(Operation.EnsureModelLoadedRequest.t(), keyword()) ::
          {:ok, Operation.EnsureModelLoadedResult.t()}
  def ensure_model_loaded(%Operation.EnsureModelLoadedRequest{} = request, _opts \\ []) do
    response =
      request
      |> GrpcMapping.ensure_model_loaded_request_to_proto()
      |> Status.ensure_model_loaded()

    {:ok, GrpcMapping.ensure_model_loaded_result_from_response(response)}
  end

  @spec unload_model(Operation.UnloadModelRequest.t(), keyword()) :: {:ok, Operation.Ack.t()}
  def unload_model(%Operation.UnloadModelRequest{} = request, _opts \\ []) do
    response =
      request
      |> GrpcMapping.unload_model_request_to_proto()
      |> Status.unload_model()

    {:ok, RuntimeEndpointMapper.ack_from_response(response)}
  end

  @spec execute_inference(Operation.ExecuteRequest.t(), pid(), reference(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def execute_inference(%Operation.ExecuteRequest{} = request, owner, stream_ref, opts \\ [])
      when is_pid(owner) and is_reference(stream_ref) do
    proto_request = RuntimeEndpointMapper.execute_request_to_proto(request)

    Task.Supervisor.start_child(task_supervisor(opts), fn ->
      execute_stream(proto_request, owner, stream_ref)
    end)
  end

  @spec cancel_inference(Operation.CancelRequest.t(), keyword()) :: :ok | {:error, term()}
  def cancel_inference(%Operation.CancelRequest{} = request, _opts \\ []) do
    request.request_id
    |> Status.cancel_request(request.controller_session_id)
    |> RuntimeEndpointMapper.ack_from_response()
    |> cancel_result()
  end

  @spec score_prefix_cache(Operation.PrefixCacheScoreRequest.t(), keyword()) ::
          {:ok, Operation.PrefixCacheScoreResult.t()}
  def score_prefix_cache(%Operation.PrefixCacheScoreRequest{} = request, _opts \\ []) do
    response =
      request
      |> RuntimeEndpointMapper.prefix_cache_score_request_to_proto()
      |> Status.score_prefix_cache()

    {:ok, RuntimeEndpointMapper.prefix_cache_score_result_from_response(response)}
  end

  defp execute_stream(request, owner, stream_ref) do
    owner_ref = Process.monitor(owner)

    try do
      do_execute_stream(request, owner, owner_ref, stream_ref)
    rescue
      _error ->
        send(
          owner,
          {:runtime_endpoint_done, stream_ref, {:error, :runtime_endpoint_stream_failed}}
        )
    catch
      :exit, _reason ->
        send(
          owner,
          {:runtime_endpoint_done, stream_ref, {:error, :runtime_endpoint_stream_failed}}
        )
    after
      Process.demonitor(owner_ref, [:flush])
    end
  end

  defp do_execute_stream(request, owner, owner_ref, stream_ref) do
    case Status.prepare_request(request, self()) do
      :ok ->
        send(owner, {:runtime_endpoint_event, stream_ref, request.request_id, accepted_event()})
        start_prepared_request(request, owner, owner_ref, stream_ref)

      {:error, reason} ->
        send_failed(owner, stream_ref, request.request_id, reason)
        send(owner, {:runtime_endpoint_done, stream_ref, :ok})
    end
  end

  defp start_prepared_request(request, owner, owner_ref, stream_ref) do
    case Status.start_request(request) do
      :ok ->
        forward_runtime_events(owner, owner_ref, stream_ref, request.request_id)

      {:error, reason} ->
        send_failed(owner, stream_ref, request.request_id, reason)
        send(owner, {:runtime_endpoint_done, stream_ref, :ok})
    end
  end

  defp forward_runtime_events(owner, owner_ref, stream_ref, request_id) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:node_runtime_event, ^request_id, %InferenceEvent{} = event} ->
        send(owner, {:runtime_endpoint_event, stream_ref, request_id, event})

        if InferenceEvent.terminal?(event) do
          send(owner, {:runtime_endpoint_done, stream_ref, :ok})
        else
          forward_runtime_events(owner, owner_ref, stream_ref, request_id)
        end
    end
  end

  defp accepted_event do
    InferenceEvent.accepted(System.system_time(:millisecond))
  end

  defp cancel_result(%Operation.Ack{ok: true}), do: :ok

  defp cancel_result(%Operation.Ack{ok: false, message: message}),
    do: {:error, {:cancel_rejected, message}}

  defp send_failed(owner, stream_ref, request_id, reason) do
    code = RuntimeServer.safe_failure_reason_code(reason)
    message = failure_message(code)

    send(
      owner,
      {:runtime_endpoint_event, stream_ref, request_id,
       InferenceEvent.failed(code, message, false)}
    )
  end

  defp failure_message("model_busy"), do: "model already has an active request"
  defp failure_message("model_not_loaded"), do: "model is not loaded"
  defp failure_message("request_already_active"), do: "request is already active"
  defp failure_message("request_not_prepared"), do: "request is not prepared"
  defp failure_message("worker_unavailable"), do: "worker process became unavailable"
  defp failure_message("license_invalid"), do: "node-agent license invalid"
  defp failure_message(_code), do: "runtime request failed"

  defp task_supervisor(opts), do: Keyword.get(opts, :task_supervisor, @task_supervisor)
end
