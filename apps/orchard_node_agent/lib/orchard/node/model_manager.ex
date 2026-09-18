defmodule Orchard.Node.ModelManager do
  @moduledoc """
  Source of truth for loaded model workers and active runtime requests.

  Ensure-load requests run as async supervised tasks with single-flight
  dedup: concurrent callers for the same `{model_id, version}` share one
  acquisition + worker-load pipeline and all receive the same reply.
  Status responses include aggregate node capacity and loaded-model placement
  capacity so the controller can avoid dispatching to full nodes or placements.
  """

  use GenServer

  import Bitwise, only: [band: 2, bsr: 2]

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Cluster.V1.RuntimeHealth
  alias Orchard.Cluster.V1.RuntimeMemoryBudget
  alias Orchard.Cluster.V1.RuntimeModelPlacement
  alias Orchard.Cluster.V1.RuntimeNodeMetadata
  alias Orchard.Cluster.V1.RuntimePrefixCacheStatus
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Cluster.V1.WorkerCrashCounter
  alias Orchard.Node
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request, as: AcquisitionRequest
  alias Orchard.Node.ModelLoadFailure
  alias Orchard.Node.ScorePrefixCacheResponse, as: ScoreResponse
  alias Orchard.Node.ToolCapabilityCatalog
  alias Orchard.Node.WorkerCapabilityEvidence
  alias Orchard.Node.WorkerProcess
  alias Orchard.Node.WorkerRecoveryCheckpointClient
  alias Orchard.Node.WorkerRecoveryCommand, as: RecoveryCommand
  alias Orchard.Node.WorkerRecoveryCustody
  alias Orchard.Node.WorkerRecoveryState, as: Recovery
  alias Orchard.Node.WorkerSupervisor

  @type worker_entry :: %{
          model_ref: ModelRef.t(),
          monitor_ref: reference(),
          pid: pid(),
          placement_state: atom(),
          request_limit: pos_integer() | nil,
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

  @uint32_max 4_294_967_295
  @uint64_max 18_446_744_073_709_551_615
  @memory_budget_uint64_fields [
    :max_recommended_working_set_size_bytes,
    :target_working_set_bytes,
    :overhead_bytes,
    :resident_memory_bytes,
    :estimated_headroom_bytes,
    :kv_cache_bytes_per_token,
    :prefill_workspace_bytes_per_token,
    :recommended_context_tokens
  ]
  @memory_budget_float_fields [:utilization]
  @invalid_memory_budget_numeric_message "memory budget status contained invalid numeric fields"
  @prefix_cache_fingerprint_cap 64
  @prefix_cache_fingerprint_pattern ~r/^hmac-sha256:[a-f0-9]{64}$/
  @prefix_cache_uint32_fields [:entry_count, :configured_max_entries]
  @prefix_cache_uint64_fields [
    :total_bytes,
    :hits,
    :misses,
    :failures,
    :stores,
    :evictions,
    :configured_max_bytes,
    :session_started_unix_ms
  ]
  @invalid_prefix_cache_numeric_message "prefix cache status contained invalid numeric fields"
  @score_prefix_cache_default_timeout_ms 150
  @score_prefix_cache_local_timeout_grace_ms 50
  @prompt_token_ids_support_probe_max_timeout_ms 1_000
  @worker_crash_model_limit 4
  @runtime_model_placement_limit 40
  @ordinary_unload_stop_deadline_ms 10_000
  @ordinary_unload_call_timeout_ms @ordinary_unload_stop_deadline_ms + 1_000

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
          worker_crash_counter_version: String.t(),
          worker_crashes: %{optional(String.t()) => non_neg_integer()},
          worker_refs: %{optional(reference()) => {String.t(), String.t()}},
          workers: %{optional({String.t(), String.t()}) => worker_entry()}
        }

  @task_supervisor Orchard.Node.ModelLoadTaskSupervisor

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec current() :: StatusResponse.t()
  def current, do: GenServer.call(__MODULE__, :current)

  @spec reset() :: :ok | {:error, :unavailable}
  def reset, do: GenServer.call(__MODULE__, :reset, 15_000)

  @spec prepare_shutdown() :: :ok | {:error, :unavailable}
  def prepare_shutdown, do: GenServer.call(__MODULE__, :prepare_shutdown, 12_000)

  @spec inspect_worker_recovery(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def inspect_worker_recovery(model_id, version) do
    GenServer.call(__MODULE__, {:inspect_worker_recovery, {model_id, version}}, 10_000)
  end

  @doc "Executes a command already authenticated by the dedicated control boundary."
  @spec recover_worker_placement(map()) :: {:ok, map()} | {:error, atom()}
  def recover_worker_placement(command) do
    GenServer.call(
      __MODULE__,
      {:recover_worker_placement, command},
      Node.worker_load_timeout_ms() + 15_000
    )
  end

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t()) :: EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request) do
    GenServer.call(__MODULE__, {:ensure_model_loaded, request}, call_timeout_for(request))
  end

  @spec unload_model(UnloadModelRequest.t()) :: Ack.t()
  def unload_model(%UnloadModelRequest{} = request) do
    GenServer.call(__MODULE__, {:unload_model, request}, @ordinary_unload_call_timeout_ms)
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

  @spec score_prefix_cache(ScorePrefixCacheRequest.t()) :: ScorePrefixCacheResponse.t()
  def score_prefix_cache(%ScorePrefixCacheRequest{} = request) do
    timeout_ms = score_prefix_cache_timeout_ms(request)

    GenServer.call(
      __MODULE__,
      {:score_prefix_cache, request},
      score_prefix_cache_manager_call_timeout(timeout_ms)
    )
  catch
    :exit, {:timeout, _call} ->
      score_prefix_cache_response("timeout", "score request timed out")

    :exit, _reason ->
      score_prefix_cache_response("unavailable", "model manager unavailable")
  end

  @doc """
  Evaluates `query` against the capability snapshot retained by the loaded
  worker for `model`, using the configured freshness window.

  Diagnostic only: the result is never written into `StatusResponse` or any
  other Controller-visible structure. Returns `:absent` when no worker is
  loaded for `model`.
  """
  @spec evaluate_worker_capability(
          ModelRef.t() | {String.t(), String.t()},
          WorkerCapabilityEvidence.query(),
          keyword()
        ) :: WorkerCapabilityEvidence.result()
  def evaluate_worker_capability(model, query, opts \\ []) when is_map(query) do
    {model_id, version} = key = worker_capability_model_key(model)

    snapshot =
      case GenServer.call(__MODULE__, {:loaded_worker_pid, key}) do
        {:ok, pid} -> WorkerProcess.capability_snapshot(pid, Keyword.take(opts, [:timeout]))
        :error -> nil
      end

    result =
      WorkerCapabilityEvidence.evaluate(
        snapshot,
        query,
        System.monotonic_time(:millisecond),
        freshness_window_ms: Node.worker_capabilities_freshness_window_ms()
      )

    :telemetry.execute(
      [:orchard, :node, :worker_capabilities, :evaluated],
      %{system_time: System.system_time()},
      %{model_id: model_id, version: version, result: evaluation_result_kind(result)}
    )

    result
  end

  defp worker_capability_model_key(%ModelRef{model_id: model_id, version: version}),
    do: model_key(model_id, version)

  defp worker_capability_model_key({model_id, version})
       when is_binary(model_id) and is_binary(version),
       do: model_key(model_id, version)

  defp evaluation_result_kind({:supported, _profile_id, _incarnation}), do: :supported
  defp evaluation_result_kind(result) when is_atom(result), do: result

  @impl true
  def init(_init_arg) do
    {:ok, initial_state()}
  end

  # -- handle_call -----------------------------------------------------------

  @impl true
  def handle_call(:current, _from, state) do
    {response, next_state} = status_response(state)
    {:reply, response, next_state}
  end

  def handle_call(:prepare_shutdown, from, state) do
    handle_call(:reset, from, %{state | stopping?: true})
  end

  def handle_call(:reset, _from, %{resetting?: true} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(:reset, from, state) do
    Enum.each(state.eviction_continuations, fn {_ref, continuation} ->
      GenServer.reply(continuation.from, ModelLoadFailure.to_response(:load_cancelled))
    end)

    state = %{state | resetting?: true, eviction_continuations: %{}}

    state =
      Enum.reduce(Map.keys(state.recovery), state, fn key, acc ->
        case acc.recovery[key] do
          %{prior?: true} -> acc
          _current_epoch -> stop_recovery_intent(acc, key, [:await_cleanup]) |> pump_recovery(key)
        end
      end)

    state = cancel_all_inflight_loads(state, :reset)
    state = Enum.reduce(Map.keys(state.workers), state, &cleanup_worker_placement(&2, &1))

    Enum.each(state.recovery_hydrations, fn {_key, hydration} ->
      Enum.each(hydration.waiters, &reply_recovery_unavailable/1)
    end)

    state = %{state | recovery_hydrations: %{}}

    send(
      self(),
      {:recovery_reset_complete, state.recovery_epoch, from,
       System.monotonic_time(:millisecond) + 10_000}
    )

    {:noreply, state}
  end

  def handle_call({:inspect_worker_recovery, key}, from, state) do
    case Map.get(state.recovery, key) do
      nil -> {:noreply, hydrate_recovery(state, key, {:inspect, from})}
      _entry -> {:reply, {:ok, recovery_projection(state, key)}, state}
    end
  end

  def handle_call({:recover_worker_placement, command}, from, state) do
    if state.stopping? or state.resetting? do
      {:reply, {:error, :unavailable}, state}
    else
      handle_recovery_command(command, from, state)
    end
  end

  def handle_call({:recovery_claim_worker, key}, {task_pid, _tag} = from, state) do
    case Map.get(state.inflight_loads, key) do
      %{task_pid: ^task_pid, worker_pid: nil, request: request} = inflight ->
        handle_recovery_claim(state, key, inflight, request, task_pid, from)

      _stale ->
        {:reply, {:error, :worker_unavailable}, state}
    end
  end

  def handle_call({:ensure_model_loaded, %EnsureModelLoadedRequest{} = request}, from, state) do
    key = model_key(request.model_id, request.version)

    cond do
      state.stopping? or state.resetting? ->
        {:reply, recovery_refusal_response(:placement_recovery_required), state}

      not Map.has_key?(state.recovery, key) ->
        {:noreply, hydrate_recovery(state, key, {:ensure, request, from})}

      reason = Recovery.refusal(state.recovery[key]) ->
        {:reply, recovery_refusal_response(reason), state}

      Map.has_key?(state.inflight_loads, key) ->
        handle_inflight_join(key, request, from, state)

      # Already loaded — fast path
      match?(%{placement_state: :PLACEMENT_STATE_LOADED}, Map.get(state.workers, key)) ->
        reply_loaded_worker(state, key, request)

      # No worker, no inflight — evict if needed, then start new acquisition task
      true ->
        begin_load(state, key, request, from)
    end
  end

  def handle_call({:unload_model, %UnloadModelRequest{} = request}, from, state) do
    deadline = System.monotonic_time(:millisecond) + @ordinary_unload_stop_deadline_ms
    handle_unload_model(request, from, deadline, state)
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
        result =
          case Recovery.refusal(state.recovery[active_request.model_key]) do
            nil -> safe_start_request(pid, request.request_id, request, subscriber)
            reason -> {:error, {:worker_recovery_refused, reason}}
          end

        case result do
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

  def handle_call({:score_prefix_cache, %ScorePrefixCacheRequest{} = request}, _from, state) do
    response = score_prefix_cache_for_state(request, state)
    {:reply, response, state}
  end

  def handle_call({:loaded_worker_pid, key}, _from, state) do
    case Map.get(state.workers, key) do
      %{placement_state: :PLACEMENT_STATE_LOADED, pid: pid} -> {:reply, {:ok, pid}, state}
      _other -> {:reply, :error, state}
    end
  end

  defp handle_recovery_command(command, from, state) do
    case RecoveryCommand.validate(command, Node.node_id()) do
      {:ok, command} ->
        key = {command.key.model_id, command.key.version}

        case state.recovery[key] do
          nil -> {:noreply, hydrate_recovery(state, key, {:recover, command, from})}
          entry -> begin_operator_recovery(state, key, entry, command, from)
        end

      error ->
        {:reply, error, state}
    end
  end

  defp handle_recovery_claim(state, key, inflight, request, task_pid, from) do
    entry = Map.fetch!(state.recovery, key)

    cond do
      state.stopping? or state.resetting? ->
        {:reply, {:error, :worker_unavailable}, state}

      recovery_claim_retry?(entry, inflight) ->
        Process.send_after(
          self(),
          {:recovery_claim_retry, state.recovery_epoch, key, from},
          50
        )

        {:noreply, state}

      not recovery_claim_allowed?(entry, inflight) ->
        {:reply, {:error, :worker_unavailable}, state}

      true ->
        admit_recovery_claim(state, key, entry, inflight, request, task_pid, from)
    end
  end

  defp recovery_claim_retry?(entry, inflight) do
    not recovery_claim_allowed?(entry, inflight) and entry.hydrated? and not entry.prior? and
      entry.policy.state == :armed and
      (inflight[:recovery_wait?] == true or claim_blocked_by_pending_effect?(entry))
  end

  @claim_defer_retry_streak_limit 1

  # An unacknowledged pre-effect checkpoint leaves desired/pending set with
  # ownership already resolved. SPEC.md §12.2.1 treats that as neither a crash
  # nor a restart failure, so the claim waits for the effect to settle instead of
  # reporting worker_unavailable, which §5.10 would count as worker_or_node_loss.
  #
  # The wait is bounded to a write that has not yet failed: once
  # WorkerRecoveryState.unavailable/3 has recorded a failed write, the claim is
  # answered immediately rather than re-arming until the Controller load
  # deadline, which would hold one attempt for the whole deadline and consume the
  # request budget that bounded retry needs. One failed write is the transient
  # hiccup this deferral exists for; a second means the outage is not transient.
  defp claim_blocked_by_pending_effect?(entry) do
    is_nil(entry.policy.incarnation) and
      entry.retry_streak <= @claim_defer_retry_streak_limit and
      entry.ownership["phase"] in ["resolved", "operator_terminated"] and
      not (is_nil(entry.desired) and is_nil(entry.pending))
  end

  defp admit_recovery_claim(state, key, entry, inflight, request, task_pid, from) do
    incarnation = new_worker_crash_counter_version()

    entry = %{
      entry
      | request: %{request | deadline_unix_ms: 0},
        ownership: %{
          "phase" => "loading",
          "incarnation" => incarnation,
          "custody" => WorkerRecoveryCustody.boot_identity()
        }
    }

    entry =
      Recovery.transition(entry, {:admit, incarnation}, recovery_now(), [
        {:spawn_worker, task_pid, from}
      ])

    state =
      put_in(
        state,
        [:inflight_loads, key],
        Map.put(inflight, :recovery_incarnation, incarnation)
      )

    {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
  end

  defp reply_loaded_worker(state, key, request) do
    entry = Map.fetch!(state.workers, key)
    deadline_ms = effective_deadline_ms(request, System.system_time(:millisecond))

    case probe_worker_prompt_token_ids_support_status(entry, deadline_ms) do
      {{:ok, supports_prompt_token_ids?}, status_result} ->
        request_limit = cacheable_request_limit_from_status_result(status_result)

        response =
          loaded_response(
            true,
            supports_prompt_token_ids?,
            placement_capacity(state, key, entry, request_limit)
          )

        next_state =
          state
          |> put_cached_worker_request_limit(key, request_limit)
          |> touch_worker_last_used(key)

        {:reply, response, next_state}

      {{:error, :deadline_exceeded}, _status_result} ->
        {:reply, ModelLoadFailure.to_response(:deadline_exceeded), state}
    end
  end

  defp begin_load(state, key, request, from) do
    case maybe_evict_before_load(state, key, request, from) do
      {:ok, state} -> start_load_task(key, request, from, state)
      {:deferred, state} -> {:noreply, state}
      {:error, reason, state} -> {:reply, ModelLoadFailure.to_response(reason), state}
    end
  end

  defp handle_prepare_request(%ExecuteInferenceRequest{} = request, subscriber, state) do
    key = model_key(request.model_id, request.version)

    cond do
      state.stopping? or state.resetting? ->
        {:reply, {:error, {:worker_recovery_refused, :placement_recovery_required}}, state}

      Map.has_key?(state.active_requests, request.request_id) ->
        {:reply, {:error, :request_already_active}, state}

      reason = Recovery.refusal(Map.get(state.recovery, key)) ->
        {:reply, {:error, {:worker_recovery_refused, reason}}, state}

      true ->
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
    worker_request_limits = loaded_worker_request_limits(state)
    node_request_limit = node_max_concurrency(worker_request_limits)
    request_limit = Map.get(worker_request_limits, key) || request_limit_for_worker(pid)

    if node_at_request_capacity?(state.active_requests, node_request_limit) or
         model_at_request_capacity?(state.active_requests, key, request_limit) do
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
  def handle_info({:recovery_hydrated, epoch, key, ref, result}, state) do
    case Map.get(state.recovery_hydrations, key) do
      %{ref: ^ref, waiters: waiters} when epoch == state.recovery_epoch ->
        state = %{state | recovery_hydrations: Map.delete(state.recovery_hydrations, key)}
        handle_recovery_hydration_result(result, state, epoch, key, waiters)

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_hydration_ready, epoch, _key, {:ensure, request, from}}, state)
      when epoch == state.recovery_epoch do
    case handle_call({:ensure_model_loaded, request}, from, state) do
      {:reply, response, state} ->
        GenServer.reply(from, response)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:recovery_hydration_ready, epoch, _key, {:unload, request, from, deadline}},
        state
      )
      when epoch == state.recovery_epoch do
    case handle_unload_model(request, from, deadline, state) do
      {:reply, response, state} ->
        GenServer.reply(from, response)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_hydration_ready, epoch, key, {:inspect, from}}, state)
      when epoch == state.recovery_epoch do
    projection = recovery_projection(state, key)
    GenServer.reply(from, {:ok, projection})
    {:noreply, discard_cold_recovery_entry(state, key)}
  end

  def handle_info({:recovery_hydration_ready, epoch, _key, {:recover, command, from}}, state)
      when epoch == state.recovery_epoch do
    case handle_recovery_command(command, from, state) do
      {:reply, response, state} ->
        GenServer.reply(from, response)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_checkpoint_result, epoch, key, id, result}, state)
      when epoch == state.recovery_epoch do
    case state.recovery[key] do
      %{pending: %{id: ^id}} = entry ->
        handle_recovery_checkpoint_result(result, state, epoch, key, id, entry)

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_checkpoint_retry, epoch, key}, state)
      when epoch == state.recovery_epoch do
    case Recovery.retry(state.recovery[key], recovery_now()) do
      {:write, entry, pending} ->
        {:noreply, put_recovery(state, key, entry) |> send_recovery_checkpoint(key, pending)}

      {:wait, _entry} ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_timer, epoch, key, fence}, state)
      when epoch == state.recovery_epoch do
    case Map.get(state.recovery, key) do
      %{policy: %{state: :backoff, fence: ^fence}, desired: nil, pending: nil} = entry ->
        cond do
          recovery_now() < entry.policy.due_ms ->
            {:noreply, apply_recovery_effect(state, key, {:schedule, fence, entry.policy.due_ms})}

          Map.has_key?(state.inflight_loads, key) or not recovery_cleanup_resolved?(state, key) ->
            Process.send_after(self(), {:recovery_timer, epoch, key, fence}, 1_000)
            {:noreply, state}

          true ->
            entry = %{entry | ownership: Map.put(entry.ownership, "phase", "resolved")}
            entry = Recovery.transition(entry, {:timer, fence, true}, recovery_now())
            {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
        end

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_claim_retry, epoch, key, from}, state)
      when epoch == state.recovery_epoch do
    case handle_call({:recovery_claim_worker, key}, from, state) do
      {:reply, reply, next} ->
        GenServer.reply(from, reply)
        {:noreply, next}

      {:noreply, next} ->
        {:noreply, next}
    end
  end

  def handle_info({:recovery_reset_complete, epoch, from, deadline}, state)
      when epoch == state.recovery_epoch do
    resolved? =
      Enum.all?(state.recovery, fn {_key, entry} ->
        is_nil(entry.pending) and is_nil(entry.desired) and
          (entry.prior? or entry.ownership["phase"] in ["resolved", "operator_terminated"])
      end)

    cond do
      resolved? ->
        GenServer.reply(from, :ok)

      System.monotonic_time(:millisecond) >= deadline ->
        GenServer.reply(from, {:error, :unavailable})

      true ->
        Process.send_after(self(), {:recovery_reset_complete, epoch, from, deadline}, 50)
    end

    done? = resolved? or System.monotonic_time(:millisecond) >= deadline
    {:noreply, %{state | resetting?: not done?}}
  end

  def handle_info({:operator_cleanup_ready, epoch, key, id}, state)
      when epoch == state.recovery_epoch do
    case state.recovery[key] do
      %{command: %{"id" => ^id, "phase" => "claimed"}, desired: nil, pending: nil} = entry ->
        handle_operator_cleanup_ready(state, epoch, key, id, entry)

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_stable, epoch, key, incarnation}, state)
      when epoch == state.recovery_epoch do
    case state.recovery[key] do
      %{prior?: false, policy: %{incarnation: ^incarnation, state: :armed}} = entry ->
        entry = Recovery.transition(entry, :tick, recovery_now())
        {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:ordinary_unload_deadline, epoch, key, waiter_id}, state)
      when epoch == state.recovery_epoch do
    case Map.get(state.recovery, key) do
      %{stop_waiters: waiters} = entry ->
        {expired, retained} =
          Enum.split_with(waiters, fn {id, _from, _response, _timer_ref} -> id == waiter_id end)

        Enum.each(expired, &reply_stop_waiter(&1, recovery_unavailable_ack()))
        {:noreply, put_in(state, [:recovery, key], %{entry | stop_waiters: retained})}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_cleanup, epoch, key}, state) when epoch == state.recovery_epoch do
    case Map.get(state.recovery, key) do
      %{ownership: %{"phase" => "cleanup"}} = entry ->
        if recovery_cleanup_resolved?(state, key) do
          entry = %{entry | ownership: Map.put(entry.ownership, "phase", "resolved")}

          effects =
            case entry.policy do
              %{state: :backoff, fence: fence, due_ms: due} -> [{:schedule, fence, due}]
              _other -> [:reply_stopped, :reply_operator]
            end

          entry = Recovery.checkpoint(entry, effects)
          {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
        else
          {:noreply, apply_recovery_effect(state, key, :await_cleanup)}
        end

      _stale ->
        {:noreply, state}
    end
  end

  # Worker creation is now synchronous with the durable manager claim. Legacy
  # notifications cannot establish ownership or terminate an unrelated process.
  def handle_info({:model_load_worker_started, _key, _task_pid, _worker_pid}, state),
    do: {:noreply, state}

  def handle_info({:model_load_finished, key, task_pid, result}, state) do
    case Map.get(state.inflight_loads, key) do
      %{task_pid: ^task_pid} = inflight ->
        handle_model_load_result(result, state, key, task_pid, inflight)

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
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if Map.has_key?(state.eviction_continuations, ref) do
      {continuation, continuations} = Map.pop(state.eviction_continuations, ref)
      finish_eviction(%{state | eviction_continuations: continuations}, continuation, result)
    else
      case Map.pop(state.recovery_io_refs, ref) do
        {nil, _} ->
          {:noreply, state}

        {callback, refs} ->
          handle_info(Tuple.insert_at(callback, tuple_size(callback), result), %{
            state
            | recovery_io_refs: refs
          })
      end
    end
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

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    cond do
      # Load task crashed
      Map.has_key?(state.load_refs, monitor_ref) ->
        key = Map.fetch!(state.load_refs, monitor_ref)

        case Map.get(state.inflight_loads, key) do
          %{task_pid: ^pid} = inflight ->
            state = recovery_load_failed(state, key, inflight)
            next_state = complete_inflight_load(state, key, inflight, {:error, :task_crashed})
            {:noreply, next_state}

          _stale ->
            # Already cleaned up; just drop the ref
            {:noreply, %{state | load_refs: Map.delete(state.load_refs, monitor_ref)}}
        end

      Map.has_key?(state.recovery_io_refs, monitor_ref) ->
        {callback, refs} = Map.pop(state.recovery_io_refs, monitor_ref)

        handle_info(Tuple.insert_at(callback, tuple_size(callback), {:error, :unavailable}), %{
          state
          | recovery_io_refs: refs
        })

      # Worker process died
      Map.has_key?(state.worker_refs, monitor_ref) ->
        key = Map.fetch!(state.worker_refs, monitor_ref)
        cleanup_reason = cleanup_reason_for_worker_exit(reason)

        next_state =
          state
          |> accept_recovery_crash(key, pid)
          |> drop_worker(key, monitor_ref)
          |> increment_worker_crash(key)
          |> cleanup_worker_unavailable(key, cleanup_reason)
          |> fail_inflight_worker(key, pid)

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

  def handle_info(message, state)
      when is_tuple(message) and
             elem(message, 0) in [
               :recovery_hydrated,
               :recovery_hydration_ready,
               :recovery_checkpoint_result,
               :recovery_checkpoint_retry,
               :ordinary_unload_deadline,
               :recovery_timer,
               :recovery_cleanup,
               :operator_cleanup_ready,
               :recovery_stable,
               :recovery_reset_complete,
               :recovery_claim_retry
             ] do
    {:noreply, state}
  end

  defp handle_recovery_hydration_result({:ok, checkpoint}, state, epoch, key, waiters) do
    entry = Recovery.new(epoch) |> Recovery.hydrate(checkpoint)

    if stale_clean_checkpoint?(entry, epoch) do
      entry = Recovery.checkpoint(%{entry | command: nil}, [{:hydration_complete, waiters}])
      {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
    else
      state = put_recovery(state, key, entry)
      Enum.each(waiters, &send(self(), {:recovery_hydration_ready, epoch, key, &1}))
      {:noreply, state}
    end
  end

  defp handle_recovery_hydration_result({:error, _reason}, state, _epoch, key, waiters) do
    Enum.each(waiters, &reply_recovery_unavailable/1)
    {:noreply, put_in(state, [:recovery_read_retry_at, key], recovery_now() + 1_000)}
  end

  defp stale_clean_checkpoint?(entry, epoch),
    do: not entry.prior? and not is_nil(entry.owner_epoch) and entry.owner_epoch != epoch

  defp handle_recovery_checkpoint_result({:ok, checkpoint}, state, epoch, key, id, entry) do
    {entry, effects} = Recovery.acknowledge(entry, id, checkpoint)

    if is_nil(entry.pending) do
      state = put_recovery(state, key, entry)
      state = Enum.reduce(effects, state, &apply_recovery_effect(&2, key, &1))
      {:noreply, pump_recovery(state, key)}
    else
      handle_recovery_checkpoint_result(
        {:error, :unavailable},
        state,
        epoch,
        key,
        id,
        state.recovery[key]
      )
    end
  end

  defp handle_recovery_checkpoint_result(
         {:error, :stale_checkpoint},
         state,
         _epoch,
         key,
         _id,
         entry
       ) do
    reply_stale_checkpoint_effect_waiters(entry)
    reply_stale_checkpoint_operator_waiters(entry)

    state = %{state | recovery: Map.delete(state.recovery, key)}
    state = abandon_stale_checkpoint_load(state, key)
    {:noreply, hydrate_recovery(state, key, :rehydrate)}
  end

  defp handle_recovery_checkpoint_result({:error, _reason}, state, epoch, key, id, entry) do
    now = recovery_now()
    entry = entry |> release_deferred_hydration_waiters() |> Recovery.unavailable(id, now)
    Process.send_after(self(), {:recovery_checkpoint_retry, epoch, key}, entry.retry_at - now)
    {:noreply, put_recovery(state, key, entry)}
  end

  defp release_deferred_hydration_waiters(entry) do
    {deferred, retained} =
      Enum.split_with(entry.effects, &match?({:hydration_complete, _waiters}, &1))

    Enum.each(deferred, &reply_superseded_checkpoint_effect_waiter/1)
    %{entry | effects: retained}
  end

  defp reply_stale_checkpoint_effect_waiters(entry) do
    entry.effects
    |> Kernel.++(Map.get(entry, :superseded_effects, []))
    |> Enum.each(&reply_superseded_checkpoint_effect_waiter/1)
  end

  defp reply_stale_checkpoint_operator_waiters(entry) do
    Enum.each(entry.operator_waiters, &GenServer.reply(&1, {:error, :unavailable}))

    Enum.each(entry.stop_waiters, &reply_stop_waiter(&1, recovery_unavailable_ack()))
  end

  defp abandon_stale_checkpoint_load(state, key) do
    case state.inflight_loads[key] do
      nil ->
        state

      inflight ->
        complete_inflight_load(state, key, inflight, {:error, :worker_unavailable})
    end
  end

  defp handle_operator_cleanup_ready(state, epoch, key, id, entry) do
    cond do
      recovery_cleanup_resolved?(state, key) ->
        complete_operator_cleanup(state, key, id, entry)

      recovery_now() >= entry.operator_deadline ->
        {:noreply, fail_operator_recovery(state, key)}

      true ->
        Process.send_after(self(), {:operator_cleanup_ready, epoch, key, id}, 1_000)
        {:noreply, state}
    end
  end

  defp complete_operator_cleanup(state, key, id, entry) do
    phase = if entry.ownership["incarnation"], do: "operator_terminated", else: "resolved"
    ownership = Map.put(entry.ownership, "phase", phase)

    entry = %{
      entry
      | ownership: ownership,
        prior?: false,
        command: Map.put(entry.command, "phase", "cleanup")
    }

    entry = Recovery.checkpoint(entry, [{:operator_reset, id}])
    {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
  end

  defp handle_model_load_result({:ok, worker_pid} = result, state, key, task_pid, inflight) do
    entry = state.recovery[key]

    cond do
      Process.alive?(worker_pid) and current_load_completion?(entry, inflight, worker_pid) ->
        ownership =
          entry.ownership
          |> Map.put("phase", "loaded")
          |> put_runtime_custody(worker_pid)

        entry = %{entry | ownership: ownership}
        {entry, operator_effects} = complete_operator_load(entry)

        entry =
          Recovery.transition(
            entry,
            {:loaded, entry.policy.incarnation},
            recovery_now(),
            [{:publish_load, task_pid, result} | operator_effects]
          )

        {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}

      Process.alive?(worker_pid) ->
        {:noreply, state}

      true ->
        state = accept_recovery_crash(state, key, worker_pid)
        {:noreply, complete_inflight_load(state, key, inflight, {:error, :worker_unavailable})}
    end
  end

  defp handle_model_load_result({:error, reason} = result, state, key, _task_pid, inflight) do
    state = recovery_load_failed(state, key, inflight, reason)
    {:noreply, complete_inflight_load(state, key, inflight, result)}
  end

  defp recovery_claim_allowed?(entry, inflight) do
    entry.hydrated? and not entry.prior? and is_nil(entry.desired) and is_nil(entry.pending) and
      is_nil(entry.policy.incarnation) and
      entry.ownership["phase"] in ["resolved", "operator_terminated"] and
      (entry.policy.state == :armed or
         (entry.policy.state == :restarting and inflight.recovery_owner))
  end

  defp begin_operator_recovery(state, key, entry, command, from) do
    case operator_recovery_admission(state, key, entry, command) do
      :begin -> start_operator_recovery(state, key, command, from)
      {:reply, reply} -> {:reply, reply, state}
    end
  end

  defp operator_recovery_admission(state, key, entry, command) do
    cond do
      command.expected_epoch != state.recovery_epoch ->
        {:reply, {:error, :conflict}}

      duplicate_operator_command?(entry, command) ->
        {:reply, duplicate_operator_result(state, key, entry.command, command)}

      operator_revision_conflict?(entry, command) ->
        {:reply, {:error, :conflict}}

      recovery_checkpoint_busy?(entry) ->
        {:reply, {:error, :unavailable}}

      operator_conflict?(state, key, command.action) ->
        {:reply, {:error, :conflict}}

      entry.prior? and not recovery_cleanup_resolved?(state, key) ->
        {:reply, {:error, :unavailable}}

      true ->
        :begin
    end
  end

  defp duplicate_operator_command?(entry, command) do
    not is_nil(entry.command) and entry.command["id"] == command.command_id and
      entry.owner_epoch == entry.epoch
  end

  defp duplicate_operator_result(state, key, prior, command) do
    if prior["fingerprint"] == command.fingerprint,
      do: operator_result(state, key),
      else: {:error, :conflict}
  end

  defp operator_revision_conflict?(entry, command) do
    command.expected_revision != entry.revision or
      (RecoveryCommand.active?(entry.command) and entry.owner_epoch == entry.epoch)
  end

  defp recovery_checkpoint_busy?(entry),
    do: not entry.hydrated? or not is_nil(entry.pending) or not is_nil(entry.desired)

  defp start_operator_recovery(state, key, command, from) do
    state = observe_dead_recovery_worker(state, key)
    entry = state.recovery[key]
    ownership = operator_recovery_ownership(state, key, entry)

    entry = %{
      entry
      | ownership: ownership,
        command: %{
          "id" => command.command_id,
          "fingerprint" => command.fingerprint,
          "action" => command.action,
          "phase" => "claimed",
          "outcome" => nil
        },
        request: Map.get(command, :load_request) || entry.request,
        operator_waiters: [from],
        operator_deadline: recovery_now() + Node.worker_load_timeout_ms() + 5_000
    }

    entry =
      Recovery.transition(entry, :interrupt, recovery_now(), [
        {:operator_cleanup, command.command_id}
      ])

    {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
  end

  defp operator_recovery_ownership(state, key, entry) do
    cond do
      is_nil(entry.ownership["incarnation"]) ->
        Map.put(entry.ownership, "phase", "resolved")

      recovery_cleanup_resolved?(state, key) ->
        Map.put(entry.ownership, "phase", "operator_terminated")

      true ->
        cleanup_ownership(entry, entry.last_worker_pid)
    end
  end

  defp interrupted_ownership(entry) do
    if entry.ownership["incarnation"],
      do: cleanup_ownership(entry, entry.last_worker_pid),
      else: Map.put(entry.ownership, "phase", "resolved")
  end

  defp cleanup_ownership(entry, owner_pid) do
    entry.ownership
    |> Map.put("phase", "cleanup")
    |> put_runtime_custody(owner_pid)
  end

  defp put_runtime_custody(ownership, owner_pid) do
    custody = recovery_custody_module().record_runtime_custody(ownership["custody"], owner_pid)
    Map.put(ownership, "custody", custody)
  end

  defp recovery_custody_module,
    do: Node.runtime_config()[:worker_recovery_custody] || WorkerRecoveryCustody

  defp operator_conflict?(state, key, "clear") do
    match?(%{placement_state: :PLACEMENT_STATE_LOADED}, state.workers[key]) or
      match?(%{recovery_owner: false}, state.inflight_loads[key])
  end

  defp operator_conflict?(state, key, "unload"),
    do: active_request_count_for_model(state.active_requests, key) > 0

  defp operator_conflict?(_state, _key, "reload"), do: false

  defp operator_result(state, key) do
    case state.recovery[key] do
      %{command: %{"phase" => "completed", "outcome" => "ok"}, pending: nil, desired: nil} ->
        {:ok, recovery_projection(state, key)}

      _ ->
        {:error, :unavailable}
    end
  end

  defp observe_dead_recovery_worker(state, key) do
    case state.workers[key] do
      %{pid: pid} ->
        if Process.alive?(pid), do: state, else: accept_recovery_crash(state, key, pid)

      _ ->
        state
    end
  end

  defp handle_unload_model(%UnloadModelRequest{} = request, from, deadline, state) do
    key = model_key(request.model_id, request.version)

    cond do
      active_request_count_for_model(state.active_requests, key) > 0 and not request.force ->
        {:reply, %Ack{ok: false, message: "model has active requests"}, state}

      not Map.has_key?(state.recovery, key) ->
        {:noreply, hydrate_recovery(state, key, {:unload, request, from, deadline})}

      not state.recovery[key].hydrated? or state.recovery[key].prior? ->
        {:reply, %Ack{ok: false, message: "recovery ownership unresolved"}, state}

      true ->
        state = stop_recovery_intent(state, key, [{:ordinary_unload, request}])
        entry = state.recovery[key]
        accepted = %Ack{ok: true, message: "unload accepted"}

        entry = %{
          entry
          | stop_waiters: [
              new_stop_waiter(state, key, from, deadline, accepted) | entry.stop_waiters
            ]
        }

        {:noreply, put_recovery(state, key, entry) |> pump_recovery(key)}
    end
  end

  defp hydrate_recovery(state, key, waiter) do
    case Map.get(state.recovery_hydrations, key) do
      nil -> start_recovery_hydration(state, key, waiter)
      hydration -> append_recovery_hydration_waiter(state, key, hydration, waiter)
    end
  end

  defp start_recovery_hydration(state, key, waiter) do
    now = recovery_now()

    if now < Map.get(state.recovery_read_retry_at, key, now) do
      reply_recovery_unavailable(waiter)
      state
    else
      launch_recovery_hydration(state, key, waiter)
    end
  end

  defp launch_recovery_hydration(state, key, waiter) do
    ref = make_ref()
    epoch = state.recovery_epoch
    client = recovery_client()
    checkpoint_key = recovery_key(key)
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> client.read(checkpoint_key) end)

    %{
      state
      | recovery_hydrations:
          Map.put(state.recovery_hydrations, key, %{ref: ref, waiters: [waiter]}),
        recovery_io_refs:
          Map.put(state.recovery_io_refs, task.ref, {:recovery_hydrated, epoch, key, ref})
    }
  end

  defp append_recovery_hydration_waiter(state, key, hydration, waiter) do
    put_in(state, [:recovery_hydrations, key], %{
      hydration
      | waiters: [waiter | hydration.waiters]
    })
  end

  defp reply_recovery_unavailable({:unload, _request, from, _deadline}),
    do: GenServer.reply(from, %Ack{ok: false, message: "recovery checkpoint unavailable"})

  defp reply_recovery_unavailable({:inspect, from}),
    do: GenServer.reply(from, {:error, :unavailable})

  defp reply_recovery_unavailable({:recover, _command, from}),
    do: GenServer.reply(from, {:error, :unavailable})

  defp reply_recovery_unavailable(:rehydrate), do: :ok

  defp reply_recovery_unavailable({:ensure, _request, from}),
    do: GenServer.reply(from, recovery_refusal_response(:placement_recovery_required))

  defp recovery_refusal_response(reason),
    do: %EnsureModelLoadedResponse{
      placement_state: :PLACEMENT_STATE_FAILED,
      recovery_refusal: Atom.to_string(reason)
    }

  defp recovery_projection(state, key) do
    entry = Map.get(state.recovery, key, Recovery.new(state.recovery_epoch))
    Map.put(Recovery.projection(entry), :key, recovery_key(key))
  end

  defp recovery_now do
    clock =
      Node.runtime_config()[:worker_recovery_clock] ||
        fn -> System.monotonic_time(:millisecond) end

    clock.()
  end

  defp recovery_key({model_id, version}),
    do: %{node_id: Node.node_id(), model_id: model_id, version: version}

  defp recovery_client,
    do:
      Node.runtime_config()[:worker_recovery_checkpoint_client] || WorkerRecoveryCheckpointClient

  defp put_recovery(state, key, entry) do
    {entry, superseded_effects} = Recovery.take_superseded_effects(entry)
    entry = reply_superseded_checkpoint_effect_waiters(entry, superseded_effects)
    put_in(state, [:recovery, key], entry)
  end

  defp reply_superseded_checkpoint_effect_waiters(entry, effects) do
    Enum.each(effects, &reply_superseded_checkpoint_effect_waiter/1)

    entry
    |> reply_superseded_stop_waiters(effects)
    |> reply_superseded_operator_waiters(effects)
  end

  defp reply_superseded_checkpoint_effect_waiter({:spawn_worker, _task_pid, from}),
    do: GenServer.reply(from, {:error, :worker_unavailable})

  defp reply_superseded_checkpoint_effect_waiter({:hydration_complete, waiters}) do
    Enum.each(waiters, &reply_recovery_unavailable/1)
  end

  defp reply_superseded_checkpoint_effect_waiter(_effect), do: :ok

  defp reply_superseded_stop_waiters(entry, effects) do
    if entry.stop_waiters != [] and Enum.any?(effects, &stop_waiter_effect?/1) do
      reply_stopped_waiters(entry.stop_waiters, effects)
      %{entry | stop_waiters: []}
    else
      entry
    end
  end

  defp reply_stopped_waiters(waiters, effects) do
    response =
      if :reply_stopped in effects,
        do: nil,
        else: %Ack{ok: false, message: "recovery checkpoint superseded"}

    Enum.each(waiters, fn waiter ->
      reply_stop_waiter(waiter, response || stop_waiter_response(waiter))
    end)
  end

  defp new_stop_waiter(state, key, from, deadline, response) do
    id = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:ordinary_unload_deadline, state.recovery_epoch, key, id},
        max(deadline - System.monotonic_time(:millisecond), 0)
      )

    {id, from, response, timer_ref}
  end

  defp reply_stop_waiter({_id, from, _response, timer_ref}, response) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    GenServer.reply(from, response)
  end

  defp stop_waiter_response({_id, _from, response, _timer_ref}), do: response

  defp recovery_unavailable_ack,
    do: %Ack{ok: false, message: "recovery checkpoint unavailable"}

  defp stop_waiter_effect?({:ordinary_unload, _request}), do: true
  defp stop_waiter_effect?(:await_cleanup), do: true
  defp stop_waiter_effect?(:reply_stopped), do: true
  defp stop_waiter_effect?(_effect), do: false

  defp reply_superseded_operator_waiters(entry, effects) do
    if entry.operator_waiters != [] and Enum.any?(effects, &operator_waiter_effect?/1) do
      Enum.each(entry.operator_waiters, &GenServer.reply(&1, {:error, :unavailable}))
      %{entry | operator_waiters: [], operator_deadline: nil}
    else
      entry
    end
  end

  defp operator_waiter_effect?({:operator_cleanup, _command_id}), do: true
  defp operator_waiter_effect?({:operator_reset, _command_id}), do: true
  defp operator_waiter_effect?(:await_cleanup), do: true
  defp operator_waiter_effect?(:reply_operator), do: true
  defp operator_waiter_effect?(_effect), do: false

  defp discard_cold_recovery_entry(state, key) do
    case state.recovery[key] do
      %{hydrated?: true, prior?: false, desired: nil, pending: nil, command: nil} = entry ->
        if entry.policy.state == :armed and entry.policy.history == [] and
             entry.policy.delay_index == 0 and is_nil(entry.policy.incarnation) and
             entry.ownership["phase"] == "resolved" do
          %{state | recovery: Map.delete(state.recovery, key)}
        else
          state
        end

      _retained ->
        state
    end
  end

  defp pump_recovery(state, key) do
    case Recovery.begin_write(state.recovery[key], recovery_now()) do
      {:write, entry, pending} ->
        put_recovery(state, key, entry) |> send_recovery_checkpoint(key, pending)

      {:wait, _entry} ->
        state
    end
  end

  defp send_recovery_checkpoint(state, key, pending) do
    client = recovery_client()
    checkpoint_key = recovery_key(key)

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        client.commit(checkpoint_key, pending.epoch, pending.revision, pending.id, pending.record)
      end)

    put_in(
      state,
      [:recovery_io_refs, task.ref],
      {:recovery_checkpoint_result, state.recovery_epoch, key, pending.id}
    )
  end

  defp stop_recovery_intent(state, key, effects) do
    state = observe_dead_recovery_worker(state, key)
    entry = state.recovery[key]
    was_operator? = RecoveryCommand.active?(entry.command)
    entry = Recovery.transition(entry, :interrupt, recovery_now(), effects)
    entry = %{entry | ownership: interrupted_ownership(entry)}

    entry =
      if was_operator? do
        entry = %{
          entry
          | command:
              Map.merge(entry.command, %{"phase" => "completed", "outcome" => "unavailable"})
        }

        if entry.policy.state == :open,
          do: entry,
          else: put_in(entry.policy.state, :recovery_required)
      else
        entry
      end

    put_recovery(state, key, entry)
  end

  defp apply_recovery_effect(state, key, {:hydration_complete, waiters}) do
    Enum.each(waiters, &send(self(), {:recovery_hydration_ready, state.recovery_epoch, key, &1}))
    state
  end

  defp apply_recovery_effect(state, key, {:ordinary_unload, request}) do
    state = cancel_inflight_load(state, key, :unload_request)

    state =
      case state.workers[key] do
        %{pid: pid, monitor_ref: monitor} ->
          {response, next} = perform_unload(pid, key, monitor, request, state)
          entry = next.recovery[key]

          waiters =
            Enum.map(entry.stop_waiters, fn {id, from, _response, timer_ref} ->
              {id, from, response, timer_ref}
            end)

          put_recovery(next, key, %{entry | stop_waiters: waiters})

        _ ->
          state
      end

    if recovery_cleanup_resolved?(state, key) do
      entry = state.recovery[key]
      entry = %{entry | ownership: Map.put(entry.ownership, "phase", "resolved")}

      put_recovery(state, key, Recovery.checkpoint(entry, [:reply_stopped, :reply_operator]))
      |> pump_recovery(key)
    else
      apply_recovery_effect(state, key, :await_cleanup)
    end
  end

  defp apply_recovery_effect(state, key, {:operator_cleanup, id}) do
    state =
      state |> cancel_inflight_load(key, :operator_recovery) |> cleanup_worker_placement(key)

    state = maybe_cleanup_unloaded_requests(state, key, true)
    send(self(), {:operator_cleanup_ready, state.recovery_epoch, key, id})
    state
  end

  defp apply_recovery_effect(state, key, {:operator_reset, id}) do
    case state.recovery[key] do
      %{command: %{"id" => ^id, "phase" => "cleanup"}} = entry ->
        action =
          case entry.command["action"] do
            "clear" -> :clear
            "unload" -> :unload
            "reload" -> :reload
          end

        command =
          Map.merge(entry.command, %{
            "phase" => if(action == :reload, do: "loading", else: "completed"),
            "outcome" => if(action == :reload, do: nil, else: "ok")
          })

        entry = %{
          entry
          | command: command,
            ownership: %{"phase" => "resolved", "incarnation" => nil, "custody" => nil},
            last_worker_pid: nil
        }

        effects = if action == :reload, do: [], else: [:reply_operator]

        entry =
          Recovery.transition(entry, {:authorized_recovery, action}, recovery_now(), effects)

        put_recovery(state, key, entry) |> pump_recovery(key)

      _ ->
        state
    end
  end

  defp apply_recovery_effect(state, key, :reply_operator) do
    entry = state.recovery[key]

    if is_nil(entry.pending) and is_nil(entry.desired) do
      Enum.each(entry.operator_waiters, &GenServer.reply(&1, operator_result(state, key)))
      put_recovery(state, key, %{entry | operator_waiters: [], operator_deadline: nil})
    else
      state
    end
  end

  defp apply_recovery_effect(state, key, :reply_stopped) do
    entry = state.recovery[key]
    Enum.each(entry.stop_waiters, &reply_stop_waiter(&1, stop_waiter_response(&1)))
    put_recovery(state, key, %{entry | stop_waiters: []})
  end

  defp apply_recovery_effect(state, key, {:spawn_worker, task_pid, from}) do
    case Map.get(state.inflight_loads, key) do
      %{task_pid: ^task_pid, worker_pid: nil} = inflight ->
        model_ref = %ModelRef{model_id: elem(key, 0), version: elem(key, 1)}

        case WorkerSupervisor.start_worker(model_ref, manager: self()) do
          {:ok, pid} ->
            monitor = Process.monitor(pid)
            state = put_worker(state, key, model_ref, pid, monitor)
            state = put_in(state, [:recovery, key, :last_worker_pid], pid)
            state = put_in(state, [:inflight_loads, key], %{inflight | worker_pid: pid})
            GenServer.reply(from, {:ok, pid})
            state

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            state
        end

      _stale ->
        GenServer.reply(from, {:error, :worker_unavailable})
        state
    end
  end

  defp apply_recovery_effect(state, key, {:publish_load, task_pid, result}) do
    case Map.get(state.inflight_loads, key) do
      %{task_pid: ^task_pid} = inflight ->
        incarnation = state.recovery[key].policy.incarnation

        Process.send_after(
          self(),
          {:recovery_stable, state.recovery_epoch, key, incarnation},
          600_000
        )

        if Process.alive?(inflight.worker_pid) do
          complete_inflight_load(state, key, inflight, result)
        else
          state = accept_recovery_crash(state, key, inflight.worker_pid)
          complete_inflight_load(state, key, inflight, {:error, :worker_unavailable})
        end

      _stale ->
        state
    end
  end

  defp apply_recovery_effect(state, key, {:schedule, fence, due}) do
    Process.send_after(
      self(),
      {:recovery_timer, state.recovery_epoch, key, fence},
      max(due - recovery_now(), 0)
    )

    state
  end

  defp apply_recovery_effect(state, key, {:load, _fence}) do
    entry = state.recovery[key]
    limit = Node.max_loaded_models()

    if (not state.stopping? and not state.resetting? and entry.request) &&
         (is_nil(limit) or count_capacity_reserved(state) <= limit) do
      request = %{
        entry.request
        | deadline_unix_ms: System.system_time(:millisecond) + Node.worker_load_timeout_ms()
      }

      {:noreply, state} = start_recovery_load(key, request, state)
      state
    else
      entry = Recovery.transition(entry, {:restart_failed, entry.policy.fence}, recovery_now())
      state = put_recovery(state, key, entry)

      if RecoveryCommand.active?(entry.command),
        do: fail_operator_recovery(state, key),
        else: pump_recovery(state, key)
    end
  end

  defp apply_recovery_effect(state, key, :await_cleanup) do
    if state.recovery[key].ownership["phase"] in ["resolved", "operator_terminated"] do
      state
      |> apply_recovery_effect(key, :reply_stopped)
      |> apply_recovery_effect(key, :reply_operator)
    else
      Process.send_after(self(), {:recovery_cleanup, state.recovery_epoch, key}, 1_000)
      state
    end
  end

  defp apply_recovery_effect(state, _key, :checkpoint), do: state
  defp apply_recovery_effect(state, _key, {:cancel, _fence}), do: state

  defp accept_recovery_crash(state, key, pid) do
    case Map.get(state.recovery, key) do
      %{last_worker_pid: ^pid, policy: %{incarnation: incarnation}} = entry
      when not is_nil(incarnation) ->
        entry = %{
          entry
          | last_worker_pid: pid,
            ownership: cleanup_ownership(entry, pid)
        }

        {entry, effects} =
          if entry.operator_waiters != [] do
            {%{
               entry
               | command:
                   Map.merge(entry.command, %{"phase" => "completed", "outcome" => "unavailable"})
             }, [:reply_operator, :await_cleanup]}
          else
            {entry, [:await_cleanup]}
          end

        entry = Recovery.transition(entry, {:crash, incarnation}, recovery_now(), effects)

        put_recovery(state, key, entry) |> pump_recovery(key)

      _already_counted ->
        state
    end
  end

  defp current_load_completion?(entry, inflight, worker_pid) do
    incarnation = inflight[:recovery_incarnation]

    not is_nil(incarnation) and entry.policy.incarnation == incarnation and
      entry.last_worker_pid == worker_pid and entry.ownership["phase"] == "loading" and
      is_nil(entry.pending) and is_nil(entry.desired)
  end

  defp complete_operator_load(entry) do
    if match?(%{"phase" => "loading"}, entry.command) do
      {%{entry | command: Map.merge(entry.command, %{"phase" => "completed", "outcome" => "ok"})},
       [:reply_operator]}
    else
      {entry, []}
    end
  end

  defp fail_operator_recovery(state, key) do
    entry = state.recovery[key]

    if RecoveryCommand.active?(entry.command) do
      command = Map.merge(entry.command, %{"phase" => "completed", "outcome" => "unavailable"})
      entry = %{entry | command: command}

      entry =
        Recovery.transition(entry, :interrupt, recovery_now(), [:reply_operator, :await_cleanup])

      entry =
        if entry.policy.state == :open,
          do: entry,
          else: put_in(entry.policy.state, :recovery_required)

      put_recovery(state, key, entry) |> pump_recovery(key)
    else
      state
    end
  end

  defp recovery_load_failed(state, key, inflight, reason \\ nil) do
    cond do
      is_pid(inflight.worker_pid) and match?({:worker_exited, _}, reason) ->
        accept_recovery_crash(state, key, inflight.worker_pid)

      is_pid(inflight.worker_pid) and not Process.alive?(inflight.worker_pid) ->
        accept_recovery_crash(state, key, inflight.worker_pid)

      true ->
        state = record_recovery_stop(state, key)

        state =
          if inflight.recovery_owner do
            entry = state.recovery[key]

            entry =
              Recovery.transition(entry, {:restart_failed, entry.policy.fence}, recovery_now())

            put_recovery(state, key, entry) |> pump_recovery(key)
          else
            state
          end

        fail_operator_recovery(state, key)
    end
  end

  defp fail_inflight_worker(state, key, pid) do
    case state.inflight_loads[key] do
      %{worker_pid: ^pid} = inflight ->
        Task.Supervisor.terminate_child(@task_supervisor, inflight.task_pid)
        complete_inflight_load(state, key, inflight, {:error, :worker_unavailable})

      _ ->
        state
    end
  end

  defp record_recovery_stop(state, key) do
    case Map.get(state.recovery, key) do
      %{policy: %{incarnation: incarnation}} = entry when not is_nil(incarnation) ->
        record_recovery_worker_stop(state, key, entry, state.workers[key])

      _no_worker ->
        state
    end
  end

  defp record_recovery_worker_stop(state, key, entry, %{pid: pid}) do
    if Process.alive?(pid),
      do: interrupt_recovery(state, key, entry),
      else: accept_recovery_crash(state, key, pid)
  end

  defp record_recovery_worker_stop(state, key, entry, nil),
    do: interrupt_recovery(state, key, entry)

  defp interrupt_recovery(state, key, entry) do
    entry = %{entry | ownership: cleanup_ownership(entry, entry.last_worker_pid)}
    entry = Recovery.transition(entry, :interrupt, recovery_now(), [:await_cleanup])
    put_recovery(state, key, entry) |> pump_recovery(key)
  end

  defp recovery_cleanup_resolved?(state, key) do
    entry = state.recovery[key]
    custody = recovery_custody_module()

    cond do
      Map.has_key?(state.workers, key) or
          recovery_inflight_owns_worker?(Map.get(state.inflight_loads, key)) ->
        false

      entry.prior? ->
        custody.resolve_prior_worker_ownership(key, entry.ownership["custody"]) == :resolved

      is_nil(entry.last_worker_pid) ->
        true

      true ->
        custody.resolve_current(entry.last_worker_pid) == :resolved
    end
  end

  defp recovery_inflight_owns_worker?(nil), do: false

  defp recovery_inflight_owns_worker?(%{worker_pid: nil, recovery_wait?: true}), do: false

  defp recovery_inflight_owns_worker?(_inflight), do: true

  defp start_recovery_load(key, request, state) do
    manager = self()
    models_root = Node.models_root()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        run_load_pipeline(key, request, models_root, manager)
      end)

    inflight = %{
      request: request,
      request_fingerprint: request_fingerprint(request),
      leader_waiter_id: nil,
      started_monotonic_ms: recovery_now(),
      source_scheme: extract_source_scheme(request.artifact_source_uri),
      preload: false,
      backend: Node.worker_backend(),
      task_pid: task.pid,
      task_ref: task.ref,
      waiters: [],
      total_waiter_count: 0,
      replied_waiter_count: 0,
      worker_pid: nil,
      recovery_owner: true
    }

    emit_load_start(key, inflight)

    {:noreply,
     %{
       state
       | inflight_loads: Map.put(state.inflight_loads, key, inflight),
         load_refs: Map.put(state.load_refs, task.ref, key)
     }}
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
          worker_pid: nil,
          recovery_owner: false
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
           {:ok, _path, _outcome} <-
             ModelAcquisition.ensure_cached(acq_request,
               force_full?: Node.force_full_model_verification?()
             ),
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

  defp start_and_load_worker(key, request, _remaining_ms, manager) do
    case GenServer.call(manager, {:recovery_claim_worker, key}, :infinity) do
      {:ok, worker_pid} -> load_claimed_worker(worker_pid, request)
      {:error, _} = err -> err
    end
  end

  defp load_claimed_worker(worker_pid, request) do
    with {:ok, remaining_ms} <- remaining_load_budget(request) do
      ensure_claimed_worker_loaded(worker_pid, request, remaining_ms)
    end
  end

  defp ensure_claimed_worker_loaded(worker_pid, request, remaining_ms) do
    case safe_ensure_loaded(worker_pid, request, remaining_ms) do
      :loaded -> {:ok, worker_pid}
      :already_loaded -> {:ok, worker_pid}
      {:error, _} = err -> err
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
        finalize_successful_load(state, key, inflight, expired, valid)

      {:error, :deadline_exceeded} ->
        if valid == [] do
          # All waiters expired — full cleanup
          state = remove_inflight(state, key, inflight)
          state = cleanup_worker_placement(state, key)

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
        state = cleanup_worker_placement(state, key)

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

  # No valid waiter remains and this was not a preload: the request that started
  # the load has already been abandoned by the controller. Do not mark the worker
  # loaded for a stale completion; clean it up.
  defp finalize_successful_load(state, key, inflight, expired, [])
       when not inflight.preload and not inflight.recovery_owner do
    state = remove_inflight(state, key, inflight)
    state = cleanup_worker_placement(state, key)

    all_replied = inflight.replied_waiter_count + length(expired)

    emit_load_stop(key, inflight, %{
      outcome: :abandoned,
      waiter_count: inflight.total_waiter_count,
      replied_waiter_count: all_replied,
      worker_started: inflight.worker_pid != nil
    })

    reply_waiters(expired, ModelLoadFailure.to_response(:deadline_exceeded))
    state
  end

  defp finalize_successful_load(state, key, inflight, expired, valid) do
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

    reply_loaded_waiters_with_prompt_token_support(state, key, valid)
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

    emit_load_stop(key, inflight, %{
      outcome: :cancelled,
      waiter_count: inflight.total_waiter_count,
      replied_waiter_count: inflight.replied_waiter_count,
      worker_started: inflight.worker_pid != nil,
      cancel_reason: cancel_reason
    })

    state = record_recovery_stop(state, key)

    # Remove inflight tracking
    state = %{
      state
      | inflight_loads: Map.delete(state.inflight_loads, key),
        load_refs: Map.delete(state.load_refs, inflight.task_ref)
    }

    # Clean up partial worker if one was started
    cleanup_worker_placement(state, key)
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
        worker_pid: nil,
        recovery_owner: false,
        recovery_wait?: true
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

        all_replied = inflight.replied_waiter_count + length(inflight.waiters)

        emit_load_stop(key, inflight, %{
          outcome: :cancelled,
          waiter_count: inflight.total_waiter_count,
          replied_waiter_count: all_replied,
          worker_started: inflight.worker_pid != nil,
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

        cleanup_worker_placement(state, key)
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
        next_state =
          state
          |> finalize_worker_removal(key, pid, monitor_ref)
          |> maybe_cleanup_unloaded_requests(key, request.force)

        {%Ack{ok: true, message: "unload accepted"}, next_state}

      {:error, :worker_unavailable} ->
        next_state =
          state
          |> finalize_worker_removal(key, pid, monitor_ref)
          |> cleanup_worker_unavailable(key, :worker_unavailable)

        {%Ack{ok: true, message: "unload accepted"}, next_state}

      {:error, reason} ->
        next_state =
          state
          |> finalize_worker_removal(key, pid, monitor_ref)
          |> maybe_cleanup_unloaded_requests(key, request.force)

        {%Ack{ok: false, message: "unload failed: #{inspect(reason)}"}, next_state}
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

  # Terminate the worker placement for `key` if one exists. This is used for
  # failed loads, but also for loads that *succeeded* yet have no remaining
  # valid waiters — runtime residency requires an active owner, so we free the
  # in-memory worker rather than keeping a model loaded for an abandoned request.
  defp cleanup_worker_placement(state, key) do
    state = record_recovery_stop(state, key)

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
      request_limit: nil,
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

  defp put_cached_worker_request_limit(state, key, request_limit)
       when is_integer(request_limit) and request_limit > 0 do
    if Map.has_key?(state.workers, key) do
      put_in(state, [:workers, key, :request_limit], request_limit)
    else
      state
    end
  end

  defp put_cached_worker_request_limit(state, _key, _request_limit), do: state

  defp cacheable_request_limit_from_status_result({:ok, %{health_code: "worker_status_error"}}),
    do: nil

  defp cacheable_request_limit_from_status_result({:ok, %{max_concurrency: value}})
       when is_integer(value) and value > 0 do
    value
  end

  defp cacheable_request_limit_from_status_result(_status_result), do: nil

  defp put_worker_request_limits(state, worker_request_limits) do
    Enum.reduce(worker_request_limits, state, fn {key, request_limit}, acc ->
      put_cached_worker_request_limit(acc, key, request_limit)
    end)
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

  defp finalize_worker_removal(state, key, pid, monitor_ref) do
    _ = DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
    drop_worker(state, key, monitor_ref)
  end

  defp cleanup_reason_for_worker_exit(:runtime_worker_unavailable), do: :worker_unavailable
  defp cleanup_reason_for_worker_exit(_reason), do: :worker_down

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

  defp score_prefix_cache_for_state(
         %ScorePrefixCacheRequest{model_ref: %ModelRef{} = model_ref} = request,
         state
       ) do
    key = model_key(model_ref.model_id, model_ref.version)

    case Map.get(state.workers, key) do
      %{placement_state: :PLACEMENT_STATE_LOADED, pid: pid} ->
        score_prefix_cache_for_worker(pid, request)

      _other ->
        score_prefix_cache_response("model_not_loaded", "model is not loaded")
    end
  end

  defp score_prefix_cache_for_state(_request, _state) do
    score_prefix_cache_response("invalid_request", "model_ref is required")
  end

  defp score_prefix_cache_for_worker(pid, request) do
    timeout_ms = score_prefix_cache_timeout_ms(request)

    response =
      if timeout_ms <= 0 do
        score_prefix_cache_response("timeout", "score request timed out")
      else
        safe_score_prefix_cache(pid, request, timeout_ms)
      end

    normalize_score_prefix_cache_response(response)
  end

  defp safe_score_prefix_cache(pid, request, timeout_ms) do
    safe_worker_call(fn ->
      WorkerProcess.score_prefix_cache(pid, request,
        timeout: score_prefix_cache_call_timeout(timeout_ms),
        timeout_ms: timeout_ms
      )
    end)
  end

  defp normalize_score_prefix_cache_response(%ScorePrefixCacheResponse{} = response),
    do: ScoreResponse.normalize(response)

  defp normalize_score_prefix_cache_response({:error, :worker_unavailable}) do
    score_prefix_cache_response("unavailable", "worker process became unavailable")
  end

  defp normalize_score_prefix_cache_response({:error, reason}) do
    score_prefix_cache_response("error", "worker score_prefix_cache failed: #{inspect(reason)}")
  end

  defp normalize_score_prefix_cache_response(_other) do
    score_prefix_cache_response("error", "worker score_prefix_cache returned malformed response")
  end

  defp score_prefix_cache_response(status_code, status_message) do
    ScoreResponse.response(status_code, status_message)
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

  defp model_at_request_capacity?(active_requests, key, request_limit) do
    active_request_count_for_model(active_requests, key) >= request_limit
  end

  defp node_at_request_capacity?(active_requests, request_limit) do
    map_size(active_requests) >= request_limit
  end

  defp node_max_concurrency(worker_request_limits) do
    case Map.values(worker_request_limits) do
      [] -> Node.effective_worker_request_limit()
      limits -> Enum.min(limits)
    end
  end

  defp loaded_worker_request_limits(state) do
    state
    |> loaded_workers()
    |> Map.new(fn {key, entry} -> {key, worker_request_limit(entry)} end)
  end

  defp worker_request_limit(%{request_limit: request_limit})
       when is_integer(request_limit) and request_limit > 0 do
    request_limit
  end

  defp worker_request_limit(%{pid: pid}) when is_pid(pid) do
    request_limit_for_worker(pid)
  end

  defp request_limit_for_worker(pid, timeout_ms \\ 1_000) do
    pid
    |> WorkerProcess.status(timeout: timeout_ms)
    |> request_limit_from_status_result()
  end

  defp request_limit_from_status_result({:ok, %{max_concurrency: value}})
       when is_integer(value) and value > 0 do
    value
  end

  defp request_limit_from_status_result(_status_result) do
    fallback_worker_request_limit()
  end

  defp fallback_worker_request_limit do
    case Node.runtime_adapter_impl() do
      Orchard.Node.WorkerRuntimeAdapter -> 1
      _other -> Node.effective_worker_request_limit()
    end
  end

  # -- Response helpers ------------------------------------------------------

  defp status_response(state) do
    tool_snapshot = ToolCapabilityCatalog.snapshot()

    {runtime_health, runtime_memory_budgets, runtime_prefix_cache_statuses,
     supports_prompt_token_ids, worker_request_limits} = runtime_health_and_memory_budgets(state)

    response = %StatusResponse{
      worker_state: worker_state(state),
      loaded_models: loaded_models(state),
      active_request_count: map_size(state.active_requests),
      max_concurrency: node_max_concurrency(worker_request_limits),
      node_metadata: build_node_metadata(),
      runtime_health: runtime_health,
      hosted_tool_capabilities: tool_snapshot.capabilities,
      hosted_tool_readiness: tool_snapshot.readiness,
      runtime_memory_budgets: runtime_memory_budgets,
      runtime_prefix_cache_statuses: runtime_prefix_cache_statuses,
      worker_crash_counters: worker_crash_counters(state),
      worker_recovery_epoch: state.recovery_epoch,
      supports_prompt_token_ids: supports_prompt_token_ids,
      runtime_model_placements: runtime_model_placements(state, worker_request_limits)
    }

    {response, put_worker_request_limits(state, worker_request_limits)}
  end

  defp worker_crash_counters(state) do
    state.worker_crashes
    |> Enum.sort_by(fn {model_id, _count} -> model_id end)
    |> Enum.take(@worker_crash_model_limit)
    |> Enum.map(fn {model_id, count} ->
      %WorkerCrashCounter{
        model_id: model_id,
        count: count,
        counter_version: state.worker_crash_counter_version
      }
    end)
  end

  defp build_node_metadata do
    %RuntimeNodeMetadata{
      node_id: Node.node_id(),
      display_name: Node.display_name(),
      hostname: Node.hostname(),
      agent_version: Node.agent_version(),
      listen_host: Node.listen_host_string(),
      listen_port: Node.listen_port() || 0,
      worker_backend: Node.worker_backend()
    }
  end

  defp maybe_runtime_memory_budget(%ModelRef{} = model_ref, status_result) do
    case status_result do
      {:ok, %{memory_budget: budget}} when is_map(budget) ->
        [runtime_memory_budget(model_ref, budget)]

      _other ->
        []
    end
  end

  defp maybe_runtime_prefix_cache_status(%ModelRef{} = model_ref, status_result) do
    case status_result do
      {:ok, status} when is_map(status) ->
        if Map.has_key?(status, :prefix_cache_status) do
          build_runtime_prefix_cache_status(model_ref, Map.get(status, :prefix_cache_status))
        else
          []
        end

      _other ->
        []
    end
  end

  defp build_runtime_prefix_cache_status(_model_ref, nil), do: []

  defp build_runtime_prefix_cache_status(%ModelRef{} = model_ref, prefix_cache_status)
       when is_map(prefix_cache_status) do
    [runtime_prefix_cache_status(model_ref, prefix_cache_status)]
  end

  defp build_runtime_prefix_cache_status(%ModelRef{} = model_ref, _invalid_status) do
    [invalid_runtime_prefix_cache_status(model_ref, %{})]
  end

  defp loaded_workers(state) do
    state.workers
    |> Enum.filter(fn {_key, entry} -> entry.placement_state == :PLACEMENT_STATE_LOADED end)
    |> Enum.sort_by(fn {{model_id, version}, _} -> {model_id, version} end)
  end

  defp runtime_model_placements(state, worker_request_limits) do
    Enum.map(runtime_model_placement_keys(state), fn {model_id, version} = key ->
      loaded? = match?(%{placement_state: :PLACEMENT_STATE_LOADED}, state.workers[key])

      %RuntimeModelPlacement{
        model_ref: %ModelRef{model_id: model_id, version: version},
        active_request_count: active_request_count_for_model(state.active_requests, key),
        max_concurrency:
          if(loaded?,
            do: Map.get(worker_request_limits, key, fallback_worker_request_limit()),
            else: 0
          ),
        worker_recovery_json: Jason.encode!(recovery_projection(state, key))
      }
    end)
  end

  defp runtime_model_placement_keys(state) do
    {loaded, other_workers} =
      state.workers
      |> Map.keys()
      |> Enum.sort()
      |> Enum.split_with(&match?(%{placement_state: :PLACEMENT_STATE_LOADED}, state.workers[&1]))

    recovery_only =
      state.recovery
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(state.workers, &1))
      |> Enum.sort()

    Enum.take(loaded ++ other_workers ++ recovery_only, @runtime_model_placement_limit)
  end

  defp runtime_memory_budget(%ModelRef{} = model_ref, budget) do
    if invalid_memory_budget_numeric_payload?(budget) do
      invalid_runtime_memory_budget(model_ref, budget)
    else
      %RuntimeMemoryBudget{
        model_ref: model_ref,
        mode: budget_string(budget[:mode]),
        budget_available: budget_bool(budget[:budget_available]),
        headroom_available: budget_bool(budget[:headroom_available]),
        status_code: budget_string(budget[:status_code]),
        status_message: budget_string(budget[:status_message]),
        source: budget_string(budget[:source]),
        max_recommended_working_set_size_bytes:
          budget_uint64(budget[:max_recommended_working_set_size_bytes]),
        utilization: budget_float(budget[:utilization]),
        target_working_set_bytes: budget_uint64(budget[:target_working_set_bytes]),
        overhead_bytes: budget_uint64(budget[:overhead_bytes]),
        resident_memory_bytes: budget_uint64(budget[:resident_memory_bytes]),
        estimated_headroom_bytes: budget_uint64(budget[:estimated_headroom_bytes]),
        kv_cache_bytes_per_token: budget_uint64(budget[:kv_cache_bytes_per_token]),
        prefill_workspace_bytes_per_token:
          budget_uint64(budget[:prefill_workspace_bytes_per_token]),
        recommended_context_tokens: budget_uint64(budget[:recommended_context_tokens])
      }
    end
  end

  defp budget_bool(value), do: value == true

  defp budget_string(value) when is_binary(value), do: value
  defp budget_string(_value), do: ""

  defp invalid_memory_budget_numeric_payload?(budget) do
    claims_usable = memory_budget_claims_usable?(budget)

    Enum.any?(@memory_budget_uint64_fields, fn field ->
      invalid_budget_uint64?(budget, field, claims_usable)
    end) or
      Enum.any?(@memory_budget_float_fields, fn field ->
        invalid_budget_float?(budget, field, claims_usable)
      end)
  end

  defp memory_budget_claims_usable?(budget) do
    budget_string(budget[:status_code]) == "ok" or
      budget_bool(budget[:budget_available]) or
      budget_bool(budget[:headroom_available])
  end

  defp invalid_budget_uint64?(budget, field, claims_usable) do
    case Map.fetch(budget, field) do
      {:ok, value} -> not valid_budget_uint64?(value)
      :error -> claims_usable
    end
  end

  defp invalid_budget_float?(budget, field, claims_usable) do
    case Map.fetch(budget, field) do
      {:ok, value} -> not valid_budget_float?(value)
      :error -> claims_usable
    end
  end

  defp invalid_runtime_memory_budget(%ModelRef{} = model_ref, budget) do
    %RuntimeMemoryBudget{
      model_ref: model_ref,
      mode: "observe",
      budget_available: false,
      headroom_available: false,
      status_code: "invalid_status",
      status_message: @invalid_memory_budget_numeric_message,
      source: budget_string(budget[:source]),
      max_recommended_working_set_size_bytes: 0,
      utilization: 0.0,
      target_working_set_bytes: 0,
      overhead_bytes: 0,
      resident_memory_bytes: 0,
      estimated_headroom_bytes: 0,
      kv_cache_bytes_per_token: 0,
      prefill_workspace_bytes_per_token: 0,
      recommended_context_tokens: 0
    }
  end

  defp runtime_prefix_cache_status(%ModelRef{} = model_ref, prefix_cache_status) do
    if invalid_prefix_cache_numeric_payload?(prefix_cache_status) do
      invalid_runtime_prefix_cache_status(model_ref, prefix_cache_status)
    else
      %RuntimePrefixCacheStatus{
        model_ref: model_ref,
        implementation: budget_string(prefix_cache_status[:implementation]),
        enabled: budget_bool(prefix_cache_status[:enabled]),
        entry_count: prefix_cache_uint32(prefix_cache_status[:entry_count]),
        total_bytes: budget_uint64(prefix_cache_status[:total_bytes]),
        hits: budget_uint64(prefix_cache_status[:hits]),
        misses: budget_uint64(prefix_cache_status[:misses]),
        failures: budget_uint64(prefix_cache_status[:failures]),
        stores: budget_uint64(prefix_cache_status[:stores]),
        evictions: budget_uint64(prefix_cache_status[:evictions]),
        configured_max_entries: prefix_cache_uint32(prefix_cache_status[:configured_max_entries]),
        configured_max_bytes: budget_uint64(prefix_cache_status[:configured_max_bytes]),
        status_code: budget_string(prefix_cache_status[:status_code]),
        status_message: budget_string(prefix_cache_status[:status_message]),
        session_started_unix_ms: budget_uint64(prefix_cache_status[:session_started_unix_ms]),
        prefix_cache_fingerprints: prefix_cache_fingerprints(prefix_cache_status)
      }
    end
  end

  defp invalid_prefix_cache_numeric_payload?(prefix_cache_status) do
    Enum.any?(@prefix_cache_uint32_fields, fn field ->
      invalid_prefix_cache_uint32?(prefix_cache_status, field)
    end) or
      Enum.any?(@prefix_cache_uint64_fields, fn field ->
        invalid_prefix_cache_uint64?(prefix_cache_status, field)
      end)
  end

  defp invalid_prefix_cache_uint32?(prefix_cache_status, field) do
    case Map.fetch(prefix_cache_status, field) do
      {:ok, value} -> not valid_prefix_cache_uint32?(value)
      :error -> false
    end
  end

  defp invalid_prefix_cache_uint64?(prefix_cache_status, field) do
    case Map.fetch(prefix_cache_status, field) do
      {:ok, value} -> not valid_budget_uint64?(value)
      :error -> false
    end
  end

  defp invalid_runtime_prefix_cache_status(%ModelRef{} = model_ref, prefix_cache_status) do
    %RuntimePrefixCacheStatus{
      model_ref: model_ref,
      implementation: budget_string(prefix_cache_status[:implementation]),
      enabled: budget_bool(prefix_cache_status[:enabled]),
      entry_count: 0,
      total_bytes: 0,
      hits: 0,
      misses: 0,
      failures: 0,
      stores: 0,
      evictions: 0,
      configured_max_entries: 0,
      configured_max_bytes: 0,
      status_code: "invalid_status",
      status_message: @invalid_prefix_cache_numeric_message,
      session_started_unix_ms: 0,
      prefix_cache_fingerprints: []
    }
  end

  defp prefix_cache_fingerprints(prefix_cache_status) do
    prefix_cache_status
    |> Map.get(:prefix_cache_fingerprints, [])
    |> normalize_prefix_cache_fingerprints()
  end

  defp normalize_prefix_cache_fingerprints(fingerprints) when is_list(fingerprints) do
    {_seen, ordered_fingerprints, _count} =
      Enum.reduce_while(fingerprints, {MapSet.new(), [], 0}, fn fingerprint, {seen, acc, count} ->
        cond do
          count >= @prefix_cache_fingerprint_cap ->
            {:halt, {seen, acc, count}}

          not valid_prefix_cache_fingerprint?(fingerprint) ->
            {:cont, {seen, acc, count}}

          MapSet.member?(seen, fingerprint) ->
            {:cont, {seen, acc, count}}

          true ->
            {:cont, {MapSet.put(seen, fingerprint), [fingerprint | acc], count + 1}}
        end
      end)

    Enum.reverse(ordered_fingerprints)
  end

  defp normalize_prefix_cache_fingerprints(_fingerprints), do: []

  defp valid_prefix_cache_fingerprint?(fingerprint) when is_binary(fingerprint) do
    Regex.match?(@prefix_cache_fingerprint_pattern, fingerprint)
  end

  defp valid_prefix_cache_fingerprint?(_fingerprint), do: false

  defp valid_prefix_cache_uint32?(value) do
    is_integer(value) and value >= 0 and value <= @uint32_max
  end

  defp prefix_cache_uint32(value)
       when is_integer(value) and value >= 0 and value <= @uint32_max,
       do: value

  defp prefix_cache_uint32(_value), do: 0

  defp valid_budget_uint64?(value) do
    is_integer(value) and value >= 0 and value <= @uint64_max
  end

  defp budget_uint64(value)
       when is_integer(value) and value >= 0 and value <= @uint64_max,
       do: value

  defp budget_uint64(_value), do: 0

  defp valid_budget_float?(value) when is_integer(value) and value >= 0 do
    float = value / 1
    finite_float?(float) and float >= 0.0
  rescue
    ArithmeticError -> false
  end

  defp valid_budget_float?(value) when is_float(value) do
    finite_float?(value) and value >= 0.0
  end

  defp valid_budget_float?(_value), do: false

  defp budget_float(value) when is_integer(value) and value >= 0 do
    float = value / 1

    if finite_float?(float), do: float, else: 0.0
  rescue
    ArithmeticError -> 0.0
  end

  defp budget_float(value) when is_float(value) do
    if finite_float?(value) and value >= 0.0, do: value, else: 0.0
  end

  defp budget_float(_value), do: 0.0

  defp finite_float?(value) when is_float(value) do
    <<bits::unsigned-64>> = <<value::float-64>>
    exponent = band(bsr(bits, 52), 0x7FF)
    exponent != 0x7FF
  end

  # Health aggregation algorithm:
  # 1. Inflight loads → degraded/starting (no worker status probes)
  # 2. Workers in LOADING state → degraded/starting (no worker status probes)
  # 3. No workers → healthy
  # 4. Otherwise probe each loaded worker and keep the first unhealthy result
  # 5. Runtime memory budgets and prefix-cache statuses are collected
  #    opportunistically from those same worker probes.
  defp runtime_health_and_memory_budgets(state) do
    cond do
      map_size(state.inflight_loads) > 0 ->
        first_inflight = first_sorted_model_ref(state.inflight_loads)

        {%RuntimeHealth{
           ready: false,
           health_code: "starting",
           health_message: "model load in progress",
           affected_model: first_inflight
         }, [], [], false, loaded_worker_request_limits(state)}

      has_loading_worker?(state) ->
        loading_ref = first_loading_worker_ref(state)

        {%RuntimeHealth{
           ready: false,
           health_code: "starting",
           health_message: "model load in progress",
           affected_model: loading_ref
         }, [], [], false, loaded_worker_request_limits(state)}

      map_size(state.workers) == 0 ->
        {%RuntimeHealth{ready: true, health_code: "", health_message: ""}, [], [], false, %{}}

      true ->
        probe_workers_health_and_memory_budgets(loaded_workers(state))
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
  defp probe_workers_health_and_memory_budgets(loaded_workers) do
    support_state = %{seen_success?: false, all_true?: true}

    {health, runtime_memory_budgets, runtime_prefix_cache_statuses, support_state,
     worker_request_limits} =
      Enum.reduce(loaded_workers, {nil, [], [], support_state, %{}}, fn {key, entry},
                                                                        {health, budgets,
                                                                         prefix_cache_statuses,
                                                                         support_state,
                                                                         worker_request_limits} ->
        status_result = WorkerProcess.status(entry.pid, timeout: 1_000)

        updated_budgets = budgets ++ maybe_runtime_memory_budget(entry.model_ref, status_result)

        updated_prefix_cache_statuses =
          prefix_cache_statuses ++
            maybe_runtime_prefix_cache_status(entry.model_ref, status_result)

        next_health = health || health_from_status_result(entry.model_ref, status_result)
        support_state = aggregate_supports_prompt_token_ids(support_state, status_result)
        request_limit = request_limit_from_status_result(status_result)
        worker_request_limits = Map.put(worker_request_limits, key, request_limit)

        {next_health, updated_budgets, updated_prefix_cache_statuses, support_state,
         worker_request_limits}
      end)

    {health || %RuntimeHealth{ready: true, health_code: "", health_message: ""},
     runtime_memory_budgets, runtime_prefix_cache_statuses,
     supports_prompt_token_ids_value(support_state), worker_request_limits}
  end

  defp supports_prompt_token_ids_value(%{seen_success?: true, all_true?: true}), do: true
  defp supports_prompt_token_ids_value(_support_state), do: false

  defp aggregate_supports_prompt_token_ids(
         support_state,
         {:ok, %{health_code: "worker_status_error"}}
       ) do
    %{support_state | all_true?: false}
  end

  defp aggregate_supports_prompt_token_ids(
         support_state,
         {:ok, %{supports_prompt_token_ids: true}}
       ) do
    %{support_state | seen_success?: true}
  end

  defp aggregate_supports_prompt_token_ids(support_state, {:ok, _status}) do
    %{support_state | seen_success?: true, all_true?: false}
  end

  defp aggregate_supports_prompt_token_ids(support_state, {:error, _reason}) do
    %{support_state | all_true?: false}
  end

  defp reply_loaded_waiters_with_prompt_token_support(state, key, waiters) do
    entry = Map.get(state.workers, key)

    {_support_cache, request_limit} =
      waiters
      |> waiters_by_deadline()
      |> Enum.reduce({:not_probed, nil}, fn waiter, {support_cache, request_limit} ->
        reply_loaded_waiter_with_support_cache(
          waiter,
          support_cache,
          request_limit,
          entry,
          state,
          key
        )
      end)

    put_cached_worker_request_limit(state, key, request_limit)
  end

  defp waiters_by_deadline(waiters) do
    waiters
    |> Enum.with_index()
    |> Enum.sort_by(fn {waiter, index} -> {waiter.deadline_unix_ms, index} end)
    |> Enum.map(fn {waiter, _index} -> waiter end)
  end

  defp reply_loaded_waiter_with_support_cache(
         waiter,
         support_cache,
         request_limit,
         entry,
         state,
         key
       ) do
    cond do
      deadline_expired?(waiter.deadline_unix_ms) ->
        reply_deadline_exceeded(waiter)
        {support_cache, request_limit}

      support_cache?(support_cache) ->
        {:ok, supports_prompt_token_ids?} = support_cache

        reply_loaded_waiter_if_valid(
          waiter,
          supports_prompt_token_ids?,
          placement_capacity(state, key, entry, request_limit)
        )

        {support_cache, request_limit}

      true ->
        probe_and_reply_loaded_waiter(waiter, entry, state, key, request_limit)
    end
  end

  defp support_cache?({:ok, _supports_prompt_token_ids?}), do: true
  defp support_cache?(_support_cache), do: false

  defp probe_and_reply_loaded_waiter(waiter, entry, state, key, request_limit) do
    case probe_worker_prompt_token_ids_support_status(entry, waiter.deadline_unix_ms) do
      {{:ok, supports_prompt_token_ids?} = next_cache, status_result} ->
        next_request_limit =
          request_limit || cacheable_request_limit_from_status_result(status_result)

        reply_loaded_waiter_if_valid(
          waiter,
          supports_prompt_token_ids?,
          placement_capacity(state, key, entry, next_request_limit)
        )

        {next_cache, next_request_limit}

      {{:error, :deadline_exceeded}, status_result} ->
        reply_deadline_exceeded(waiter)

        {:not_probed, request_limit || cacheable_request_limit_from_status_result(status_result)}
    end
  end

  defp reply_deadline_exceeded(waiter) do
    GenServer.reply(waiter.from, ModelLoadFailure.to_response(:deadline_exceeded))
  end

  defp reply_loaded_waiter_if_valid(waiter, supports_prompt_token_ids?, placement_capacity) do
    if deadline_expired?(waiter.deadline_unix_ms) do
      GenServer.reply(waiter.from, ModelLoadFailure.to_response(:deadline_exceeded))
    else
      GenServer.reply(
        waiter.from,
        loaded_response(false, supports_prompt_token_ids?, placement_capacity)
      )
    end
  end

  defp loaded_response(already_loaded?, supports_prompt_token_ids?, placement_capacity) do
    %EnsureModelLoadedResponse{
      already_loaded: already_loaded?,
      placement_state: :PLACEMENT_STATE_LOADED,
      worker_supports_prompt_token_ids: supports_prompt_token_ids?,
      placement_capacity: placement_capacity
    }
  end

  defp placement_capacity(state, key, %{model_ref: model_ref}, request_limit)
       when is_integer(request_limit) and request_limit > 0 do
    %RuntimeModelPlacement{
      model_ref: model_ref,
      active_request_count: active_request_count_for_model(state.active_requests, key),
      max_concurrency: request_limit
    }
  end

  defp placement_capacity(_state, _key, _entry, _request_limit), do: nil

  defp probe_worker_prompt_token_ids_support_status(nil, _deadline_unix_ms),
    do: {{:ok, false}, nil}

  defp probe_worker_prompt_token_ids_support_status(entry, deadline_unix_ms) do
    case remaining_probe_budget_ms(deadline_unix_ms) do
      {:ok, remaining_ms} ->
        timeout_ms = min(remaining_ms, @prompt_token_ids_support_probe_max_timeout_ms)

        status_result = WorkerProcess.status(entry.pid, timeout: timeout_ms)

        {normalize_prompt_token_ids_support_status(status_result, deadline_unix_ms),
         status_result}

      {:error, :deadline_exceeded} ->
        {{:error, :deadline_exceeded}, nil}
    end
  end

  defp normalize_prompt_token_ids_support_status(status_result, deadline_unix_ms) do
    cond do
      deadline_expired?(deadline_unix_ms) ->
        {:error, :deadline_exceeded}

      match?({:ok, %{health_code: "worker_status_error"}}, status_result) ->
        {:ok, false}

      match?({:ok, %{supports_prompt_token_ids: true}}, status_result) ->
        {:ok, true}

      true ->
        {:ok, false}
    end
  end

  defp remaining_probe_budget_ms(deadline_unix_ms) do
    remaining_ms = deadline_unix_ms - System.system_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :deadline_exceeded}
    else
      {:ok, remaining_ms}
    end
  end

  defp deadline_expired?(deadline_unix_ms),
    do: deadline_unix_ms <= System.system_time(:millisecond)

  defp health_from_status_result(_model_ref, {:ok, %{ready: true}}), do: nil

  defp health_from_status_result(model_ref, {:ok, %{ready: false} = status}) do
    %RuntimeHealth{
      ready: false,
      health_code: status[:health_code] || "worker_unhealthy",
      health_message: status[:health_message] || "",
      affected_model: model_ref
    }
  end

  defp health_from_status_result(model_ref, {:error, _reason}) do
    %RuntimeHealth{
      ready: false,
      health_code: "worker_status_error",
      health_message: "worker status request failed",
      affected_model: model_ref
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

  defp score_prefix_cache_timeout_ms(%ScorePrefixCacheRequest{deadline_unix_ms: deadline})
       when is_integer(deadline) and deadline > 0 do
    max(deadline - System.system_time(:millisecond), 0)
  end

  defp score_prefix_cache_timeout_ms(_request), do: @score_prefix_cache_default_timeout_ms

  defp score_prefix_cache_call_timeout(timeout_ms) do
    max(timeout_ms + @score_prefix_cache_local_timeout_grace_ms, 1)
  end

  defp score_prefix_cache_manager_call_timeout(timeout_ms) do
    score_prefix_cache_call_timeout(timeout_ms) + @score_prefix_cache_local_timeout_grace_ms
  end

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
      load_refs: %{},
      worker_crash_counter_version: new_worker_crash_counter_version(),
      worker_crashes: %{},
      recovery_epoch: new_worker_crash_counter_version(),
      recovery: %{},
      recovery_hydrations: %{},
      recovery_io_refs: %{},
      recovery_read_retry_at: %{},
      eviction_continuations: %{},
      stopping?: false,
      resetting?: false
    }
  end

  defp new_worker_crash_counter_version do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp increment_worker_crash(state, {model_id, _version}) do
    cond do
      Map.has_key?(state.worker_crashes, model_id) ->
        update_in(state, [:worker_crashes, model_id], &min(&1 + 1, @uint64_max))

      map_size(state.worker_crashes) < @worker_crash_model_limit ->
        put_in(state, [:worker_crashes, model_id], 1)

      true ->
        state
    end
  end

  # -- Eviction helpers ------------------------------------------------------

  # Evicts synchronously before the async load task starts. If the incoming
  # load subsequently fails (bad hash, runtime error, etc.), the evicted model
  # is NOT restored — the slot will be reclaimed by the next successful load.
  # This is intentional: deferring eviction until after acquisition would
  # require cross-process coordination between the async load task and the
  # GenServer's capacity state.
  defp maybe_evict_before_load(state, target_key, request, from) do
    case Node.max_loaded_models() do
      nil ->
        {:ok, state}

      limit ->
        reserved_count = count_capacity_reserved(state)

        if reserved_count < limit do
          {:ok, state}
        else
          do_evict(state, target_key, limit, reserved_count, request, from)
        end
    end
  end

  defp do_evict(state, target_key, limit, reserved_count, request, from) do
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
      {:ok, victim_key, _victim_entry} ->
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

        ref = make_ref()
        continuation = %{request: request, from: from, meta: eviction_meta, started: start_time}

        case handle_call({:unload_model, evict_request}, {self(), ref}, state) do
          {:noreply, next_state} ->
            {:deferred, put_in(next_state, [:eviction_continuations, ref], continuation)}

          {:reply, response, next_state} ->
            send(self(), {ref, response})
            {:deferred, put_in(next_state, [:eviction_continuations, ref], continuation)}
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
          is_nil(Recovery.refusal(state.recovery[key])) and
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

  defp finish_eviction(state, continuation, %Ack{ok: true}) do
    emit_eviction_stop(
      continuation.meta,
      System.monotonic_time(:millisecond) - continuation.started
    )

    case handle_call({:ensure_model_loaded, continuation.request}, continuation.from, state) do
      {:reply, response, next} ->
        GenServer.reply(continuation.from, response)
        {:noreply, next}

      {:noreply, next} ->
        {:noreply, next}
    end
  end

  defp finish_eviction(state, continuation, _failure) do
    emit_eviction_exception(
      continuation.meta,
      System.monotonic_time(:millisecond) - continuation.started,
      :model_capacity_exhausted
    )

    GenServer.reply(continuation.from, ModelLoadFailure.to_response(:model_capacity_exhausted))
    {:noreply, state}
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

    recovery_keys =
      state.recovery
      |> Enum.filter(fn {_key, entry} ->
        entry.policy.state in [:backoff, :restarting] or
          entry.ownership["phase"] not in ["resolved", "operator_terminated"]
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    inflight_keys |> MapSet.union(worker_keys) |> MapSet.union(recovery_keys) |> MapSet.size()
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
