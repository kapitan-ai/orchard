defmodule Orchard.Node.ModelManager do
  @moduledoc """
  Source of truth for loaded model workers and active runtime requests.
  """

  use GenServer

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Node.WorkerProcess
  alias Orchard.Node.WorkerSupervisor

  @type worker_entry :: %{
          model_ref: ModelRef.t(),
          monitor_ref: reference(),
          pid: pid(),
          placement_state: atom()
        }

  @type request_phase :: :prepared | :running

  @type active_request :: %{
          controller_session_id: String.t() | nil,
          model_key: {String.t(), String.t()},
          phase: request_phase(),
          pid: pid(),
          subscriber: pid(),
          subscriber_monitor_ref: reference()
        }

  @type state :: %{
          active_requests: %{optional(String.t()) => active_request()},
          subscriber_refs: %{optional(reference()) => String.t()},
          worker_refs: %{optional(reference()) => {String.t(), String.t()}},
          workers: %{optional({String.t(), String.t()}) => worker_entry()}
        }

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec current() :: StatusResponse.t()
  def current, do: GenServer.call(__MODULE__, :current)

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t()) :: EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request) do
    GenServer.call(__MODULE__, {:ensure_model_loaded, request})
  end

  @spec unload_model(UnloadModelRequest.t()) :: Ack.t()
  def unload_model(%UnloadModelRequest{} = request) do
    GenServer.call(__MODULE__, {:unload_model, request})
  end

  @spec prepare_request(ExecuteInferenceRequest.t(), pid()) :: :ok | {:error, term()}
  def prepare_request(%ExecuteInferenceRequest{} = request, subscriber) when is_pid(subscriber) do
    GenServer.call(__MODULE__, {:prepare_request, request, subscriber})
  end

  @spec start_request(ExecuteInferenceRequest.t()) :: :ok | {:error, term()}
  def start_request(%ExecuteInferenceRequest{} = request) do
    GenServer.call(__MODULE__, {:start_request, request})
  end

  @spec cancel_request(String.t(), String.t() | nil) :: Ack.t()
  def cancel_request(request_id, controller_session_id \\ nil) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:cancel_request, request_id, controller_session_id})
  end

  @impl true
  def init(_init_arg) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, status_response(state), state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.workers, fn {_key, entry} ->
      _ = DynamicSupervisor.terminate_child(WorkerSupervisor, entry.pid)
    end)

    {:reply, :ok, initial_state()}
  end

  def handle_call({:ensure_model_loaded, %EnsureModelLoadedRequest{} = request}, _from, state) do
    key = model_key(request.model_id, request.version)

    case Map.get(state.workers, key) do
      %{placement_state: :PLACEMENT_STATE_LOADED} ->
        {:reply,
         %EnsureModelLoadedResponse{
           already_loaded: true,
           placement_state: :PLACEMENT_STATE_LOADED
         }, state}

      nil ->
        {reply, next_state} = load_new_worker(request, key, state)
        {:reply, reply, next_state}

      %{pid: pid} ->
        {reply, next_state} = ensure_existing_worker_loaded(request, key, pid, state)
        {:reply, reply, next_state}
    end
  end

  def handle_call({:unload_model, %UnloadModelRequest{} = request}, _from, state) do
    key = model_key(request.model_id, request.version)

    case Map.get(state.workers, key) do
      nil ->
        {:reply, %Ack{ok: true, message: "model already absent"}, state}

      %{pid: pid, monitor_ref: monitor_ref} ->
        active_request_count = active_request_count_for_model(state.active_requests, key)

        if active_request_count > 0 and not request.force do
          {:reply, %Ack{ok: false, message: "model has active requests"}, state}
        else
          {reply, next_state} = perform_unload(pid, key, monitor_ref, request, state)
          {:reply, reply, next_state}
        end
    end
  end

  def handle_call(
        {:prepare_request, %ExecuteInferenceRequest{} = request, subscriber},
        _from,
        state
      ) do
    key = model_key(request.model_id, request.version)

    if Map.has_key?(state.active_requests, request.request_id) do
      {:reply, {:error, :request_already_active}, state}
    else
      case Map.get(state.workers, key) do
        %{placement_state: :PLACEMENT_STATE_LOADED, pid: pid} ->
          if model_has_active_request?(state.active_requests, key) do
            {:reply, {:error, :model_busy}, state}
          else
            subscriber_monitor_ref = Process.monitor(subscriber)

            active_requests =
              Map.put(state.active_requests, request.request_id, %{
                controller_session_id: request.controller_session_id,
                model_key: key,
                phase: :prepared,
                pid: pid,
                subscriber: subscriber,
                subscriber_monitor_ref: subscriber_monitor_ref
              })

            subscriber_refs =
              Map.put(state.subscriber_refs, subscriber_monitor_ref, request.request_id)

            next_state = %{
              state
              | active_requests: active_requests,
                subscriber_refs: subscriber_refs
            }

            {:reply, :ok, next_state}
          end

        _other ->
          {:reply, {:error, :model_not_loaded}, state}
      end
    end
  end

  def handle_call({:start_request, %ExecuteInferenceRequest{} = request}, _from, state) do
    case Map.fetch(state.active_requests, request.request_id) do
      :error ->
        {:reply, {:error, :request_not_prepared}, state}

      {:ok, %{pid: pid, subscriber: subscriber} = active_request} ->
        case safe_start_request(pid, request.request_id, request, subscriber) do
          :ok ->
            next_state = put_request_phase(state, request.request_id, :running)
            {:reply, :ok, next_state}

          {:error, :worker_unavailable} ->
            next_state =
              cleanup_worker_unavailable(state, active_request.model_key, :worker_unavailable)

            {:reply, {:error, :worker_unavailable}, next_state}

          {:error, reason} ->
            next_state = remove_request_from_state(state, request.request_id, active_request)
            {:reply, {:error, reason}, next_state}
        end
    end
  end

  def handle_call({:cancel_request, request_id, _controller_session_id}, _from, state) do
    # M1 intentionally accepts controller_session_id without validating session-currentness.
    # The node agent has no authoritative session registry yet, so cancellation remains
    # keyed by request_id while we preserve the field for later §7.5.6 enforcement.
    case Map.fetch(state.active_requests, request_id) do
      :error ->
        {:reply, %Ack{ok: true, message: "cancel accepted"}, state}

      {:ok, %{phase: :prepared} = active_request} ->
        next_state = remove_request_from_state(state, request_id, active_request)
        {:reply, %Ack{ok: true, message: "cancel accepted"}, next_state}

      {:ok, %{phase: :running, pid: pid, model_key: model_key}} ->
        case safe_cancel_request(pid, request_id) do
          :ok ->
            {:reply, %Ack{ok: true, message: "cancel accepted"}, state}

          {:error, :worker_unavailable} ->
            next_state = cleanup_worker_unavailable(state, model_key, :worker_unavailable)
            {:reply, %Ack{ok: true, message: "cancel accepted"}, next_state}

          {:error, reason} ->
            {:reply, %Ack{ok: false, message: "cancel failed: #{inspect(reason)}"}, state}
        end
    end
  end

  @impl true
  def handle_info({:worker_request_finished, worker_pid, request_id}, state) do
    case Map.fetch(state.active_requests, request_id) do
      {:ok, %{pid: ^worker_pid} = active_request} ->
        {active_requests, subscriber_refs} =
          remove_active_request(
            state.active_requests,
            state.subscriber_refs,
            request_id,
            active_request
          )

        {:noreply, %{state | active_requests: active_requests, subscriber_refs: subscriber_refs}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.worker_refs, monitor_ref) ->
        key = Map.fetch!(state.worker_refs, monitor_ref)

        next_state =
          cleanup_worker_unavailable(drop_worker(state, key, monitor_ref), key, :worker_down)

        {:noreply, next_state}

      Map.has_key?(state.subscriber_refs, monitor_ref) ->
        request_id = Map.fetch!(state.subscriber_refs, monitor_ref)

        next_state =
          state |> drop_subscriber_ref(monitor_ref) |> maybe_cancel_orphaned_request(request_id)

        {:noreply, next_state}

      true ->
        {:noreply, state}
    end
  end

  defp load_new_worker(request, key, state) do
    model_ref = %ModelRef{model_id: request.model_id, version: request.version}

    case WorkerSupervisor.start_worker(model_ref, manager: self()) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)
        state = put_worker(state, key, model_ref, pid, monitor_ref)
        finalize_worker_load(state, key, pid, request)

      {:error, reason} ->
        reply = failed_load_response(reason)
        {reply, state}
    end
  end

  defp ensure_existing_worker_loaded(request, key, pid, state) do
    finalize_worker_load(state, key, pid, request)
  end

  defp finalize_worker_load(state, key, pid, request) do
    case safe_ensure_loaded(pid, request) do
      :loaded ->
        reply = %EnsureModelLoadedResponse{
          already_loaded: false,
          placement_state: :PLACEMENT_STATE_LOADED
        }

        {reply, put_worker_state(state, key, :PLACEMENT_STATE_LOADED)}

      :already_loaded ->
        reply = %EnsureModelLoadedResponse{
          already_loaded: true,
          placement_state: :PLACEMENT_STATE_LOADED
        }

        {reply, put_worker_state(state, key, :PLACEMENT_STATE_LOADED)}

      {:error, :worker_unavailable} ->
        reply = failed_load_response(:worker_unavailable)
        {reply, cleanup_worker_unavailable(state, key, :worker_unavailable)}

      {:error, reason} ->
        reply = failed_load_response(reason)
        {reply, cleanup_failed_worker(state, key)}
    end
  end

  defp perform_unload(pid, key, monitor_ref, request, state) do
    case safe_unload(pid, force: request.force, evict: request.evict) do
      :ok ->
        _ = DynamicSupervisor.terminate_child(WorkerSupervisor, pid)

        next_state =
          state
          |> drop_worker(key, monitor_ref)
          |> maybe_cleanup_unloaded_requests(key, request.force)

        {%Ack{ok: true, message: "unload accepted"}, next_state}

      {:error, :worker_unavailable} ->
        next_state =
          cleanup_worker_unavailable(
            drop_worker(state, key, monitor_ref),
            key,
            :worker_unavailable
          )

        {%Ack{ok: true, message: "unload accepted"}, next_state}

      {:error, reason} ->
        {%Ack{ok: false, message: "unload failed: #{inspect(reason)}"}, state}
    end
  end

  defp maybe_cancel_orphaned_request(state, request_id) do
    case Map.fetch(state.active_requests, request_id) do
      {:ok, %{phase: :prepared} = active_request} ->
        remove_request_from_state(state, request_id, active_request)

      {:ok, %{phase: :running, pid: pid, model_key: model_key}} ->
        case safe_cancel_request(pid, request_id) do
          :ok ->
            state

          {:error, :worker_unavailable} ->
            cleanup_worker_unavailable(state, model_key, :worker_unavailable)

          {:error, _reason} ->
            state
        end

      :error ->
        state
    end
  end

  defp cleanup_failed_worker(state, key) do
    case Map.get(state.workers, key) do
      nil ->
        state

      %{pid: pid, monitor_ref: monitor_ref} ->
        _ = DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
        drop_worker(state, key, monitor_ref)
    end
  end

  defp put_worker(state, key, model_ref, pid, monitor_ref) do
    entry = %{
      model_ref: model_ref,
      monitor_ref: monitor_ref,
      pid: pid,
      placement_state: :PLACEMENT_STATE_LOADING
    }

    %{
      state
      | workers: Map.put(state.workers, key, entry),
        worker_refs: Map.put(state.worker_refs, monitor_ref, key)
    }
  end

  defp put_worker_state(state, key, placement_state) do
    update_in(state, [:workers, key, :placement_state], fn _current -> placement_state end)
  end

  defp drop_worker(state, key, monitor_ref) do
    %{
      state
      | workers: Map.delete(state.workers, key),
        worker_refs: Map.delete(state.worker_refs, monitor_ref)
    }
  end

  defp drop_subscriber_ref(state, monitor_ref) do
    %{state | subscriber_refs: Map.delete(state.subscriber_refs, monitor_ref)}
  end

  defp put_request_phase(state, request_id, phase) do
    put_in(state, [:active_requests, request_id, :phase], phase)
  end

  defp remove_request_from_state(state, request_id, active_request) do
    {active_requests, subscriber_refs} =
      remove_active_request(
        state.active_requests,
        state.subscriber_refs,
        request_id,
        active_request
      )

    %{state | active_requests: active_requests, subscriber_refs: subscriber_refs}
  end

  defp maybe_cleanup_unloaded_requests(state, key, true) do
    cleanup_requests_for_model(state, key, :worker_force_unloaded)
  end

  defp maybe_cleanup_unloaded_requests(state, _key, false), do: state

  defp cleanup_worker_unavailable(state, key, reason) do
    cleanup_requests_for_model(state, key, reason)
  end

  defp cleanup_requests_for_model(state, key, reason) do
    Enum.reduce(state.active_requests, state, fn {request_id, active_request}, acc ->
      if active_request.model_key == key do
        maybe_notify_running_request_failed(active_request, request_id, reason)
        remove_request_from_state(acc, request_id, active_request)
      else
        acc
      end
    end)
  end

  defp maybe_notify_running_request_failed(%{phase: :prepared}, _request_id, _reason), do: :ok

  defp maybe_notify_running_request_failed(
         %{phase: :running, subscriber: subscriber},
         request_id,
         reason
       ) do
    send(
      subscriber,
      {:node_runtime_event, request_id, request_failed_event(reason)}
    )
  end

  defp remove_active_request(active_requests, subscriber_refs, request_id, active_request) do
    Process.demonitor(active_request.subscriber_monitor_ref, [:flush])

    {
      Map.delete(active_requests, request_id),
      Map.delete(subscriber_refs, active_request.subscriber_monitor_ref)
    }
  end

  defp request_failed_event(:worker_down) do
    Orchard.InferenceEvent.failed("worker_down", "worker process exited unexpectedly", false)
  end

  defp request_failed_event(:worker_force_unloaded) do
    Orchard.InferenceEvent.failed(
      "worker_unloaded",
      "worker force unload interrupted request",
      false
    )
  end

  defp request_failed_event(:worker_unavailable) do
    Orchard.InferenceEvent.failed(
      "worker_unavailable",
      "worker process became unavailable",
      false
    )
  end

  defp safe_ensure_loaded(pid, request) do
    safe_worker_call(fn -> WorkerProcess.ensure_loaded(pid, request) end)
  end

  defp safe_start_request(pid, request_id, request, subscriber) do
    safe_worker_call(fn ->
      WorkerProcess.start_request(pid, request_id, request, subscriber: subscriber)
    end)
  end

  defp safe_cancel_request(pid, request_id) do
    safe_worker_call(fn -> WorkerProcess.cancel_request(pid, request_id) end)
  end

  defp safe_unload(pid, opts) do
    safe_worker_call(fn -> WorkerProcess.unload(pid, opts) end)
  end

  defp safe_worker_call(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  defp active_request_count_for_model(active_requests, key) do
    Enum.count(active_requests, fn {_request_id, active_request} ->
      active_request.model_key == key
    end)
  end

  defp model_has_active_request?(active_requests, key) do
    Enum.any?(active_requests, fn {_request_id, active_request} ->
      active_request.model_key == key
    end)
  end

  defp failed_load_response(_reason) do
    %EnsureModelLoadedResponse{already_loaded: false, placement_state: :PLACEMENT_STATE_FAILED}
  end

  defp status_response(state) do
    %StatusResponse{
      worker_state: worker_state(state),
      loaded_models: loaded_models(state),
      active_request_count: map_size(state.active_requests)
    }
  end

  defp worker_state(state) do
    cond do
      map_size(state.active_requests) > 0 ->
        :WORKER_STATE_BUSY

      Enum.any?(state.workers, fn {_key, entry} ->
        entry.placement_state == :PLACEMENT_STATE_LOADING
      end) ->
        :WORKER_STATE_STARTING

      true ->
        :WORKER_STATE_IDLE
    end
  end

  defp loaded_models(state) do
    state.workers
    |> Enum.filter(fn {_key, entry} -> entry.placement_state == :PLACEMENT_STATE_LOADED end)
    |> Enum.map(fn {_key, entry} -> entry.model_ref end)
    |> Enum.sort_by(&{&1.model_id, &1.version})
  end

  defp model_key(model_id, version), do: {model_id, version}

  defp initial_state do
    %{workers: %{}, worker_refs: %{}, active_requests: %{}, subscriber_refs: %{}}
  end
end
