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
  alias Orchard.Cluster.V1.RuntimeHealth
  alias Orchard.Cluster.V1.RuntimeNodeMetadata
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Node
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request, as: AcquisitionRequest
  alias Orchard.Node.ModelLoadFailure
  alias Orchard.Node.ToolCapabilityCatalog
  alias Orchard.Node.WorkerProcess
  alias Orchard.Node.WorkerSupervisor

  @type worker_entry :: %{
          model_ref: ModelRef.t(),
          monitor_ref: reference(),
          pid: pid(),
          placement_state: atom(),
          last_used_monotonic_ms: integer()
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

  @type inflight_waiter :: %{
          id: reference(),
          from: GenServer.from(),
          deadline_unix_ms: non_neg_integer(),
          timer_ref: reference() | nil
        }

  @type inflight_load :: %{
          request: EnsureModelLoadedRequest.t(),
          request_fingerprint: {String.t(), String.t() | nil},
          leader_waiter_id: reference(),
          started_monotonic_ms: integer(),
          source_scheme: String.t() | nil,
          preload: boolean(),
          backend: String.t(),
          task_pid: pid(),
          task_ref: reference(),
          waiters: [inflight_waiter()],
          total_waiter_count: non_neg_integer(),
          replied_waiter_count: non_neg_integer(),
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
         }, touch_worker_last_used(state, key)}

      # Inflight load exists — join or reject
      Map.has_key?(state.inflight_loads, key) ->
        handle_inflight_join(key, request, from, state)

      # No worker, no inflight — evict if needed, then start new acquisition task
      true ->
        case maybe_evict_before_load(state, key) do
          {:ok, state} ->
            start_load_task(key, request, from, state)

          {:error, reason, state} ->
            {:reply, ModelLoadFailure.to_response(reason), state}
        end
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
    handle_prepare_request(request, subscriber, state)
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

  defp handle_prepare_request(%ExecuteInferenceRequest{} = request, subscriber, state) do
    key = model_key(request.model_id, request.version)

    if Map.has_key?(state.active_requests, request.request_id) do
      {:reply, {:error, :request_already_active}, state}
    else
      prepare_request_for_worker(request, subscriber, key, state)
    end
  end

  defp prepare_request_for_worker(request, subscriber, key, state) do
    case Map.get(state.workers, key) do
      %{placement_state: :PLACEMENT_STATE_LOADED, pid: pid} ->
        prepare_loaded_request(request, subscriber, key, pid, state)

      _other ->
        {:reply, {:error, :model_not_loaded}, state}
    end
  end

  defp prepare_loaded_request(request, subscriber, key, pid, state) do
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

      next_state =
        %{
          state
          | active_requests: active_requests,
            subscriber_refs: subscriber_refs
        }
        |> touch_worker_last_used(key)

      {:reply, :ok, next_state}
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
      {:ok, %{pid: ^worker_pid, model_key: model_key} = active_request} ->
        {active_requests, subscriber_refs} =
          remove_active_request(
            state.active_requests,
            state.subscriber_refs,
            request_id,
            active_request
          )

        next_state =
          %{state | active_requests: active_requests, subscriber_refs: subscriber_refs}
          |> touch_worker_last_used(model_key)

        {:noreply, next_state}

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

  def handle_info({:inflight_waiter_timeout, key, task_ref, _waiter_id}, state) do
    case Map.get(state.inflight_loads, key) do
      %{task_ref: ^task_ref} = inflight ->
        {:noreply, handle_waiter_expiry(state, key, inflight)}

      _stale_or_missing ->
        # Stale timer from a previous attempt or cancelled inflight — ignore
        {:noreply, state}
    end
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
      now_ms = System.system_time(:millisecond)

      case build_waiter(request, from, now_ms) do
        {:error, :deadline_exceeded} ->
          # Already-expired request — reply immediately, don't join
          {:reply, ModelLoadFailure.to_response(:deadline_exceeded), state}

        {:ok, waiter} ->
          waiter = schedule_waiter_timer(waiter, key, inflight.task_ref, now_ms)

          inflight = %{
            inflight
            | waiters: inflight.waiters ++ [waiter],
              total_waiter_count: inflight.total_waiter_count + 1
          }

          {:noreply, %{state | inflight_loads: Map.put(state.inflight_loads, key, inflight)}}
      end
    else
      # Conflicting request — reject immediately
      {:reply, ModelLoadFailure.to_response(:conflicting_request), state}
    end
  end

  defp start_load_task(key, request, from, state) do
    now_ms = System.system_time(:millisecond)

    case build_waiter(request, from, now_ms) do
      {:error, :deadline_exceeded} ->
        {:reply, ModelLoadFailure.to_response(:deadline_exceeded), state}

      {:ok, waiter} ->
        manager = self()
        models_root = Node.models_root()

        task =
          Task.Supervisor.async_nolink(@task_supervisor, fn ->
            run_load_pipeline(key, request, models_root, manager)
          end)

        backend = Node.worker_backend()
        source_scheme = extract_source_scheme(request.artifact_source_uri)
        preload = request.preload || false

        waiter = schedule_waiter_timer(waiter, key, task.ref, now_ms)

        inflight = %{
          request: request,
          request_fingerprint: request_fingerprint(request),
          leader_waiter_id: waiter.id,
          started_monotonic_ms: System.monotonic_time(:millisecond),
          source_scheme: source_scheme,
          preload: preload,
          backend: backend,
          task_pid: task.pid,
          task_ref: task.ref,
          waiters: [waiter],
          total_waiter_count: 1,
          replied_waiter_count: 0,
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
  end

  defp run_load_pipeline(key, request, models_root, manager) do
    # Test observability hook: notify test process of the exact request used
    if pid = Process.whereis(:load_timeout_test_pid) do
      send(pid, {:load_pipeline_request, key, request})
    end

    result =
      with {:ok, acq_request} <- AcquisitionRequest.from_proto(request, models_root),
           {:ok, _path, _outcome} <- ModelAcquisition.ensure_cached(acq_request),
           {:ok, remaining_ms} <- remaining_load_budget(request) do
        start_and_load_worker(key, request, remaining_ms, manager)
      end

    send(manager, {:model_load_finished, key, self(), result})
  end

  defp remaining_load_budget(request) do
    case remaining_budget_ms(request) do
      remaining_ms when remaining_ms <= 0 -> {:error, :deadline_exceeded}
      remaining_ms -> {:ok, remaining_ms}
    end
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
    now_ms = System.system_time(:millisecond)
    {expired, valid} = partition_waiters(inflight.waiters, now_ms)

    # Design decision: we partition expired/valid even on {:ok, _} success.
    # Waiters whose deadline has passed at message-handling time receive
    # :deadline_exceeded even though the load succeeded. This preserves the
    # deadline contract — the caller asked for a response within N ms and
    # didn't get one. The loaded worker remains available for subsequent
    # requests from those callers via the fast path (already-loaded check).

    # Cancel all waiter timers first
    cancel_all_waiter_timers(inflight.waiters)

    case result do
      {:ok, _worker_pid} ->
        # Clean up inflight tracking
        state = remove_inflight(state, key, inflight)

        # Mark worker as LOADED and touch LRU timestamp
        state =
          if Map.has_key?(state.workers, key) do
            state
            |> put_worker_state(key, :PLACEMENT_STATE_LOADED)
            |> touch_worker_last_used(key)
          else
            state
          end

        all_replied = inflight.replied_waiter_count + length(expired) + length(valid)

        emit_load_stop(key, inflight, %{
          outcome: :loaded,
          waiter_count: inflight.total_waiter_count,
          replied_waiter_count: all_replied,
          worker_started: inflight.worker_pid != nil
        })

        # Reply expired waiters with deadline_exceeded, valid ones with success
        reply_waiters(expired, ModelLoadFailure.to_response(:deadline_exceeded))

        reply_waiters(valid, %EnsureModelLoadedResponse{
          already_loaded: false,
          placement_state: :PLACEMENT_STATE_LOADED
        })

        state

      {:error, :deadline_exceeded} ->
        if valid == [] do
          # All waiters expired — full cleanup
          state = remove_inflight(state, key, inflight)
          state = cleanup_failed_worker(state, key)

          all_replied = inflight.replied_waiter_count + length(expired)

          emit_load_exception(key, inflight, %{
            waiter_count: inflight.total_waiter_count,
            replied_waiter_count: all_replied,
            worker_started: inflight.worker_pid != nil,
            reason: :deadline_exceeded
          })

          reply_waiters(expired, ModelLoadFailure.to_response(:deadline_exceeded))
          state
        else
          # Valid followers remain — reply expired, then abort and restart
          reply_waiters(expired, ModelLoadFailure.to_response(:deadline_exceeded))

          inflight = %{
            inflight
            | replied_waiter_count: inflight.replied_waiter_count + length(expired)
          }

          state = abort_inflight_attempt(state, key, inflight, :leader_deadline_exceeded)
          restart_inflight_load(state, key, valid, inflight)
        end

      {:error, reason} ->
        # Non-deadline failure — fail everyone
        state = remove_inflight(state, key, inflight)
        state = cleanup_failed_worker(state, key)

        all_replied = inflight.replied_waiter_count + length(inflight.waiters)

        emit_load_exception(key, inflight, %{
          waiter_count: inflight.total_waiter_count,
          replied_waiter_count: all_replied,
          worker_started: inflight.worker_pid != nil,
          reason: reason
        })

        reply_waiters(expired, ModelLoadFailure.to_response(:deadline_exceeded))
        reply_waiters(valid, ModelLoadFailure.to_response(reason))
        state
    end
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, fn waiter ->
      GenServer.reply(waiter.from, reply)
    end)
  end

  # -- Waiter helpers --------------------------------------------------------

  defp handle_waiter_expiry(state, key, inflight) do
    now_ms = System.system_time(:millisecond)
    {expired, valid} = partition_waiters(inflight.waiters, now_ms)

    # Reply all expired waiters with deadline_exceeded
    reply_waiters(expired, ModelLoadFailure.to_response(:deadline_exceeded))

    # Track replies for telemetry
    inflight = %{
      inflight
      | replied_waiter_count: inflight.replied_waiter_count + length(expired)
    }

    leader_expired? = Enum.any?(expired, fn w -> w.id == inflight.leader_waiter_id end)

    cond do
      valid == [] ->
        # No remaining waiters — abort the attempt entirely (abort includes cleanup)
        abort_inflight_attempt(state, key, inflight, :all_waiters_expired)

      leader_expired? ->
        # Leader expired — restart with valid followers
        cancel_all_waiter_timers(valid)
        state = abort_inflight_attempt(state, key, inflight, :leader_deadline_exceeded)
        restart_inflight_load(state, key, valid, inflight)

      true ->
        # Non-leader waiter expired — just remove them, keep task running
        inflight = %{inflight | waiters: valid}
        %{state | inflight_loads: Map.put(state.inflight_loads, key, inflight)}
    end
  end

  defp build_waiter(request, from, now_ms) do
    deadline_ms = effective_deadline_ms(request, now_ms)

    if deadline_ms <= now_ms do
      {:error, :deadline_exceeded}
    else
      {:ok,
       %{
         id: make_ref(),
         from: from,
         deadline_unix_ms: deadline_ms,
         timer_ref: nil
       }}
    end
  end

  defp effective_deadline_ms(%EnsureModelLoadedRequest{deadline_unix_ms: d}, _now_ms)
       when is_integer(d) and d > 0,
       do: d

  defp effective_deadline_ms(_request, now_ms),
    do: now_ms + Node.worker_load_timeout_ms()

  defp schedule_waiter_timer(waiter, key, task_ref, now_ms) do
    delay = max(waiter.deadline_unix_ms - now_ms, 0)
    msg = {:inflight_waiter_timeout, key, task_ref, waiter.id}
    timer_ref = Process.send_after(self(), msg, delay)
    %{waiter | timer_ref: timer_ref}
  end

  defp cancel_all_waiter_timers(waiters) do
    Enum.each(waiters, fn waiter ->
      if waiter.timer_ref, do: Process.cancel_timer(waiter.timer_ref)
    end)
  end

  defp partition_waiters(waiters, now_ms) do
    {valid, expired} =
      Enum.split_with(waiters, fn w -> w.deadline_unix_ms > now_ms end)

    {expired, valid}
  end

  defp remove_inflight(state, key, inflight) do
    Process.demonitor(inflight.task_ref, [:flush])

    %{
      state
      | inflight_loads: Map.delete(state.inflight_loads, key),
        load_refs: Map.delete(state.load_refs, inflight.task_ref)
    }
  end

  defp abort_inflight_attempt(state, key, inflight, cancel_reason) do
    # Terminate the supervised task
    Task.Supervisor.terminate_child(@task_supervisor, inflight.task_pid)
    Process.demonitor(inflight.task_ref, [:flush])

    # Drain any pending worker-started message
    {state, worker_drained?} = drain_pending_worker_started(state, key, inflight.task_pid)

    emit_load_stop(key, inflight, %{
      outcome: :cancelled,
      waiter_count: inflight.total_waiter_count,
      replied_waiter_count: inflight.replied_waiter_count,
      worker_started: inflight.worker_pid != nil or worker_drained?,
      cancel_reason: cancel_reason
    })

    # Remove inflight tracking
    state = %{
      state
      | inflight_loads: Map.delete(state.inflight_loads, key),
        load_refs: Map.delete(state.load_refs, inflight.task_ref)
    }

    # Clean up partial worker if one was started
    cleanup_failed_worker(state, key)
  end

  defp restart_inflight_load(state, key, valid_waiters, prev_inflight) do
    now_ms = System.system_time(:millisecond)

    # Re-check deadlines at restart time
    {still_expired, still_valid} = partition_waiters(valid_waiters, now_ms)
    reply_waiters(still_expired, ModelLoadFailure.to_response(:deadline_exceeded))

    if still_valid == [] do
      # Everyone expired during cleanup
      state
    else
      # Choose new leader: highest deadline, tie-break by list position (first wins)
      new_leader =
        Enum.max_by(still_valid, fn w -> w.deadline_unix_ms end)

      # Re-use the stored original request with only the deadline overridden
      leader_request = %{prev_inflight.request | deadline_unix_ms: new_leader.deadline_unix_ms}

      manager = self()
      models_root = Node.models_root()

      task =
        Task.Supervisor.async_nolink(@task_supervisor, fn ->
          run_load_pipeline(key, leader_request, models_root, manager)
        end)

      # Reschedule all waiter timers with new task_ref
      rescheduled_waiters =
        Enum.map(still_valid, fn w ->
          schedule_waiter_timer(w, key, task.ref, now_ms)
        end)

      inflight = %{
        request: leader_request,
        request_fingerprint: prev_inflight.request_fingerprint,
        leader_waiter_id: new_leader.id,
        started_monotonic_ms: System.monotonic_time(:millisecond),
        source_scheme: prev_inflight.source_scheme,
        preload: prev_inflight.preload,
        backend: prev_inflight.backend,
        task_pid: task.pid,
        task_ref: task.ref,
        waiters: rescheduled_waiters,
        total_waiter_count: length(rescheduled_waiters),
        replied_waiter_count: 0,
        worker_pid: nil
      }

      emit_load_start(key, inflight)

      %{
        state
        | inflight_loads: Map.put(state.inflight_loads, key, inflight),
          load_refs: Map.put(state.load_refs, task.ref, key)
      }
    end
  end

  # -- Inflight cancellation -------------------------------------------------

  defp cancel_inflight_load(state, key, cancel_reason) do
    case Map.get(state.inflight_loads, key) do
      nil ->
        state

      inflight ->
        # Cancel all waiter timers
        cancel_all_waiter_timers(inflight.waiters)

        # Shut down the task
        Task.Supervisor.terminate_child(@task_supervisor, inflight.task_pid)
        Process.demonitor(inflight.task_ref, [:flush])

        # Drain any pending worker-started message the task may have sent
        # before being killed — prevents orphaned workers under WorkerSupervisor.
        {state, worker_drained?} = drain_pending_worker_started(state, key, inflight.task_pid)

        all_replied = inflight.replied_waiter_count + length(inflight.waiters)

        emit_load_stop(key, inflight, %{
          outcome: :cancelled,
          waiter_count: inflight.total_waiter_count,
          replied_waiter_count: all_replied,
          worker_started: inflight.worker_pid != nil or worker_drained?,
          cancel_reason: cancel_reason
        })

        # Reply all blocked waiters with failure
        reply_waiters(inflight.waiters, ModelLoadFailure.to_response(:load_cancelled))

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
      placement_state: :PLACEMENT_STATE_LOADING,
      last_used_monotonic_ms: System.monotonic_time(:millisecond)
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

  defp touch_worker_last_used(state, key, at_ms \\ System.monotonic_time(:millisecond)) do
    case Map.get(state.workers, key) do
      nil -> state
      _entry -> put_in(state, [:workers, key, :last_used_monotonic_ms], at_ms)
    end
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

  defp status_response(state) do
    tool_snapshot = ToolCapabilityCatalog.snapshot()

    %StatusResponse{
      worker_state: worker_state(state),
      loaded_models: loaded_models(state),
      active_request_count: map_size(state.active_requests),
      node_metadata: build_node_metadata(),
      runtime_health: aggregate_runtime_health(state),
      hosted_tool_capabilities: tool_snapshot.capabilities,
      hosted_tool_readiness: tool_snapshot.readiness
    }
  end

  defp build_node_metadata do
    %RuntimeNodeMetadata{
      node_id: Node.node_id() || "",
      display_name: Node.display_name() || "",
      hostname: Node.hostname() || "",
      agent_version: Node.agent_version() || "",
      listen_host: Node.listen_host_string() || "",
      listen_port: Node.listen_port() || 0,
      worker_backend: Node.worker_backend() || ""
    }
  end

  # Health aggregation algorithm:
  # 1. Inflight loads → degraded/starting
  # 2. Workers in LOADING state → degraded/starting
  # 3. No workers → healthy
  # 4. Probe each loaded worker; first unhealthy wins
  # 5. All healthy → healthy
  defp aggregate_runtime_health(state) do
    cond do
      map_size(state.inflight_loads) > 0 ->
        first_inflight = first_sorted_model_ref(state.inflight_loads)

        %RuntimeHealth{
          ready: false,
          health_code: "starting",
          health_message: "model load in progress",
          affected_model: first_inflight
        }

      has_loading_worker?(state) ->
        loading_ref = first_loading_worker_ref(state)

        %RuntimeHealth{
          ready: false,
          health_code: "starting",
          health_message: "model load in progress",
          affected_model: loading_ref
        }

      map_size(state.workers) == 0 ->
        %RuntimeHealth{ready: true, health_code: "", health_message: ""}

      true ->
        probe_workers_health(state)
    end
  end

  defp has_loading_worker?(state) do
    Enum.any?(state.workers, fn {_key, entry} ->
      entry.placement_state == :PLACEMENT_STATE_LOADING
    end)
  end

  defp first_loading_worker_ref(state) do
    state.workers
    |> Enum.filter(fn {_key, entry} -> entry.placement_state == :PLACEMENT_STATE_LOADING end)
    |> Enum.sort_by(fn {{model_id, version}, _} -> {model_id, version} end)
    |> List.first()
    |> case do
      {_key, entry} -> entry.model_ref
      nil -> nil
    end
  end

  # For inflight_loads keyed by {model_id, version}, extract the first model ref
  defp first_sorted_model_ref(inflight_loads) do
    inflight_loads
    |> Enum.sort_by(fn {{model_id, version}, _} -> {model_id, version} end)
    |> List.first()
    |> case do
      {{model_id, version}, _entry} -> %ModelRef{model_id: model_id, version: version}
      nil -> nil
    end
  end

  # NOTE: Sequential probing with 1s timeout per worker. Acceptable for
  # single-node / low-worker-count (capped by max_loaded_models). For
  # multi-node with many workers, consider parallel probing or cached health.
  defp probe_workers_health(state) do
    loaded_workers =
      state.workers
      |> Enum.filter(fn {_key, entry} -> entry.placement_state == :PLACEMENT_STATE_LOADED end)
      |> Enum.sort_by(fn {{model_id, version}, _} -> {model_id, version} end)

    Enum.reduce_while(loaded_workers, nil, fn {_key, entry}, _acc ->
      case WorkerProcess.status(entry.pid, timeout: 1_000) do
        {:ok, %{ready: true}} ->
          {:cont, nil}

        {:ok, %{ready: false} = status} ->
          {:halt,
           %RuntimeHealth{
             ready: false,
             health_code: status[:health_code] || "worker_unhealthy",
             health_message: status[:health_message] || "",
             affected_model: entry.model_ref
           }}

        {:error, _reason} ->
          {:halt,
           %RuntimeHealth{
             ready: false,
             health_code: "worker_status_error",
             health_message: "worker status request failed",
             affected_model: entry.model_ref
           }}
      end
    end)
    |> case do
      nil -> %RuntimeHealth{ready: true, health_code: "", health_message: ""}
      health -> health
    end
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

  # -- Eviction helpers ------------------------------------------------------

  # Evicts synchronously before the async load task starts. If the incoming
  # load subsequently fails (bad hash, runtime error, etc.), the evicted model
  # is NOT restored — the slot will be reclaimed by the next successful load.
  # This is intentional: deferring eviction until after acquisition would
  # require cross-process coordination between the async load task and the
  # GenServer's capacity state.
  defp maybe_evict_before_load(state, target_key) do
    case Node.max_loaded_models() do
      nil ->
        {:ok, state}

      limit ->
        reserved_count = count_capacity_reserved(state)

        if reserved_count < limit do
          {:ok, state}
        else
          do_evict(state, target_key, limit, reserved_count)
        end
    end
  end

  defp do_evict(state, target_key, limit, reserved_count) do
    start_time = System.monotonic_time(:millisecond)
    {incoming_model_id, incoming_version} = target_key

    # victim_model_id/victim_version are nil at start — filled in stop/exception
    # events after select_eviction_candidate runs.
    base_meta = %{
      incoming_model_id: incoming_model_id,
      incoming_version: incoming_version,
      victim_model_id: nil,
      victim_version: nil,
      max_loaded_models: limit,
      reserved_model_count_before: reserved_count
    }

    emit_eviction_start(base_meta)

    case select_eviction_candidate(state, target_key) do
      {:ok, victim_key, victim_entry} ->
        {victim_model_id, victim_version} = victim_key

        eviction_meta =
          Map.merge(base_meta, %{
            victim_model_id: victim_model_id,
            victim_version: victim_version
          })

        evict_request = %UnloadModelRequest{
          model_id: victim_model_id,
          version: victim_version,
          force: false,
          evict: true
        }

        case unload_worker_entry(state, victim_key, victim_entry, evict_request) do
          {:ok, next_state} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            emit_eviction_stop(eviction_meta, duration_ms)
            {:ok, next_state}

          {:error, reason, next_state} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            emit_eviction_exception(eviction_meta, duration_ms, reason)
            {:error, reason, next_state}
        end

      :none ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        emit_eviction_exception(
          Map.merge(base_meta, %{victim_model_id: nil, victim_version: nil}),
          duration_ms,
          :model_capacity_exhausted
        )

        {:error, :model_capacity_exhausted, state}
    end
  end

  defp select_eviction_candidate(state, target_key) do
    candidates =
      state.workers
      |> Enum.filter(fn {key, entry} ->
        key != target_key and
          entry.placement_state == :PLACEMENT_STATE_LOADED and
          active_request_count_for_model(state.active_requests, key) == 0
      end)
      |> Enum.sort_by(fn {key, entry} ->
        {entry.last_used_monotonic_ms, key}
      end)

    case candidates do
      [{key, entry} | _] -> {:ok, key, entry}
      [] -> :none
    end
  end

  # Unlike perform_unload/5 (the explicit unload path), this does NOT call
  # maybe_cleanup_unloaded_requests — select_eviction_candidate/2 guarantees
  # the victim has zero active requests, so cleanup would be a no-op.
  defp unload_worker_entry(state, key, entry, request) do
    case safe_unload(entry.pid, force: request.force, evict: request.evict) do
      :ok ->
        _ = DynamicSupervisor.terminate_child(WorkerSupervisor, entry.pid)
        next_state = drop_worker(state, key, entry.monitor_ref)
        {:ok, next_state}

      {:error, :worker_unavailable} ->
        # Worker already gone — slot is freed, treat as success
        next_state =
          cleanup_worker_unavailable(
            drop_worker(state, key, entry.monitor_ref),
            key,
            :worker_unavailable
          )

        {:ok, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Counts unique model slots reserved by inflight loads OR workers in
  # LOADING/LOADED state. This is the correct capacity metric for admission
  # gating: a model key in `inflight_loads` has reserved a slot even before
  # its worker process exists or reaches LOADED. Keys present in both maps
  # (during the brief LOADING overlap) are counted once.
  defp count_capacity_reserved(state) do
    inflight_keys = Map.keys(state.inflight_loads) |> MapSet.new()

    worker_keys =
      state.workers
      |> Enum.filter(fn {_key, entry} ->
        entry.placement_state in [:PLACEMENT_STATE_LOADING, :PLACEMENT_STATE_LOADED]
      end)
      |> Enum.map(fn {key, _entry} -> key end)
      |> MapSet.new()

    MapSet.union(inflight_keys, worker_keys) |> MapSet.size()
  end

  # -- Telemetry helpers -----------------------------------------------------

  defp emit_eviction_start(meta) do
    :telemetry.execute(
      [:orchard, :node, :eviction, :start],
      %{system_time: System.system_time()},
      meta
    )
  end

  defp emit_eviction_stop(meta, duration_ms) do
    :telemetry.execute(
      [:orchard, :node, :eviction, :stop],
      %{duration_ms: duration_ms},
      Map.put(meta, :outcome, :evicted)
    )
  end

  defp emit_eviction_exception(meta, duration_ms, reason) do
    :telemetry.execute(
      [:orchard, :node, :eviction, :exception],
      %{duration_ms: duration_ms},
      Map.put(meta, :reason, reason)
    )
  end

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
