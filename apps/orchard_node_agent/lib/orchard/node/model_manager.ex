defmodule Orchard.Node.ModelManager do
  @moduledoc """
  Source of truth for loaded model workers and active runtime requests.

  Ensure-load requests run as async supervised tasks with single-flight
  dedup: concurrent callers for the same `{model_id, version}` share one
  acquisition + worker-load pipeline and all receive the same reply.
  """

  use GenServer

  require Logger

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Node
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request, as: AcquisitionRequest
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

  @type inflight_load :: %{
          request_fingerprint: {String.t(), String.t() | nil},
          leader_deadline_unix_ms: non_neg_integer(),
          started_monotonic_ms: integer(),
          source_scheme: String.t() | nil,
          preload: boolean(),
          backend: String.t(),
          task_pid: pid(),
          task_ref: reference(),
          waiters: [GenServer.from()],
          worker_pid: pid() | nil
        }

  @type state :: %{
          active_requests: %{optional(String.t()) => active_request()},
          inflight_loads: %{optional({String.t(), String.t()}) => inflight_load()},
          load_refs: %{optional(reference()) => {String.t(), String.t()}},
          subscriber_refs: %{optional(reference()) => String.t()},
          worker_refs: %{optional(reference()) => {String.t(), String.t()}},
          workers: %{optional({String.t(), String.t()}) => worker_entry()}
        }

  @task_supervisor Orchard.Node.ModelLoadTaskSupervisor

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec current() :: StatusResponse.t()
  def current, do: GenServer.call(__MODULE__, :current)

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t()) :: EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request) do
    GenServer.call(__MODULE__, {:ensure_model_loaded, request}, call_timeout_for(request))
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

  # -- handle_call -----------------------------------------------------------

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, status_response(state), state}
  end

  def handle_call(:reset, _from, state) do
    # Cancel all inflight acquisition tasks and reply waiters
    state = cancel_all_inflight_loads(state, :reset)

    # Terminate all loaded workers
    Enum.each(state.workers, fn {_key, entry} ->
      _ = DynamicSupervisor.terminate_child(WorkerSupervisor, entry.pid)
    end)

    {:reply, :ok, initial_state()}
  end

  def handle_call({:ensure_model_loaded, %EnsureModelLoadedRequest{} = request}, from, state) do
    key = model_key(request.model_id, request.version)

    cond do
      # Already loaded — fast path
      match?(%{placement_state: :PLACEMENT_STATE_LOADED}, Map.get(state.workers, key)) ->
        {:reply,
         %EnsureModelLoadedResponse{
           already_loaded: true,
           placement_state: :PLACEMENT_STATE_LOADED
         }, state}

      # Inflight load exists — join or reject
      Map.has_key?(state.inflight_loads, key) ->
        handle_inflight_join(key, request, from, state)

      # No worker, no inflight — start new acquisition task
      true ->
        start_load_task(key, request, from, state)
    end
  end

  def handle_call({:unload_model, %UnloadModelRequest{} = request}, _from, state) do
    key = model_key(request.model_id, request.version)

    cond do
      # Cancel inflight load if one exists for this key
      Map.has_key?(state.inflight_loads, key) ->
        next_state = cancel_inflight_load(state, key, :unload_request)
        {:reply, %Ack{ok: true, message: "unload accepted"}, next_state}

      # Loaded worker exists — unload it
      Map.has_key?(state.workers, key) ->
        %{pid: pid, monitor_ref: monitor_ref} = Map.fetch!(state.workers, key)
        active_request_count = active_request_count_for_model(state.active_requests, key)

        if active_request_count > 0 and not request.force do
          {:reply, %Ack{ok: false, message: "model has active requests"}, state}
        else
          {reply, next_state} = perform_unload(pid, key, monitor_ref, request, state)
          {:reply, reply, next_state}
        end

      # Nothing to unload
      true ->
        {:reply, %Ack{ok: true, message: "model already absent"}, state}
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

  # -- handle_info -----------------------------------------------------------

  @impl true
  def handle_info({:model_load_worker_started, key, task_pid, worker_pid}, state) do
    case Map.get(state.inflight_loads, key) do
      %{task_pid: ^task_pid} = inflight ->
        # Track the worker so we can clean it up on cancel/failure
        model_ref = %ModelRef{model_id: elem(key, 0), version: elem(key, 1)}
        monitor_ref = Process.monitor(worker_pid)
        state = put_worker(state, key, model_ref, worker_pid, monitor_ref)
        inflight = %{inflight | worker_pid: worker_pid}
        {:noreply, %{state | inflight_loads: Map.put(state.inflight_loads, key, inflight)}}

      _stale_or_missing ->
        # Inflight was cancelled; terminate the orphaned worker
        _ = DynamicSupervisor.terminate_child(WorkerSupervisor, worker_pid)
        {:noreply, state}
    end
  end

  def handle_info({:model_load_finished, key, task_pid, result}, state) do
    case Map.get(state.inflight_loads, key) do
      %{task_pid: ^task_pid} = inflight ->
        next_state = complete_inflight_load(state, key, inflight, result)
        {:noreply, next_state}

      _stale_or_missing ->
        # Late message after cancel — ignore
        {:noreply, state}
    end
  end

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

  # Task.Supervisor.async_nolink sends {ref, return_value} on task completion.
  # We handle results via the explicit :model_load_finished message sent from
  # within the task, so this just acknowledges and flushes the monitor.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    cond do
      # Load task crashed
      Map.has_key?(state.load_refs, monitor_ref) ->
        key = Map.fetch!(state.load_refs, monitor_ref)

        case Map.get(state.inflight_loads, key) do
          %{task_pid: ^pid} = inflight ->
            next_state = complete_inflight_load(state, key, inflight, {:error, :task_crashed})
            {:noreply, next_state}

          _stale ->
            # Already cleaned up; just drop the ref
            {:noreply, %{state | load_refs: Map.delete(state.load_refs, monitor_ref)}}
        end

      # Worker process died
      Map.has_key?(state.worker_refs, monitor_ref) ->
        key = Map.fetch!(state.worker_refs, monitor_ref)

        next_state =
          cleanup_worker_unavailable(drop_worker(state, key, monitor_ref), key, :worker_down)

        {:noreply, next_state}

      # Subscriber (request consumer) died
      Map.has_key?(state.subscriber_refs, monitor_ref) ->
        request_id = Map.fetch!(state.subscriber_refs, monitor_ref)

        next_state =
          state |> drop_subscriber_ref(monitor_ref) |> maybe_cancel_orphaned_request(request_id)

        {:noreply, next_state}

      true ->
        {:noreply, state}
    end
  end

  # -- Async load pipeline ---------------------------------------------------

  defp handle_inflight_join(key, request, from, state) do
    inflight = Map.fetch!(state.inflight_loads, key)
    fingerprint = request_fingerprint(request)

    if inflight.request_fingerprint == fingerprint do
      # Same request — add as waiter
      inflight = %{inflight | waiters: inflight.waiters ++ [from]}
      {:noreply, %{state | inflight_loads: Map.put(state.inflight_loads, key, inflight)}}
    else
      # Conflicting request — reject immediately
      {:reply, failed_load_response(:conflicting_request), state}
    end
  end

  defp start_load_task(key, request, from, state) do
    manager = self()
    models_root = Node.models_root()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        run_load_pipeline(key, request, models_root, manager)
      end)

    backend = Node.worker_backend()
    source_scheme = extract_source_scheme(request.artifact_source_uri)
    preload = request.preload || false

    inflight = %{
      request_fingerprint: request_fingerprint(request),
      leader_deadline_unix_ms: request.deadline_unix_ms || 0,
      started_monotonic_ms: System.monotonic_time(:millisecond),
      source_scheme: source_scheme,
      preload: preload,
      backend: backend,
      task_pid: task.pid,
      task_ref: task.ref,
      waiters: [from],
      worker_pid: nil
    }

    emit_load_start(key, inflight)

    next_state = %{
      state
      | inflight_loads: Map.put(state.inflight_loads, key, inflight),
        load_refs: Map.put(state.load_refs, task.ref, key)
    }

    {:noreply, next_state}
  end

  defp run_load_pipeline(key, request, models_root, manager) do
    result =
      case AcquisitionRequest.from_proto(request, models_root) do
        {:ok, acq_request} ->
          case ModelAcquisition.ensure_cached(acq_request) do
            {:ok, _path, _outcome} ->
              remaining_ms = remaining_budget_ms(request)

              if remaining_ms <= 0 do
                {:error, :deadline_exceeded}
              else
                start_and_load_worker(key, request, remaining_ms, manager)
              end

            {:error, _} = err ->
              err
          end

        {:error, _} = err ->
          err
      end

    send(manager, {:model_load_finished, key, self(), result})
  end

  defp start_and_load_worker(key, request, remaining_ms, manager) do
    model_ref = %ModelRef{model_id: elem(key, 0), version: elem(key, 1)}

    case WorkerSupervisor.start_worker(model_ref, manager: manager) do
      {:ok, worker_pid} ->
        send(manager, {:model_load_worker_started, key, self(), worker_pid})

        case safe_ensure_loaded(worker_pid, request, remaining_ms) do
          :loaded -> {:ok, worker_pid}
          :already_loaded -> {:ok, worker_pid}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp complete_inflight_load(state, key, inflight, result) do
    # Clean up inflight tracking
    state = %{
      state
      | inflight_loads: Map.delete(state.inflight_loads, key),
        load_refs: Map.delete(state.load_refs, inflight.task_ref)
    }

    Process.demonitor(inflight.task_ref, [:flush])

    case result do
      {:ok, _worker_pid} ->
        # Mark worker as LOADED and reply all waiters success
        state =
          if Map.has_key?(state.workers, key) do
            put_worker_state(state, key, :PLACEMENT_STATE_LOADED)
          else
            state
          end

        emit_load_stop(key, inflight, %{
          outcome: :loaded,
          waiter_count: length(inflight.waiters),
          worker_started: inflight.worker_pid != nil
        })

        reply_all_waiters(inflight.waiters, %EnsureModelLoadedResponse{
          already_loaded: false,
          placement_state: :PLACEMENT_STATE_LOADED
        })

        state

      {:error, reason} ->
        # Clean up partial worker if one was started
        state = cleanup_failed_worker(state, key)

        emit_load_exception(key, inflight, %{
          waiter_count: length(inflight.waiters),
          worker_started: inflight.worker_pid != nil,
          reason: reason
        })

        reply_all_waiters(inflight.waiters, failed_load_response(:acquisition_failed))

        state
    end
  end

  defp reply_all_waiters(waiters, reply) do
    Enum.each(waiters, fn from ->
      GenServer.reply(from, reply)
    end)
  end

  # -- Inflight cancellation -------------------------------------------------

  defp cancel_inflight_load(state, key, cancel_reason) do
    case Map.get(state.inflight_loads, key) do
      nil ->
        state

      inflight ->
        # Shut down the task
        Task.Supervisor.terminate_child(@task_supervisor, inflight.task_pid)
        Process.demonitor(inflight.task_ref, [:flush])

        # Drain any pending worker-started message the task may have sent
        # before being killed — prevents orphaned workers under WorkerSupervisor.
        {state, worker_drained?} = drain_pending_worker_started(state, key, inflight.task_pid)

        emit_load_stop(key, inflight, %{
          outcome: :cancelled,
          waiter_count: length(inflight.waiters),
          worker_started: inflight.worker_pid != nil or worker_drained?,
          cancel_reason: cancel_reason
        })

        # Reply all blocked waiters with failure
        reply_all_waiters(inflight.waiters, failed_load_response(:load_cancelled))

        # Clean up partial worker if started
        state = %{
          state
          | inflight_loads: Map.delete(state.inflight_loads, key),
            load_refs: Map.delete(state.load_refs, inflight.task_ref)
        }

        cleanup_failed_worker(state, key)
    end
  end

  defp drain_pending_worker_started(state, key, task_pid) do
    receive do
      {:model_load_worker_started, ^key, ^task_pid, worker_pid} ->
        # Worker was spawned but task was killed before manager processed the
        # notification. Register and immediately clean up to avoid orphaning.
        model_ref = %ModelRef{model_id: elem(key, 0), version: elem(key, 1)}
        monitor_ref = Process.monitor(worker_pid)
        state = put_worker(state, key, model_ref, worker_pid, monitor_ref)
        {state, true}
    after
      0 -> {state, false}
    end
  end

  defp cancel_all_inflight_loads(state, cancel_reason) do
    Enum.reduce(Map.keys(state.inflight_loads), state, fn key, acc ->
      cancel_inflight_load(acc, key, cancel_reason)
    end)
  end

  # -- Worker load helpers ---------------------------------------------------

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

  # -- State helpers ---------------------------------------------------------

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
    Process.demonitor(monitor_ref, [:flush])

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

  # -- Worker RPC wrappers ---------------------------------------------------

  defp safe_ensure_loaded(pid, request, remaining_ms) do
    safe_worker_call(fn ->
      WorkerProcess.ensure_loaded(pid, request,
        call_timeout: remaining_ms + 5_000,
        load_timeout_ms: remaining_ms
      )
    end)
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

  # -- Query helpers ---------------------------------------------------------

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

  # -- Response helpers ------------------------------------------------------

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

      map_size(state.inflight_loads) > 0 ->
        :WORKER_STATE_STARTING

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

  # -- Internal helpers ------------------------------------------------------

  defp model_key(model_id, version), do: {model_id, version}

  defp request_fingerprint(%EnsureModelLoadedRequest{} = request) do
    {request.artifact_sha256, request.artifact_source_uri}
  end

  defp remaining_budget_ms(%EnsureModelLoadedRequest{deadline_unix_ms: deadline})
       when is_integer(deadline) and deadline > 0 do
    max(deadline - System.system_time(:millisecond), 0)
  end

  defp remaining_budget_ms(_request), do: Node.worker_load_timeout_ms()

  defp call_timeout_for(%EnsureModelLoadedRequest{deadline_unix_ms: deadline})
       when is_integer(deadline) and deadline > 0 do
    remaining = deadline - System.system_time(:millisecond)

    if remaining > 0 do
      remaining + 10_000
    else
      Node.worker_load_timeout_ms() + 10_000
    end
  end

  defp call_timeout_for(_request), do: Node.worker_load_timeout_ms() + 10_000

  defp initial_state do
    %{
      workers: %{},
      worker_refs: %{},
      active_requests: %{},
      subscriber_refs: %{},
      inflight_loads: %{},
      load_refs: %{}
    }
  end

  # -- Telemetry helpers -----------------------------------------------------

  defp emit_load_start(key, inflight) do
    {model_id, version} = key

    :telemetry.execute(
      [:orchard, :node, :model_manager, :load, :start],
      %{system_time: System.system_time()},
      %{
        model_id: model_id,
        version: version,
        source_scheme: inflight.source_scheme,
        preload: inflight.preload,
        backend: inflight.backend
      }
    )
  end

  defp emit_load_stop(key, inflight, extra) do
    {model_id, version} = key

    :telemetry.execute(
      [:orchard, :node, :model_manager, :load, :stop],
      %{duration_ms: load_duration_ms(inflight)},
      Map.merge(
        %{
          model_id: model_id,
          version: version,
          source_scheme: inflight.source_scheme,
          preload: inflight.preload,
          backend: inflight.backend
        },
        extra
      )
    )
  end

  defp emit_load_exception(key, inflight, extra) do
    {model_id, version} = key

    :telemetry.execute(
      [:orchard, :node, :model_manager, :load, :exception],
      %{duration_ms: load_duration_ms(inflight)},
      Map.merge(
        %{
          model_id: model_id,
          version: version,
          source_scheme: inflight.source_scheme,
          preload: inflight.preload,
          backend: inflight.backend
        },
        extra
      )
    )
  end

  defp load_duration_ms(inflight) do
    System.monotonic_time(:millisecond) - inflight.started_monotonic_ms
  end

  defp extract_source_scheme(nil), do: nil
  defp extract_source_scheme(""), do: nil

  defp extract_source_scheme(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" -> scheme
      _ -> nil
    end
  end
end
