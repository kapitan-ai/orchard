defmodule Orchard.Node.WorkerProcess do
  @moduledoc """
  Per-model runtime owner that talks to the configured runtime adapter.
  """

  use GenServer

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.InferenceEvent
  alias Orchard.Node.RuntimeAdapter

  @type state :: %{
          adapter: module(),
          adapter_state: term(),
          loaded?: boolean(),
          manager: pid(),
          model_ref: ModelRef.t(),
          requests: %{optional(String.t()) => %{generation_ref: reference(), subscriber: pid()}}
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec ensure_loaded(pid(), EnsureModelLoadedRequest.t()) ::
          :loaded | :already_loaded | {:error, term()}
  def ensure_loaded(pid, %EnsureModelLoadedRequest{} = request) do
    GenServer.call(pid, {:ensure_loaded, request})
  end

  @spec unload(pid(), keyword()) :: :ok | {:error, term()}
  def unload(pid, opts \\ []) do
    GenServer.call(pid, {:unload, opts})
  end

  @spec start_request(pid(), String.t(), ExecuteInferenceRequest.t(), keyword()) ::
          :ok | {:error, term()}
  def start_request(pid, request_id, %ExecuteInferenceRequest{} = request, opts) do
    GenServer.call(pid, {:start_request, request_id, request, opts})
  end

  @spec cancel_request(pid(), String.t()) :: :ok | {:error, term()}
  def cancel_request(pid, request_id) when is_binary(request_id) do
    GenServer.call(pid, {:cancel_request, request_id})
  end

  @impl true
  def init(opts) do
    model_ref = Keyword.fetch!(opts, :model_ref)
    manager = Keyword.fetch!(opts, :manager)

    {:ok,
     %{
       adapter: RuntimeAdapter.impl(),
       adapter_state: nil,
       loaded?: false,
       manager: manager,
       model_ref: model_ref,
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:ensure_loaded, %EnsureModelLoadedRequest{}}, _from, %{loaded?: true} = state) do
    {:reply, :already_loaded, state}
  end

  def handle_call({:ensure_loaded, %EnsureModelLoadedRequest{}}, _from, state) do
    case state.adapter.load_model(state.model_ref, owner: self()) do
      {:ok, adapter_state} ->
        {:reply, :loaded, %{state | loaded?: true, adapter_state: adapter_state}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unload, opts}, _from, state) do
    force? = Keyword.get(opts, :force, false)

    if map_size(state.requests) > 0 and not force? do
      {:reply, {:error, :active_requests}, state}
    else
      state = maybe_cancel_requests(state, force?)

      case state.adapter.unload_model(state.adapter_state, opts) do
        :ok ->
          {:reply, :ok, %{state | adapter_state: nil, loaded?: false, requests: %{}}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(
        {:start_request, request_id, %ExecuteInferenceRequest{} = request, opts},
        _from,
        state
      ) do
    subscriber = Keyword.fetch!(opts, :subscriber)

    cond do
      not state.loaded? ->
        {:reply, {:error, :model_not_loaded}, state}

      Map.has_key?(state.requests, request_id) ->
        {:reply, {:error, :already_running}, state}

      map_size(state.requests) > 0 ->
        {:reply, {:error, :model_busy}, state}

      true ->
        start_generation(request_id, request, subscriber, state)
    end
  end

  def handle_call({:cancel_request, request_id}, _from, state) do
    case Map.fetch(state.requests, request_id) do
      :error ->
        {:reply, :ok, state}

      {:ok, %{generation_ref: generation_ref}} ->
        case state.adapter.cancel_generation(state.adapter_state, generation_ref,
               request_id: request_id
             ) do
          {:ok, adapter_state} ->
            {:reply, :ok, %{state | adapter_state: adapter_state}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({:runtime_adapter_event, generation_ref, %InferenceEvent{} = event}, state) do
    case fetch_request_by_generation_ref(state.requests, generation_ref) do
      {:ok, {request_id, %{subscriber: subscriber}}} ->
        send(subscriber, {:node_runtime_event, request_id, event})

        if InferenceEvent.terminal?(event) do
          next_state = finish_generation(state, request_id, generation_ref)
          notify_request_finished(next_state.manager, request_id)
          {:noreply, next_state}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:runtime_adapter_done, generation_ref}, state) do
    case fetch_request_by_generation_ref(state.requests, generation_ref) do
      {:ok, {request_id, %{subscriber: subscriber}}} ->
        failed_event =
          InferenceEvent.failed(
            "runtime_stream_ended",
            "runtime stream ended without terminal event",
            false
          )

        send(subscriber, {:node_runtime_event, request_id, failed_event})
        next_state = finish_generation(state, request_id, generation_ref)
        notify_request_finished(next_state.manager, request_id)
        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, _data}}, %{adapter_state: %{port: port}} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{adapter_state: %{port: port}} = state) do
    {:stop, :runtime_worker_exited, state}
  end

  def handle_info({port, {:data, _data}}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info({:gun_down, _conn_pid, _protocol, _reason, _streams}, state) do
    {:stop, :runtime_worker_exited, state}
  end

  @impl true
  def terminate(reason, %{adapter: adapter, adapter_state: adapter_state}) do
    if is_nil(adapter_state) do
      :ok
    else
      # When the worker has already exited, skip the unload RPC to avoid a
      # wasted timeout against a dead process.  Local cleanup (kill tasks,
      # disconnect channel, remove socket) still runs inside the adapter.
      opts = [force: true, skip_rpc: reason == :runtime_worker_exited]
      _ = adapter.unload_model(adapter_state, opts)
      :ok
    end
  end

  defp start_generation(request_id, request, subscriber, state) do
    case state.adapter.start_generation(state.adapter_state, request,
           owner: self(),
           request_id: request_id
         ) do
      {:ok, generation_ref, adapter_state} ->
        requests =
          Map.put(state.requests, request_id, %{
            generation_ref: generation_ref,
            subscriber: subscriber
          })

        {:reply, :ok, %{state | adapter_state: adapter_state, requests: requests}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp finish_generation(state, request_id, generation_ref) do
    adapter_state =
      state.adapter.finish_generation(
        state.adapter_state,
        generation_ref,
        request_id: request_id
      )

    %{state | adapter_state: adapter_state, requests: Map.delete(state.requests, request_id)}
  end

  defp maybe_cancel_requests(state, false), do: state

  defp maybe_cancel_requests(state, true) do
    adapter_state =
      Enum.reduce(state.requests, state.adapter_state, fn {request_id, request_state},
                                                          adapter_state ->
        case state.adapter.cancel_generation(adapter_state, request_state.generation_ref,
               request_id: request_id
             ) do
          {:ok, next_adapter_state} ->
            next_adapter_state

          {:error, _reason} ->
            adapter_state
        end
      end)

    %{state | adapter_state: adapter_state}
  end

  defp fetch_request_by_generation_ref(requests, generation_ref) do
    Enum.find_value(requests, :error, fn {request_id, request_state} ->
      if request_state.generation_ref == generation_ref do
        {:ok, {request_id, request_state}}
      end
    end)
  end

  defp notify_request_finished(manager, request_id) do
    send(manager, {:worker_request_finished, self(), request_id})
  end
end
