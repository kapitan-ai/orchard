defmodule Orchard.Inference.RequestOrchestrator do
  @moduledoc """
  Executes the shared durable request lifecycle for prepared canonical requests.

  Once a request has been persisted and validated, scheduler and dispatch
  orchestration crashes are converted into durable failed terminal outcomes so
  requests do not remain active without a runtime owner.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest, GenerationParams}
  alias Orchard.Dispatch.{AttemptOutcome, RequestDispatcher}
  alias Orchard.DomainMetrics
  alias Orchard.Inference
  alias Orchard.Metrics.{InferenceAttemptProjection, Status}

  alias Orchard.Inference.{
    AdmissionPolicy,
    AttemptBreakerAttribution,
    AttemptContext,
    AttemptRetryClassifier,
    CacheAffinity,
    CanonicalRequestSerializer,
    ChatError,
    EventUsage,
    ModelLoadFailure,
    QueueManager,
    RequestDeadline,
    ToolCallAccumulator,
    ToolExecutionSemantics,
    ToolingValidation
  }

  alias Orchard.Governance
  alias Orchard.InferenceEvent
  alias Orchard.Nodes
  alias Orchard.Nodes.ExclusionSet
  alias Orchard.Requests

  alias Orchard.Requests.{
    CapturePolicy,
    Idempotency,
    InferenceAttemptFailure,
    InferenceAttemptResult,
    Request,
    RequestServer,
    RequestStepEvent
  }

  alias Orchard.Runtime.{MemoryBudget, PrefixCacheScore, PrefixCacheStatus}
  alias Orchard.RuntimeEndpoint.Target
  alias Orchard.SentryContext

  @type event_handler ::
          (Ecto.UUID.t(), InferenceEvent.t() ->
             :ok | :cancel | {:error, :serializer_failed})
  @type success_persistence ::
          (CanonicalRequest.t(), [InferenceEvent.t()] -> map())
  @type step_event_appender ::
          (struct() | Ecto.UUID.t(), [RequestStepEvent.t() | map()] ->
             {:ok, [RequestStepEvent.t()]} | {:error, term()})
  @type terminal_persister ::
          (struct() | Ecto.UUID.t(), map(), [RequestStepEvent.t() | map()] ->
             {:ok, struct()} | {:error, term()})

  @type execute_result ::
          {:ok, CanonicalRequest.t(), [InferenceEvent.t()]}
          | {:replay, struct()}
          | {:error, term()}

  @spec execute(CanonicalRequest.t(), map(), keyword()) :: execute_result()
  def execute(%CanonicalRequest{} = canonical, model, opts \\ []) do
    previous_started_at = Process.put({__MODULE__, :metrics_started_at}, System.monotonic_time())

    try do
      case do_execute(canonical, model, opts) do
        # Keep the existing execute/3 contract for direct callers; persistence
        # and scheduling use the resolved value internally.
        {:ok, _resolved_canonical, events} -> {:ok, canonical, events}
        result -> result
      end
    after
      restore_metrics_started_at(previous_started_at)
    end
  end

  @doc false
  @spec validate_scheduler_selection(map(), [Ecto.UUID.t()]) ::
          :ok | {:error, {:dispatch_failed, :identity_unresolved}}
  def validate_scheduler_selection(_schedule, []), do: :ok

  def validate_scheduler_selection(schedule, exclude_node_ids)
      when is_map(schedule) and is_list(exclude_node_ids) do
    with {:ok, selected_node_id} <- Ecto.UUID.cast(map_value(schedule, :node_id)),
         :ok <- validate_selected_target_identity(schedule, selected_node_id),
         {:ok, excluded_node_ids} <- ExclusionSet.canonicalize(exclude_node_ids),
         false <- MapSet.member?(excluded_node_ids, selected_node_id) do
      :ok
    else
      _identity_unresolved -> {:error, {:dispatch_failed, :identity_unresolved}}
    end
  end

  defp do_execute(canonical, model, opts) do
    event_handler = Keyword.get(opts, :event_handler)
    caller = Keyword.get(opts, :caller, self())
    success_persistence = Keyword.get(opts, :success_persistence)
    idempotency = Keyword.get(opts, :idempotency)

    step_event_appender =
      Keyword.get(opts, :step_event_appender, &Requests.append_request_step_events/2)

    terminal_persister =
      Keyword.get(opts, :terminal_persister, &Requests.mark_terminal_with_step_events/3)

    with :ok <- validate_resolved_tooling(canonical),
         :ok <- put_request_validated_context(canonical),
         {:ok, db_request, canonical} <- persist_request(canonical, model, idempotency) do
      put_request_persisted_context(db_request, canonical)

      DomainMetrics.input_accounted(
        canonical.tenant_id,
        canonical.model_ref.model_id,
        canonical.input_token_count
      )

      start_and_dispatch(
        db_request,
        canonical,
        model,
        caller,
        event_handler,
        success_persistence,
        step_event_appender,
        terminal_persister
      )
    end
  end

  defp start_and_dispatch(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence,
         step_event_appender,
         terminal_persister
       ) do
    case start_fsm(db_request) do
      {:ok, _pid} ->
        run_dispatch_pipeline(
          db_request,
          canonical,
          model,
          caller,
          event_handler,
          success_persistence,
          step_event_appender,
          terminal_persister
        )

      {:error, reason} ->
        handle_start_failure(db_request, reason, terminal_persister)
    end
  end

  defp handle_start_failure(db_request, reason, terminal_persister) do
    case fail_request(
           db_request,
           {:request_server_start_failed, reason},
           nil,
           terminal_persister
         ) do
      :ok -> {:error, {:request_server_start_failed, reason}}
      {:error, {:terminal_persist_failed, _} = persist_error} -> {:error, persist_error}
    end
  end

  defp run_dispatch_pipeline(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence,
         step_event_appender,
         terminal_persister
       ) do
    db_request
    |> dispatch_pipeline_result(
      canonical,
      model,
      caller,
      event_handler,
      success_persistence,
      step_event_appender,
      terminal_persister
    )
    |> handle_dispatch_pipeline_result(db_request, terminal_persister)
  end

  defp dispatch_pipeline_result(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence,
         step_event_appender,
         terminal_persister
       ) do
    with :ok <- advance_fsm(db_request.id, :validated) do
      dispatch_after_validation(
        db_request,
        canonical,
        model,
        caller,
        event_handler,
        success_persistence,
        step_event_appender,
        terminal_persister
      )
    end
  end

  defp dispatch_after_validation(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence,
         step_event_appender,
         terminal_persister
       ) do
    if Inference.queue_admission_enabled?() do
      run_queue_dispatch_pipeline(
        db_request,
        canonical,
        model,
        caller,
        event_handler,
        success_persistence,
        step_event_appender,
        terminal_persister
      )
    else
      run_legacy_dispatch_pipeline(
        db_request,
        canonical,
        model,
        caller,
        event_handler,
        success_persistence,
        step_event_appender,
        terminal_persister
      )
    end
  end

  defp handle_dispatch_pipeline_result({:ok, _, _} = success, _db_request, _terminal_persister),
    do: success

  defp handle_dispatch_pipeline_result(
         {:error, {:terminal_persist_failed, _} = persist_error, _step_context},
         _db_request,
         _terminal_persister
       ),
       do: {:error, persist_error}

  defp handle_dispatch_pipeline_result(
         {:error, reason, step_context},
         db_request,
         terminal_persister
       ) do
    fail_and_return_error(db_request, reason, step_context, terminal_persister)
  end

  defp handle_dispatch_pipeline_result(
         {:error, {:terminal_persist_failed, _} = persist_error},
         _db_request,
         _terminal_persister
       ),
       do: {:error, persist_error}

  defp handle_dispatch_pipeline_result(
         {:error, {:admission_already_terminalized, reason}},
         db_request,
         _terminal_persister
       ) do
    DomainMetrics.scheduler_rejection(reason)
    emit_terminal_metrics(db_request, terminal_status_for_queue_reason(reason))
    {:error, reason}
  end

  defp handle_dispatch_pipeline_result({:error, reason}, db_request, terminal_persister) do
    fail_and_return_error(db_request, reason, nil, terminal_persister)
  end

  defp fail_and_return_error(db_request, reason, step_context, terminal_persister) do
    advance_attempt_fsm_best_effort(db_request.id, step_context)

    case fail_request(db_request, reason, step_context, terminal_persister) do
      :ok -> {:error, reason}
      {:error, {:terminal_persist_failed, _} = persist_error} -> {:error, persist_error}
    end
  end

  defp run_legacy_dispatch_pipeline(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence,
         step_event_appender,
         terminal_persister
       ) do
    with {:ok, schedule} <- schedule_request(db_request, canonical),
         {:ok, _} <-
           record_scheduler_decision(db_request, scheduler_persistence_metadata(schedule)),
         :ok <- put_request_scheduled_context(schedule),
         :ok <- advance_fsm(db_request.id, :scheduled),
         :ok <- advance_fsm(db_request.id, :dispatching) do
      execute_inference_turn(db_request, canonical, model, schedule, %{
        caller: caller,
        event_handler: event_handler,
        success_persistence: success_persistence,
        step_event_appender: step_event_appender,
        terminal_persister: terminal_persister
      })
    end
  end

  defp run_queue_dispatch_pipeline(
         db_request,
         canonical,
         model,
         caller,
         event_handler,
         success_persistence,
         step_event_appender,
         terminal_persister
       ) do
    with :ok <- advance_fsm(db_request.id, :admitted),
         {:ok, grant} <- acquire_queue_grant(db_request, canonical, caller) do
      dispatch_if_queue_request_live(db_request, canonical, model, grant, %{
        caller: caller,
        event_handler: event_handler,
        success_persistence: success_persistence,
        step_event_appender: step_event_appender,
        terminal_persister: terminal_persister
      })
    end
  end

  defp dispatch_if_queue_request_live(db_request, canonical, model, grant, execution_opts) do
    if terminal_request?(db_request.id) do
      Inference.queue_manager().release(grant)
      {:error, {:admission_already_terminalized, terminal_queue_reason(db_request.id)}}
    else
      dispatch_with_queue_grant(db_request, canonical, model, grant, execution_opts)
    end
  end

  defp acquire_queue_grant(db_request, canonical, caller) do
    request = queue_admission_request(db_request, canonical, caller)

    if RequestDeadline.remaining_ms(db_request.timeout_at, DateTime.utc_now()) <= 0 do
      {:error, {:dispatch_failed, :request_timeout}}
    else
      acquire_queue_grant(request, db_request)
    end
  end

  defp acquire_queue_grant(request, db_request) do
    case Inference.queue_manager().acquire(request) do
      {:ok, %QueueManager.Grant{} = grant} ->
        {:ok, grant}

      {:queued, %QueueManager.Ticket{} = ticket} ->
        await_queued_grant(db_request, ticket)

      {:error, reason, metadata} ->
        persist_queue_terminal_metadata(db_request, metadata, reason)
    end
  end

  defp queue_admission_request(db_request, canonical, caller) do
    %{
      request_id: db_request.id,
      public_id: db_request.public_id,
      tenant_id: db_request.tenant_id,
      model_id: canonical.model_ref.model_id,
      version: canonical.model_ref.version,
      max_active_per_tenant: tenant_active_limit(canonical),
      max_wait_ms: queue_wait_budget_ms(db_request, canonical),
      caller_pid: caller
    }
  end

  defp queue_wait_budget_ms(db_request, canonical) do
    now = DateTime.utc_now()
    remaining_ms = RequestDeadline.remaining_ms(db_request.timeout_at, now)

    case canonical do
      %{admission: %{queue_wait_ms: wait}} when is_integer(wait) and wait >= 0 ->
        min(wait, remaining_ms)

      _canonical ->
        remaining_ms
    end
  end

  defp tenant_active_limit(canonical) do
    case canonical.resolved_policy.max_active_requests do
      limit when is_integer(limit) and limit > 0 -> limit
      _other -> nil
    end
  end

  defp await_queued_grant(db_request, ticket) do
    case record_queued_admission(db_request, ticket) do
      :ok ->
        consume_queued_grant(db_request, ticket, false)

      {:error, :already_terminal} ->
        consume_queued_grant(db_request, ticket, true)

      {:error, reason} ->
        if terminal_request?(db_request.id) do
          consume_queued_grant(db_request, ticket, true)
        else
          Inference.queue_manager().abandon(ticket)
          {:error, {:queue_metadata_persist_failed, reason}}
        end
    end
  end

  defp record_queued_admission(db_request, ticket) do
    with :ok <- maybe_advance_queued(db_request.id),
         {:ok, _request} <-
           Requests.record_schedule(db_request, QueueManager.queued_metadata(ticket)) do
      :ok
    end
  end

  defp maybe_advance_queued(request_id) do
    case Requests.get_request!(request_id).state do
      :queued -> :ok
      _other -> advance_fsm(request_id, :queued)
    end
  end

  defp consume_queued_grant(db_request, ticket, already_terminal?) do
    case Inference.queue_manager().await(ticket) do
      {:ok, %QueueManager.Grant{} = grant} ->
        {:ok, grant}

      {:error, reason, metadata} ->
        handle_queue_await_error(db_request, metadata, reason, already_terminal?)
    end
  end

  defp handle_queue_await_error(
         db_request,
         metadata,
         :request_caller_disconnect,
         already_terminal?
       ) do
    if already_terminal? or terminal_request?(db_request.id) do
      maybe_emit_tenant_quota_rejection(db_request, metadata, :request_caller_disconnect)
      {:error, {:admission_already_terminalized, terminal_queue_reason(db_request.id)}}
    else
      persist_queue_terminal_metadata(db_request, metadata, :request_caller_disconnect)
    end
  end

  defp handle_queue_await_error(db_request, metadata, reason, true) do
    maybe_emit_tenant_quota_rejection(db_request, metadata, reason)
    {:error, {:admission_already_terminalized, terminal_queue_reason(db_request.id)}}
  end

  defp handle_queue_await_error(db_request, metadata, reason, false) do
    if terminal_request?(db_request.id) do
      maybe_emit_tenant_quota_rejection(db_request, metadata, reason)
      {:error, {:admission_already_terminalized, terminal_queue_reason(db_request.id)}}
    else
      persist_queue_terminal_metadata(db_request, metadata, reason)
    end
  end

  defp persist_queue_terminal_metadata(db_request, metadata, reason) do
    case Requests.record_schedule(db_request, metadata) do
      {:ok, _request} ->
        maybe_emit_tenant_quota_rejection(db_request, metadata, reason)
        {:error, reason}

      {:error, persist_reason} ->
        {:error, {:queue_metadata_persist_failed, persist_reason}}
    end
  end

  defp terminal_request?(request_id) do
    Requests.get_request!(request_id).state in Request.terminal_states()
  end

  defp terminal_queue_reason(request_id) do
    case Requests.get_request!(request_id).error_code do
      "request_controller_restarted" -> :request_controller_restarted
      "request_caller_disconnect" -> :request_caller_disconnect
      "queue_timeout" -> :queue_timeout
      _other -> :already_terminal
    end
  end

  defp dispatch_with_queue_grant(db_request, canonical, model, grant, execution_opts) do
    case do_dispatch_with_queue_grant(db_request, canonical, model, grant, execution_opts) do
      {:error, reason} when reason in [:cluster_busy, :model_busy] ->
        requeue_after_schedule_busy(db_request, canonical, model, grant, execution_opts, reason)

      result ->
        result
    end
  after
    Inference.queue_manager().release(grant)
  end

  defp requeue_after_schedule_busy(db_request, canonical, model, grant, execution_opts, reason) do
    request = queue_admission_request(db_request, canonical, execution_opts.caller)

    case Inference.queue_manager().requeue(grant, request,
           queue_wait_reason: busy_queue_wait_reason(reason)
         ) do
      {:queued, %QueueManager.Ticket{} = ticket} ->
        with {:ok, next_grant} <- await_queued_grant(db_request, ticket) do
          dispatch_if_queue_request_live(db_request, canonical, model, next_grant, execution_opts)
        end

      {:error, :request_caller_disconnect, metadata} ->
        with {:ok, _request} <- Requests.record_schedule(db_request, metadata),
             :ok <-
               terminalize_pre_dispatch_disconnect(
                 db_request,
                 execution_opts.terminal_persister
               ) do
          {:error, {:admission_already_terminalized, :request_caller_disconnect}}
        end

      {:error, reason, metadata} ->
        handle_queue_await_error(db_request, metadata, reason, false)
    end
  end

  defp busy_queue_wait_reason(:cluster_busy), do: :live_node_capacity
  defp busy_queue_wait_reason(:model_busy), do: :requested_model_path_capacity

  defp do_dispatch_with_queue_grant(db_request, canonical, model, grant, execution_opts) do
    metadata = QueueManager.grant_metadata(grant)

    with {:ok, _request} <- Requests.record_schedule(db_request, metadata),
         :ok <-
           ensure_caller_alive_before_schedule(
             db_request,
             execution_opts.caller,
             metadata,
             execution_opts.terminal_persister
           ),
         {:ok, schedule} <- schedule_request(db_request, canonical),
         {:ok, _} <-
           record_scheduler_decision(
             db_request,
             scheduler_persistence_metadata(Map.merge(schedule, metadata))
           ),
         :ok <- put_request_scheduled_context(Map.merge(schedule, metadata)),
         :ok <- advance_fsm(db_request.id, :scheduled),
         :ok <- advance_fsm(db_request.id, :dispatching) do
      execute_inference_turn(
        db_request,
        canonical,
        model,
        schedule,
        Map.put(execution_opts, :queue_grant, grant)
      )
    end
  end

  defp ensure_caller_alive_before_schedule(db_request, caller, metadata, terminal_persister) do
    if Process.alive?(caller) do
      :ok
    else
      interrupt_metadata = Map.put(metadata, :queue_result, :interrupted_before_dispatch)

      with {:ok, _request} <- Requests.record_schedule(db_request, interrupt_metadata),
           :ok <- terminalize_pre_dispatch_disconnect(db_request, terminal_persister) do
        {:error, {:admission_already_terminalized, :request_caller_disconnect}}
      end
    end
  end

  defp terminalize_pre_dispatch_disconnect(db_request, terminal_persister) do
    terminal_attrs = %{
      state: :cancelled,
      error_code: "request_caller_disconnect",
      error_message: "Caller disconnected before scheduling"
    }

    case terminal_persister.(db_request, terminal_attrs, []) do
      {:ok, _request} ->
        advance_fsm_best_effort_terminal(db_request.id, :cancelled)
        :ok

      {:error, reason} ->
        {:error, {:terminal_persist_failed, reason}}
    end
  end

  defp execute_inference_turn(db_request, canonical, model, schedule, execution_opts) do
    if RequestDeadline.remaining_ms(db_request.timeout_at, DateTime.utc_now()) <= 0 do
      {:error, {:dispatch_failed, :request_timeout}}
    else
      step_context = inference_turn_step_context(canonical)

      case persist_inference_turn_started(
             db_request,
             step_context,
             execution_opts.step_event_appender
           ) do
        {:ok, persisted_step_context} ->
          dispatch_started_inference_turn(
            db_request,
            canonical,
            model,
            schedule,
            execution_opts,
            persisted_step_context
          )

        {:error, reason} ->
          {:error, {:request_step_start_failed, reason}}
      end
    end
  end

  defp dispatch_started_inference_turn(
         db_request,
         canonical,
         model,
         schedule,
         execution_opts,
         %AttemptContext{} = context
       ) do
    case dispatch(
           db_request,
           canonical,
           model,
           schedule,
           execution_opts.caller,
           execution_opts.event_handler,
           Map.get(execution_opts, :queue_grant)
         ) do
      %AttemptOutcome{} = pending_outcome ->
        case record_attempt_breaker_failure(db_request, model, context, pending_outcome) do
          :ok ->
            continue_after_breaker(
              db_request,
              canonical,
              model,
              schedule,
              execution_opts,
              context,
              pending_outcome
            )

          {:error, reason} ->
            decision =
              finished_attempt_decision(pending_outcome, db_request, context, execution_opts)

            {:error, reason, terminal_evidence(context, pending_outcome, decision)}
        end

      {:error, reason} ->
        outcome = failed_dispatch_outcome(schedule)
        decision = finished_attempt_decision(outcome, db_request, context, execution_opts)
        {:error, reason, terminal_evidence(context, outcome, decision)}
    end
  end

  defp record_attempt_breaker_failure(db_request, model, context, outcome) do
    case AttemptBreakerAttribution.record(
           db_request.id,
           context.attempt,
           Map.get(model, :id),
           outcome
         ) do
      {:ok, _decision} -> :ok
      {:error, reason} -> {:error, {:breaker_attribution_failed, reason}}
    end
  end

  defp continue_after_breaker(
         db_request,
         canonical,
         model,
         schedule,
         execution_opts,
         %AttemptContext{attempt: 1} = context,
         %AttemptOutcome{attempt_outcome: attempt_outcome, delivery_state: :pending} =
           pending_outcome
       )
       when attempt_outcome != :completed do
    continue_attempt_one_after_breaker(
      db_request,
      canonical,
      model,
      schedule,
      execution_opts,
      context,
      pending_outcome
    )
  end

  defp continue_after_breaker(
         db_request,
         canonical,
         _model,
         _schedule,
         execution_opts,
         %AttemptContext{} = context,
         %AttemptOutcome{} = pending_outcome
       ) do
    selected = select_attempt_outcome(pending_outcome, canonical, execution_opts)
    decision = finished_attempt_decision(selected, db_request, context, execution_opts)

    continue_selected_attempt(
      db_request,
      canonical,
      selected,
      execution_opts,
      context,
      decision
    )
  end

  defp continue_attempt_one_after_breaker(
         db_request,
         canonical,
         model,
         schedule,
         execution_opts,
         %AttemptContext{} = context,
         %AttemptOutcome{} = pending_outcome
       ) do
    boundary = retry_boundary(pending_outcome, db_request, context, execution_opts)

    case AttemptRetryClassifier.pre_schedule(boundary) do
      {:declined, decision} ->
        decline_attempt_one(
          db_request,
          canonical,
          pending_outcome,
          execution_opts,
          context,
          decision
        )

      :eligible_for_alternate ->
        continue_eligible_attempt_one(
          db_request,
          canonical,
          model,
          schedule,
          execution_opts,
          context,
          pending_outcome
        )
    end
  end

  defp continue_eligible_attempt_one(
         db_request,
         canonical,
         model,
         schedule,
         execution_opts,
         context,
         pending_outcome
       ) do
    if unmanaged_compatibility_schedule?(schedule) do
      decline_attempt_one(
        db_request,
        canonical,
        pending_outcome,
        execution_opts,
        context,
        :no_alternative_node
      )
    else
      continue_schedulable_attempt_one(
        db_request,
        canonical,
        model,
        schedule,
        execution_opts,
        context,
        pending_outcome
      )
    end
  end

  defp continue_schedulable_attempt_one(
         db_request,
         canonical,
         model,
         schedule,
         execution_opts,
         context,
         pending_outcome
       ) do
    case persist_attempt_one_state(db_request.id, pending_outcome) do
      :ok ->
        start_alternate_attempt(
          db_request,
          canonical,
          model,
          schedule,
          execution_opts,
          context,
          pending_outcome
        )

      {:error, reason} ->
        {:error, {:attempt_one_state_transition_failed, reason},
         terminal_evidence(context, pending_outcome, :not_retryable)}
    end
  end

  defp persist_attempt_one_state(request_id, %AttemptOutcome{accepted: true}) do
    case RequestServer.get_state(request_id) do
      {:ok, :running} -> :ok
      {:ok, _state} -> advance_fsm(request_id, :running)
      {:error, _reason} = error -> error
    end
  end

  defp persist_attempt_one_state(request_id, %AttemptOutcome{accepted: false}) do
    case RequestServer.get_state(request_id) do
      {:ok, :dispatching} -> :ok
      other -> {:error, {:unexpected_unaccepted_attempt_state, other}}
    end
  end

  defp start_alternate_attempt(
         db_request,
         canonical,
         model,
         attempt_one_schedule,
         execution_opts,
         %AttemptContext{} = context,
         %AttemptOutcome{} = pending_outcome
       ) do
    with_live_retry_boundary(
      db_request,
      canonical,
      pending_outcome,
      execution_opts,
      context,
      fn _boundary ->
        prefix_cache_score_budget_consumed =
          prefix_cache_score_budget_consumed(attempt_one_schedule)

        result =
          schedule_alternate_request(
            canonical,
            [pending_outcome.node_id],
            db_request.timeout_at,
            prefix_cache_score_budget_consumed
          )

        with_live_retry_boundary(
          db_request,
          canonical,
          pending_outcome,
          execution_opts,
          context,
          fn _post_schedule_boundary ->
            handle_alternate_schedule_result(
              result,
              db_request,
              canonical,
              model,
              execution_opts,
              context,
              pending_outcome
            )
          end
        )
      end
    )
  end

  defp handle_alternate_schedule_result(
         {:candidate, alternate_schedule, persistence_metadata},
         db_request,
         canonical,
         model,
         execution_opts,
         context,
         pending_outcome
       ) do
    run_retry_persist_probe()

    with_live_retry_boundary(
      db_request,
      canonical,
      pending_outcome,
      execution_opts,
      context,
      fn boundary ->
        persist_and_dispatch_alternate(
          db_request,
          canonical,
          model,
          {alternate_schedule, persistence_metadata},
          execution_opts,
          context,
          pending_outcome,
          AttemptRetryClassifier.finalize_alternate(boundary, :different_node)
        )
      end
    )
  end

  defp handle_alternate_schedule_result(
         {:no_candidate, _reason, persistence_metadata},
         db_request,
         canonical,
         _model,
         execution_opts,
         context,
         pending_outcome
       ) do
    persist_alternate_rejection(db_request, persistence_metadata)

    with_live_retry_boundary(
      db_request,
      canonical,
      pending_outcome,
      execution_opts,
      context,
      fn boundary ->
        decline_attempt_one(
          db_request,
          canonical,
          pending_outcome,
          execution_opts,
          context,
          AttemptRetryClassifier.finalize_alternate(boundary, :no_candidate)
        )
      end
    )
  end

  defp handle_alternate_schedule_result(
         {:identity_unresolved, persistence_metadata},
         db_request,
         canonical,
         _model,
         execution_opts,
         context,
         pending_outcome
       ) do
    persist_alternate_rejection(db_request, persistence_metadata)

    with_live_retry_boundary(
      db_request,
      canonical,
      pending_outcome,
      execution_opts,
      context,
      fn boundary ->
        decline_attempt_one(
          db_request,
          canonical,
          pending_outcome,
          execution_opts,
          context,
          AttemptRetryClassifier.finalize_alternate(boundary, :identity_unresolved)
        )
      end
    )
  end

  defp handle_alternate_schedule_result(
         {:orchestration_error, reason},
         _db_request,
         _canonical,
         _model,
         _execution_opts,
         context,
         pending_outcome
       ) do
    {:error, reason, terminal_evidence(context, pending_outcome, :not_retryable)}
  end

  defp persist_alternate_rejection(db_request, metadata),
    do: persist_rejected_scheduler_decision(db_request, metadata)

  defp persist_and_dispatch_alternate(
         db_request,
         canonical,
         model,
         {alternate_schedule, persistence_metadata},
         execution_opts,
         %AttemptContext{} = attempt_one_context,
         %AttemptOutcome{} = pending_outcome,
         :retried
       ) do
    attempt_two_context = inference_turn_step_context(canonical, 2, [pending_outcome.node_id])

    case persist_retried_attempt_boundary(
           db_request,
           pending_outcome,
           attempt_one_context,
           attempt_two_context,
           persistence_metadata
         ) do
      {:ok, {:attempt_two_started, persisted_attempt_two_context}} ->
        dispatch_persisted_alternate(
          db_request,
          canonical,
          model,
          alternate_schedule,
          execution_opts,
          pending_outcome,
          persisted_attempt_two_context
        )

      {:error, reason} ->
        {:error, reason, terminal_evidence(attempt_one_context, pending_outcome, :not_retryable)}
    end
  end

  defp dispatch_persisted_alternate(
         db_request,
         canonical,
         model,
         alternate_schedule,
         execution_opts,
         pending_outcome,
         %AttemptContext{} = attempt_two_context
       ) do
    case AttemptOutcome.discard(pending_outcome) do
      {:ok, _discarded} ->
        dispatch_alternate_if_live(
          db_request,
          canonical,
          model,
          alternate_schedule,
          execution_opts,
          attempt_two_context
        )

      {:error, reason} ->
        terminalize_started_attempt_two_controller(
          alternate_schedule,
          attempt_two_context,
          reason
        )
    end
  end

  defp dispatch_alternate_if_live(
         db_request,
         canonical,
         model,
         alternate_schedule,
         execution_opts,
         attempt_two_context
       ) do
    snapshot = retry_gate_snapshot(execution_opts.caller, db_request.timeout_at, nil)

    case snapshot do
      %{caller_status: :cancelled} ->
        terminalize_started_attempt_two(alternate_schedule, attempt_two_context, :cancelled)

      %{deadline_status: :exhausted} ->
        terminalize_started_attempt_two(
          alternate_schedule,
          attempt_two_context,
          :budget_exhausted
        )

      _open ->
        dispatch_started_inference_turn(
          db_request,
          canonical,
          model,
          alternate_schedule,
          execution_opts,
          attempt_two_context
        )
    end
  end

  defp decline_attempt_one(
         _db_request,
         _canonical,
         %AttemptOutcome{attempt_outcome: attempt_outcome} = pending_outcome,
         _execution_opts,
         %AttemptContext{} = context,
         :cancelled
       )
       when attempt_outcome != :cancelled do
    _ = AttemptOutcome.discard(pending_outcome)
    cancelled = cancel_attempt_outcome(pending_outcome)

    {:error, {:dispatch_failed, :request_caller_disconnect},
     terminal_evidence(context, cancelled, :cancelled)}
  end

  defp decline_attempt_one(
         db_request,
         canonical,
         %AttemptOutcome{} = pending_outcome,
         execution_opts,
         %AttemptContext{} = context,
         planned_decision
       ) do
    selected = select_attempt_outcome(pending_outcome, canonical, execution_opts)
    decision = selected_decline_decision(selected, db_request, execution_opts, planned_decision)

    continue_selected_attempt(
      db_request,
      canonical,
      selected,
      execution_opts,
      context,
      decision
    )
  end

  defp cancel_attempt_outcome(%AttemptOutcome{} = outcome) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      outcome
      | attempt_outcome: :cancelled,
        model_load_category: nil,
        failure:
          InferenceAttemptFailure.normalize(%{
            category: :cancellation,
            code: :request_caller_disconnect
          }),
        ended_at: now
    }

    {:ok, cancelled} = AttemptOutcome.new(Map.from_struct(attrs))
    cancelled
  end

  defp selected_decline_decision(selected, db_request, execution_opts, planned_decision) do
    boundary = retry_boundary(selected, db_request, 1, execution_opts)

    case AttemptRetryClassifier.pre_schedule(boundary) do
      {:declined, decision}
      when decision in [:output_committed, :cancelled, :budget_exhausted] ->
        decision

      _other ->
        planned_decision
    end
  end

  defp select_attempt_outcome(
         %AttemptOutcome{delivery_state: :pending} = outcome,
         canonical,
         execution_opts
       ) do
    AttemptOutcome.select(outcome, canonical.public_id, execution_opts.event_handler)
  end

  defp select_attempt_outcome(%AttemptOutcome{} = outcome, _canonical, _execution_opts),
    do: outcome

  defp continue_selected_attempt(
         db_request,
         canonical,
         %AttemptOutcome{} = outcome,
         execution_opts,
         %AttemptContext{} = context,
         retry_decision
       ) do
    cond do
      outcome.delivery_state == :failed ->
        {:error, public_dispatch_reason(outcome),
         terminal_evidence(context, outcome, retry_decision)}

      Enum.any?(outcome.events, &InferenceEvent.terminal?/1) ->
        finalize_started_inference_turn(
          db_request,
          canonical,
          outcome,
          execution_opts,
          context,
          retry_decision
        )

      true ->
        {:error, public_dispatch_reason(outcome),
         terminal_evidence(context, outcome, retry_decision)}
    end
  end

  defp failed_dispatch_outcome(schedule) do
    started_attempt_outcome(
      schedule,
      :failed,
      InferenceAttemptFailure.normalize(%{category: :controller, code: :orchestration_error}),
      :unresolved,
      :unresolved
    )
  end

  defp started_attempt_outcome(
         schedule,
         attempt_outcome,
         failure,
         execution_resolution,
         capacity_release_outcome
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      attempt_outcome: attempt_outcome,
      node_id: trusted_node_id(schedule),
      accepted: false,
      events: [],
      failure: failure,
      execution_resolution: execution_resolution,
      capacity_release_outcome: capacity_release_outcome,
      started_at: now,
      ended_at: now,
      first_token_at: nil,
      output_committed: false,
      output_commitment_kind: nil,
      delivery_state: :pending,
      delivered_event_count: 0,
      runtime_retryable: nil
    }

    {:ok, outcome} = AttemptOutcome.new(attrs)
    outcome
  end

  defp schedule_alternate_request(
         canonical,
         exclude_node_ids,
         timeout_at,
         prefix_cache_score_budget_consumed
       ) do
    case call_scheduler(canonical, exclude_node_ids, prefix_cache_score_budget_consumed) do
      {:ok, schedule} when is_map(schedule) ->
        classify_alternate_scheduler_selection(schedule, exclude_node_ids, timeout_at)

      {:error, reason, decision} when is_map(decision) ->
        {:no_candidate, reason, decision}

      {:error, {:orchestration_crash, _details} = reason} ->
        {:orchestration_error, reason}

      {:error, reason} ->
        {:orchestration_error, orchestration_crash(:scheduler, {:missing_decision, reason})}

      other ->
        {:orchestration_error, orchestration_crash(:scheduler, {:invalid_return, other})}
    end
  end

  defp classify_alternate_scheduler_selection(schedule, exclude_node_ids, timeout_at) do
    case validate_scheduler_selection(schedule, exclude_node_ids) do
      :ok ->
        accepted = Map.put(schedule, :timeout_at, timeout_at)
        {:candidate, accepted, scheduler_persistence_metadata(accepted)}

      {:error, {:dispatch_failed, :identity_unresolved}} ->
        {:identity_unresolved, scheduler_persistence_metadata(schedule)}
    end
  end

  defp persist_retried_attempt_boundary(
         db_request,
         %AttemptOutcome{} = attempt_one_outcome,
         %AttemptContext{} = attempt_one_context,
         %AttemptContext{} = attempt_two_context,
         persistence_metadata
       ) do
    terminal_attrs = unsuccessful_attempt_terminal_attrs(attempt_one_outcome)

    steps = [
      terminal_inference_turn_step(
        db_request,
        attempt_one_outcome.events,
        terminal_attrs,
        attempt_one_context,
        attempt_one_outcome,
        :retried
      ),
      inference_turn_started_step(attempt_two_context)
    ]

    case start_attempt_two_fsm(db_request.id, persistence_metadata, steps) do
      :ok ->
        run_retry_started_probe(db_request)
        {:ok, {:attempt_two_started, attempt_two_context}}

      {:error, reason} ->
        {:error, {:request_step_start_failed, reason}}
    end
  end

  defp start_attempt_two_fsm(request_id, persistence_metadata, steps) do
    case RequestServer.start_attempt_two(request_id, persistence_metadata, steps) do
      {:error, {:invalid_scheduler_explanation, reason}} ->
        log_error(
          "invalid scheduler explanation at attempt 2 start: #{inspect(reason)}; " <>
            "persisting scheduler decision without explanation candidates"
        )

        RequestServer.start_attempt_two(
          request_id,
          drop_scheduler_explanation(persistence_metadata),
          steps
        )

      result ->
        result
    end
  end

  defp unsuccessful_attempt_terminal_attrs(%AttemptOutcome{events: events} = outcome) do
    if Enum.any?(events, &InferenceEvent.terminal?/1) do
      terminal_attrs_from_events(events)
    else
      outcome
      |> public_dispatch_reason()
      |> ChatError.from_execute_error()
      |> ChatError.terminal_attrs()
    end
  end

  defp terminalize_started_attempt_two(schedule, context, :cancelled) do
    failure =
      InferenceAttemptFailure.normalize(%{
        category: :cancellation,
        code: :request_caller_disconnect
      })

    outcome =
      started_attempt_outcome(schedule, :cancelled, failure, :not_started, :not_applicable)

    {:error, {:dispatch_failed, :request_caller_disconnect},
     terminal_evidence(context, outcome, :cancelled)}
  end

  defp terminalize_started_attempt_two(schedule, context, :budget_exhausted) do
    failure = InferenceAttemptFailure.normalize(%{category: :deadline, code: :request_timeout})

    outcome =
      started_attempt_outcome(schedule, :timed_out, failure, :not_started, :not_applicable)

    {:error, {:dispatch_failed, :request_timeout},
     terminal_evidence(context, outcome, :retry_exhausted)}
  end

  defp terminalize_started_attempt_two_controller(schedule, context, reason) do
    failure =
      InferenceAttemptFailure.normalize(%{category: :controller, code: :orchestration_error})

    outcome = started_attempt_outcome(schedule, :failed, failure, :not_started, :not_applicable)

    {:error, orchestration_crash(:attempt_two_start, reason),
     terminal_evidence(context, outcome, :retry_exhausted)}
  end

  defp finished_attempt_decision(
         %AttemptOutcome{attempt_outcome: :completed},
         _db_request,
         _context,
         _execution_opts
       ),
       do: nil

  defp finished_attempt_decision(outcome, db_request, context, execution_opts) do
    boundary = retry_boundary(outcome, db_request, context, execution_opts)

    case AttemptRetryClassifier.pre_schedule(boundary) do
      {:declined, decision} -> decision
      :eligible_for_alternate -> :not_retryable
    end
  end

  defp with_live_retry_boundary(
         db_request,
         canonical,
         pending_outcome,
         execution_opts,
         %AttemptContext{} = context,
         on_eligible
       )
       when is_function(on_eligible, 1) do
    boundary = retry_boundary(pending_outcome, db_request, context, execution_opts)

    case AttemptRetryClassifier.pre_schedule(boundary) do
      {:declined, decision} ->
        decline_attempt_one(
          db_request,
          canonical,
          pending_outcome,
          execution_opts,
          context,
          decision
        )

      :eligible_for_alternate ->
        on_eligible.(boundary)
    end
  end

  defp run_retry_persist_probe do
    case Process.get(:orchard_retry_persist_probe) do
      fun when is_function(fun, 0) -> fun.()
      _other -> :ok
    end
  end

  defp run_retry_started_probe(db_request) do
    case Process.get(:orchard_retry_started_probe) do
      fun when is_function(fun, 1) -> fun.(db_request)
      _other -> :ok
    end
  end

  defp retry_boundary(outcome, db_request, %AttemptContext{attempt: attempt}, execution_opts),
    do: retry_boundary(outcome, db_request, attempt, execution_opts)

  defp retry_boundary(outcome, db_request, attempt, execution_opts) do
    snapshot = retry_gate_snapshot(execution_opts.caller, db_request.timeout_at, outcome)

    %{
      attempt: attempt,
      output_committed: outcome.output_committed,
      caller_status: snapshot.caller_status,
      deadline_status: snapshot.deadline_status,
      failure_class: Map.fetch!(outcome.failure, "failure_class"),
      failure_code: Map.fetch!(outcome.failure, "failure_code"),
      model_load_category: outcome.model_load_category,
      runtime_retryable: outcome.runtime_retryable,
      identity_resolution: identity_resolution(outcome),
      execution_resolution: outcome.execution_resolution,
      capacity_release_outcome: outcome.capacity_release_outcome
    }
    |> AttemptRetryClassifier.new()
  end

  defp retry_gate_snapshot(caller, timeout_at, outcome) do
    caller_status =
      if match?(%AttemptOutcome{attempt_outcome: :cancelled}, outcome) or
           not Process.alive?(caller) do
        :cancelled
      else
        :live
      end

    deadline_status =
      if RequestDeadline.remaining_ms(timeout_at, DateTime.utc_now()) > 0,
        do: :remaining,
        else: :exhausted

    %{caller_status: caller_status, deadline_status: deadline_status}
  end

  defp identity_resolution(%AttemptOutcome{node_id: node_id}) do
    if match?({:ok, _uuid}, Ecto.UUID.cast(node_id)), do: :resolved, else: :unresolved
  end

  defp terminal_evidence(%AttemptContext{attempt: 1} = context, outcome, decision),
    do: {:attempt_one_declined, context, outcome, decision}

  defp terminal_evidence(%AttemptContext{attempt: 2} = context, outcome, decision),
    do: {:attempt_two_finished, context, outcome, decision}

  defp trusted_node_id(schedule) do
    case Map.get(schedule, :node_id) do
      node_id when is_binary(node_id) ->
        if match?({:ok, _uuid}, Ecto.UUID.cast(node_id)), do: node_id, else: nil

      _node_id ->
        nil
    end
  end

  defp finalize_started_inference_turn(
         db_request,
         canonical,
         %AttemptOutcome{} = outcome,
         execution_opts,
         %AttemptContext{} = context,
         retry_decision
       ) do
    case finalize(
           db_request,
           canonical,
           outcome,
           execution_opts,
           context,
           retry_decision
         ) do
      {:ok, _, _} = success ->
        success

      {:error, reason} ->
        failed_outcome = AttemptOutcome.fail_attempt(outcome)
        decision = finished_attempt_decision(failed_outcome, db_request, context, execution_opts)
        {:error, reason, terminal_evidence(context, failed_outcome, decision)}
    end
  end

  defp persist_request(canonical, model, idempotency) do
    # Internal callers may bypass the public normalizers, so resolve admission
    # again as a fail-safe immediately before serializing and persisting.
    canonical = AdmissionPolicy.resolve(canonical)

    with :ok <- validate_persistable_timeout(canonical),
         {:ok, serialized_canonical} <- serialize_canonical_request(canonical) do
      capture_mode = effective_capture_mode(canonical)

      canonical
      |> request_attrs(model, serialized_canonical, capture_mode)
      |> put_idempotency_attrs(idempotency)
      |> Requests.create_request()
      |> handle_create_request_result(idempotency, canonical)
    end
  end

  defp validate_persistable_timeout(%CanonicalRequest{admission: %{timeout_ms: timeout_ms}})
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: :ok

  defp validate_persistable_timeout(%CanonicalRequest{}),
    do: {:error, :request_timeout_unresolved}

  defp effective_capture_mode(canonical) do
    case Governance.get_tenant(canonical.tenant_id) do
      {:ok, tenant} ->
        CapturePolicy.resolve(tenant.request_body_capture_mode, canonical.store?)

      {:error, :tenant_not_found} ->
        :none
    end
  end

  defp request_attrs(canonical, model, serialized_canonical, capture_mode) do
    %{
      id: canonical.internal_id,
      public_id: canonical.public_id,
      endpoint: canonical.endpoint,
      tenant_id: canonical.tenant_id,
      principal_type: canonical.principal_type,
      api_key_id: canonical.api_key_id,
      service_account_id: canonical.service_account_id,
      requested_model: "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}",
      model_id: model.id,
      state: :received,
      stream: canonical.stream?,
      body_hash: serialized_canonical |> Jason.encode!() |> sha256(),
      payload_capture_mode: capture_mode,
      canonical_request: serialized_canonical,
      request_payload: %{"prompt" => canonical.rendered_prompt},
      sampling_params: CanonicalRequestSerializer.sampling_params(canonical.sampling),
      response_format: %{"type" => Atom.to_string(canonical.response_format.type)},
      input_tokens: canonical.input_token_count,
      reserved_output_tokens: effective_max_output_tokens(canonical.sampling),
      timeout_at:
        RequestDeadline.timeout_at(
          canonical.admission.timeout_ms,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )
    }
  end

  defp sha256(content), do: :crypto.hash(:sha256, content)

  defp put_idempotency_attrs(attrs, %Idempotency.Context{} = idempotency) do
    Map.merge(attrs, %{
      idempotency_key: idempotency.key,
      body_hash: idempotency.body_hash
    })
  end

  defp put_idempotency_attrs(attrs, nil), do: attrs

  defp handle_create_request_result({:ok, request}, _idempotency, canonical),
    do: {:ok, request, canonical}

  defp handle_create_request_result(
         {:error, changeset},
         %Idempotency.Context{} = idempotency,
         _canonical
       ) do
    if idempotency_constraint?(changeset) do
      resolve_duplicate_request(idempotency)
    else
      {:error, changeset}
    end
  end

  defp handle_create_request_result({:error, changeset}, nil, _canonical), do: {:error, changeset}

  defp idempotency_constraint?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:idempotency_key, {_message, metadata}} ->
        to_string(Keyword.get(metadata, :constraint_name)) == "idx_requests_tenant_idempotency"

      _other ->
        false
    end)
  end

  defp resolve_duplicate_request(idempotency) do
    case Idempotency.resolve(idempotency) do
      {:replay, request} ->
        {:replay, request}

      {:conflict, reason, _request} ->
        {:error, {:idempotency_conflict, reason}}

      :proceed ->
        {:error, {:idempotency_resolution_failed, :missing_request}}
    end
  end

  defp start_fsm(db_request) do
    RequestServer.start(
      request_id: db_request.id,
      public_id: db_request.public_id,
      initial_state: :received
    )
  end

  defp advance_fsm(request_id, state) do
    RequestServer.transition(request_id, state)
  end

  defp schedule_request(db_request, canonical) do
    schedule_request(db_request, canonical, [])
  end

  defp schedule_request(db_request, canonical, exclude_node_ids) do
    if RequestDeadline.remaining_ms(db_request.timeout_at, DateTime.utc_now()) <= 0 do
      {:error, {:dispatch_failed, :request_timeout}}
    else
      schedule_live_request(db_request, canonical, exclude_node_ids)
    end
  end

  defp schedule_live_request(db_request, canonical, exclude_node_ids) do
    case call_scheduler(canonical, exclude_node_ids) do
      {:ok, schedule} when is_map(schedule) ->
        accept_scheduler_selection(db_request, schedule, exclude_node_ids)

      {:error, reason, decision} when is_map(decision) ->
        persist_rejected_scheduler_decision(db_request, decision)
        {:error, reason}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, orchestration_crash(:scheduler, :invalid_return)}
    end
  end

  defp accept_scheduler_selection(db_request, schedule, exclude_node_ids) do
    with :ok <- validate_scheduler_selection(schedule, exclude_node_ids),
         true <- RequestDeadline.remaining_ms(db_request.timeout_at, DateTime.utc_now()) > 0 do
      {:ok, Map.put(schedule, :timeout_at, db_request.timeout_at)}
    else
      false -> {:error, {:dispatch_failed, :request_timeout}}
      {:error, _reason} = error -> error
    end
  end

  defp persist_rejected_scheduler_decision(db_request, decision) do
    case record_scheduler_decision(db_request, decision) do
      {:ok, _request} ->
        :ok

      {:error, _reason} ->
        log_error(
          "failed to persist rejected scheduler decision for request #{db_request.public_id}"
        )

        :ok
    end
  end

  defp call_scheduler(canonical, exclude_node_ids) do
    call_scheduler(canonical, exclude_node_ids, 0)
  end

  defp call_scheduler(canonical, exclude_node_ids, prefix_cache_score_budget_consumed) do
    opts = [exclude_node_ids: exclude_node_ids]

    opts =
      if prefix_cache_score_budget_consumed > 0 do
        Keyword.put(
          opts,
          :prefix_cache_score_budget_consumed,
          prefix_cache_score_budget_consumed
        )
      else
        opts
      end

    Inference.scheduler().schedule(canonical, opts)
  rescue
    error ->
      log_warn("scheduler crashed: #{exception_name(error)}")
      {:error, orchestration_crash(:scheduler, {:exception, error})}
  catch
    :exit, _reason ->
      log_warn("scheduler exited")
      {:error, orchestration_crash(:scheduler, :exit)}

    _kind, _reason ->
      log_warn("scheduler threw")
      {:error, orchestration_crash(:scheduler, :throw)}
  end

  defp validate_selected_target_identity(schedule, selected_node_id) do
    case map_value(schedule, :runtime_endpoint_target) do
      nil ->
        validate_legacy_target_identity(schedule, selected_node_id)

      target ->
        validate_runtime_endpoint_target_identity(target, selected_node_id)
    end
  end

  defp validate_runtime_endpoint_target_identity(
         %Target{transport: :grpc_compat} = target,
         selected_node_id
       ) do
    with {:ok, ^selected_node_id} <- target_node_id(target),
         {:ok, %Orchard.Nodes.Node{id: durable_node_id}} <- Nodes.lookup_by_target_result(target),
         {:ok, ^selected_node_id} <- Ecto.UUID.cast(durable_node_id) do
      :ok
    else
      _missing_or_conflicting -> :error
    end
  end

  defp validate_runtime_endpoint_target_identity(target, selected_node_id) do
    case target_node_id(target) do
      {:ok, ^selected_node_id} -> :ok
      _missing_or_conflicting -> :error
    end
  end

  defp validate_legacy_target_identity(schedule, selected_node_id) do
    with target when not is_nil(target) <- map_value(schedule, :runtime_client_target),
         {:ok, %Orchard.Nodes.Node{id: node_id}} <- Nodes.lookup_by_target_result(target),
         {:ok, ^selected_node_id} <- Ecto.UUID.cast(node_id) do
      :ok
    else
      _missing_or_conflicting -> :error
    end
  end

  defp target_node_id(%Target{node_id: node_id}), do: Ecto.UUID.cast(node_id)

  defp target_node_id(target) when is_map(target) do
    target
    |> map_value(:node_id)
    |> Ecto.UUID.cast()
  end

  defp target_node_id(_target), do: :error

  defp record_scheduler_decision(db_request, metadata) do
    case Requests.record_schedule(db_request, metadata) do
      {:error, {:invalid_scheduler_explanation, reason}} ->
        log_error(
          "invalid scheduler explanation for request #{db_request.public_id}: " <>
            "#{inspect(reason)}; persisting scheduler decision without explanation candidates"
        )

        Requests.record_schedule(db_request, drop_scheduler_explanation(metadata))

      result ->
        result
    end
  end

  defp drop_scheduler_explanation(metadata) do
    Map.drop(metadata, [
      :scored_candidates,
      "scored_candidates",
      :rejected_candidates,
      "rejected_candidates",
      :skipped_candidates,
      "skipped_candidates"
    ])
  end

  defp scheduler_persistence_metadata(schedule) do
    schedule
    |> strip_scheduler_runtime_metadata()
    |> maybe_merge_prefix_cache_fields(schedule)
    |> maybe_merge_prefix_cache_score_fields(schedule)
    |> maybe_merge_memory_admission_fields(schedule)
  end

  defp maybe_merge_prefix_cache_fields(metadata, schedule) do
    if Inference.cache_introspection_enabled?() do
      fields =
        PrefixCacheStatus.selected_fields(prefix_cache_status(schedule),
          fingerprint_match: prefix_cache_fingerprint_match(schedule)
        )

      Map.merge(metadata, fields)
    else
      metadata
    end
  end

  defp prefix_cache_status(schedule) do
    Map.get(schedule, :prefix_cache_status) || Map.get(schedule, "prefix_cache_status")
  end

  defp prefix_cache_fingerprint_match(schedule) do
    cond do
      Map.has_key?(schedule, :prefix_cache_fingerprint_match?) ->
        Map.get(schedule, :prefix_cache_fingerprint_match?)

      Map.has_key?(schedule, "prefix_cache_fingerprint_match?") ->
        Map.get(schedule, "prefix_cache_fingerprint_match?")

      true ->
        nil
    end
  end

  defp maybe_merge_prefix_cache_score_fields(metadata, schedule) do
    if Inference.cache_introspection_enabled?() and Inference.prefix_cache_scoring_enabled?() do
      fields =
        schedule
        |> prefix_cache_score()
        |> PrefixCacheScore.selected_fields()

      Map.merge(metadata, fields)
    else
      metadata
    end
  end

  defp prefix_cache_score(schedule) do
    Map.get(schedule, :prefix_cache_score) || Map.get(schedule, "prefix_cache_score")
  end

  defp maybe_merge_memory_admission_fields(metadata, schedule) do
    if Inference.memory_admission_enabled?() do
      memory_budget = memory_budget(schedule)
      tier = memory_admission_tier(memory_budget)

      metadata
      |> Map.merge(%{memory_admission_enabled: true, memory_admission_tier: tier})
      |> Map.merge(MemoryBudget.selected_fields(memory_budget))
    else
      metadata
    end
  end

  defp memory_budget(schedule) do
    Map.get(schedule, :memory_budget) || Map.get(schedule, "memory_budget")
  end

  defp memory_admission_tier(memory_budget) do
    memory_budget
    |> MemoryBudget.normalize_for_scheduler()
    |> Map.get(:admission_tier, :headroom_unknown)
    |> Atom.to_string()
  end

  defp strip_scheduler_runtime_metadata(schedule) do
    schedule
    |> Map.drop([:timeout_at, "timeout_at"])
    |> strip_runtime_endpoint_metadata()
    |> strip_dispatch_capacity_metadata()
    |> strip_prefix_cache_metadata()
    |> strip_memory_admission_metadata()
  end

  defp strip_runtime_endpoint_metadata(schedule) do
    Map.reject(schedule, fn {key, _value} -> runtime_endpoint_metadata_key?(key) end)
  end

  defp runtime_endpoint_metadata_key?(:runtime_endpoint_target), do: true
  defp runtime_endpoint_metadata_key?("runtime_endpoint_target"), do: true
  defp runtime_endpoint_metadata_key?(:dispatch_identity_source), do: true
  defp runtime_endpoint_metadata_key?("dispatch_identity_source"), do: true
  defp runtime_endpoint_metadata_key?(_key), do: false

  defp strip_dispatch_capacity_metadata(schedule) do
    Map.reject(schedule, fn {key, _value} -> dispatch_capacity_metadata_key?(key) end)
  end

  defp dispatch_capacity_metadata_key?(key)
       when key in [
              :dispatch_capacity_input,
              :dispatch_capacity_evaluation,
              :dispatch_capacity_acquisition_input_provider,
              :dispatch_capacity_input_provider,
              :dispatch_capacity_authority
            ],
       do: true

  defp dispatch_capacity_metadata_key?(key) when is_binary(key) do
    key in [
      "dispatch_capacity_input",
      "dispatch_capacity_evaluation",
      "dispatch_capacity_acquisition_input_provider",
      "dispatch_capacity_input_provider",
      "dispatch_capacity_authority"
    ]
  end

  defp dispatch_capacity_metadata_key?(_key), do: false

  defp strip_prefix_cache_metadata(schedule) do
    Map.reject(schedule, fn {key, _value} -> prefix_cache_metadata_key?(key) end)
  end

  defp prefix_cache_metadata_key?(:prefix_cache_status), do: true
  defp prefix_cache_metadata_key?("prefix_cache_status"), do: true
  defp prefix_cache_metadata_key?(:prefix_cache_fingerprint_match?), do: true
  defp prefix_cache_metadata_key?("prefix_cache_fingerprint_match?"), do: true
  defp prefix_cache_metadata_key?(:prefix_cache_score), do: true
  defp prefix_cache_metadata_key?("prefix_cache_score"), do: true
  defp prefix_cache_metadata_key?(:prefix_cache_score_budget_consumed), do: true
  defp prefix_cache_metadata_key?("prefix_cache_score_budget_consumed"), do: true

  defp prefix_cache_metadata_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> prefix_cache_metadata_key?()
  end

  defp prefix_cache_metadata_key?(key) when is_binary(key) do
    String.starts_with?(key, "selected_prefix_cache_")
  end

  defp prefix_cache_metadata_key?(_key), do: false

  defp prefix_cache_score_budget_consumed(schedule) do
    case map_value(schedule, :prefix_cache_score_budget_consumed) do
      consumed when is_integer(consumed) and consumed > 0 -> consumed
      _other -> 0
    end
  end

  defp unmanaged_compatibility_schedule?(schedule) do
    case map_value(schedule, :dispatch_capacity_evaluation) do
      %{authority_decision: :unmanaged_compatibility} -> true
      %{"authority_decision" => "unmanaged_compatibility"} -> true
      _other -> false
    end
  end

  defp strip_memory_admission_metadata(schedule) do
    Map.reject(schedule, fn {key, _value} -> memory_admission_metadata_key?(key) end)
  end

  defp memory_admission_metadata_key?(:memory_budget), do: true
  defp memory_admission_metadata_key?("memory_budget"), do: true
  defp memory_admission_metadata_key?(:memory_headroom_ok?), do: true
  defp memory_admission_metadata_key?("memory_headroom_ok?"), do: true
  defp memory_admission_metadata_key?(:memory_admission_enabled), do: true
  defp memory_admission_metadata_key?("memory_admission_enabled"), do: true
  defp memory_admission_metadata_key?(:memory_admission_tier), do: true
  defp memory_admission_metadata_key?("memory_admission_tier"), do: true

  defp memory_admission_metadata_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> memory_admission_metadata_key?()
  end

  defp memory_admission_metadata_key?(key) when is_binary(key) do
    String.starts_with?(key, "selected_memory_")
  end

  defp memory_admission_metadata_key?(_key), do: false

  defp dispatch(db_request, canonical, model, schedule, caller, event_handler, queue_grant) do
    execute_request = build_execute_request(canonical, schedule)
    model_load_request = build_model_load_request(model, schedule)
    on_accepted = build_accepted_callback(queue_grant)

    maybe_mark_grant_node(queue_grant, map_value(schedule, :node_id), promote?: false)

    dispatch_request(
      schedule,
      execute_request,
      model_load_request,
      caller,
      event_handler,
      on_accepted,
      db_request.id,
      queue_grant
    )
  end

  defp dispatch_request(
         schedule,
         execute_request,
         model_load_request,
         caller,
         event_handler,
         on_accepted,
         request_id,
         queue_grant
       ) do
    opts = [
      caller: caller,
      event_handler: event_handler,
      on_accepted: on_accepted,
      on_node_resolved: build_node_resolved_callback(request_id, queue_grant)
    ]

    dispatch = &RequestDispatcher.dispatch/4

    dispatch.(schedule, execute_request, model_load_request, opts)
  rescue
    error ->
      log_warn("dispatch crashed: #{exception_name(error)}")
      {:error, orchestration_crash(:dispatch, {:exception, error})}
  catch
    :exit, _reason ->
      log_warn("dispatch exited")
      {:error, orchestration_crash(:dispatch, :exit)}

    _kind, _reason ->
      log_warn("dispatch threw")
      {:error, orchestration_crash(:dispatch, :throw)}
  end

  defp public_dispatch_reason(%AttemptOutcome{
         failure: %{
           "failure_class" => "model_load_failure",
           "failure_code" => failure_code
         }
       }) do
    {:model_load_failed, ModelLoadFailure.from_model_load_code(failure_code)}
  end

  defp public_dispatch_reason(%AttemptOutcome{
         failure: %{"failure_class" => "pre_acceptance_unavailable"}
       }) do
    {:model_load_failed, ModelLoadFailure.from_model_load_code("runtime_unavailable")}
  end

  defp public_dispatch_reason(%AttemptOutcome{
         attempt_outcome: :timed_out,
         failure: %{"failure_code" => "request_timeout"}
       }),
       do: {:dispatch_failed, :request_timeout}

  defp public_dispatch_reason(%AttemptOutcome{
         attempt_outcome: :cancelled,
         failure: %{"failure_code" => "request_caller_disconnect"}
       }),
       do: {:dispatch_failed, :request_caller_disconnect}

  defp public_dispatch_reason(%AttemptOutcome{failure: %{"failure_code" => failure_code}}),
    do: {:dispatch_failed, failure_code}

  defp build_accepted_callback(queue_grant) do
    fn _request_id, event -> maybe_mark_capacity_source_observed(queue_grant, event) end
  end

  defp maybe_mark_capacity_source_observed(
         %QueueManager.Grant{} = grant,
         %InferenceEvent{event: %InferenceEvent.Accepted{}}
       ) do
    Inference.queue_manager().mark_capacity_source_observed(grant)
  rescue
    error ->
      log_warn("queue capacity source observation failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      log_warn("queue capacity source observation exited: #{inspect(reason)}")
      :ok
  end

  defp maybe_mark_capacity_source_observed(_grant, _event), do: :ok

  defp put_request_validated_context(canonical) do
    if SentryContext.controller_enabled?() do
      SentryContext.add_breadcrumb(
        category: "orchard.request",
        message: "request.validated",
        level: :info,
        data: request_lifecycle_data(canonical)
      )
    end

    :ok
  end

  defp put_request_persisted_context(db_request, canonical) do
    if SentryContext.controller_enabled?() do
      canonical = %{canonical | public_id: db_request.public_id}

      db_request
      |> SentryContext.build_request_extra(canonical)
      |> SentryContext.put_extra()

      SentryContext.put_tags(request_tags(canonical))

      SentryContext.add_breadcrumb(
        category: "orchard.request",
        message: "request.persisted",
        level: :info,
        data: %{orchard_request_id: db_request.public_id}
      )
    end

    :ok
  end

  defp put_request_scheduled_context(schedule) do
    if SentryContext.controller_enabled?() do
      SentryContext.put_tags(%{scheduler_strategy: map_value(schedule, :strategy)})

      SentryContext.add_breadcrumb(
        category: "orchard.request",
        message: "request.scheduled",
        level: :info,
        data: schedule_lifecycle_data(schedule)
      )
    end

    :ok
  end

  defp request_tags(canonical) do
    %{
      orchard_app: "controller",
      orchard_surface: "api",
      orchard_endpoint: canonical.endpoint,
      stream: canonical.stream?,
      tooling: tooling_enabled?(canonical.tooling)
    }
  end

  defp request_lifecycle_data(canonical) do
    %{
      endpoint: canonical.endpoint,
      stream: canonical.stream?,
      tooling: tooling_enabled?(canonical.tooling),
      model_id: canonical.model_ref.model_id,
      model_version: canonical.model_ref.version
    }
  end

  defp schedule_lifecycle_data(schedule) do
    %{}
    |> put_if_present(:scheduler_strategy, map_value(schedule, :strategy))
    |> put_if_present(:node_hash, SentryContext.hash_id(map_value(schedule, :node_id)))
  end

  defp tooling_enabled?(%CanonicalRequest.Tooling{} = tooling) do
    tooling.tools != [] or tooling.requested_tools != [] or not is_nil(tooling.tool_choice)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp build_node_resolved_callback(request_id, queue_grant) do
    fn node_id ->
      case Requests.assign_node(request_id, node_id) do
        {:ok, _} -> :ok
        {:error, reason} -> log_warn("assign_node failed: #{inspect(reason)}")
      end

      maybe_mark_grant_node(queue_grant, node_id, promote?: false)
    end
  end

  defp maybe_mark_grant_node(grant, node_id, opts)

  defp maybe_mark_grant_node(%QueueManager.Grant{} = grant, node_id, opts)
       when is_binary(node_id) and node_id != "",
       do: mark_grant_node_safe(grant, node_id, opts)

  defp maybe_mark_grant_node(_grant, _node_id, _opts), do: :ok

  defp mark_grant_node_safe(grant, node_id, opts) do
    Inference.queue_manager().mark_grant_node(grant, node_id, opts)
  rescue
    error ->
      log_warn("queue grant node reconciliation failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      log_warn("queue grant node reconciliation exited: #{inspect(reason)}")
      :ok
  end

  defp finalize(
         db_request,
         canonical,
         %AttemptOutcome{events: events, first_token_at: first_token_at} = outcome,
         execution_opts,
         %AttemptContext{} = context,
         retry_decision
       ) do
    case build_terminal_attrs(
           canonical,
           events,
           first_token_at,
           execution_opts.success_persistence
         ) do
      {:ok, terminal_attrs} ->
        persist_terminal(
          db_request,
          canonical,
          events,
          terminal_attrs,
          context,
          outcome,
          retry_decision,
          execution_opts.terminal_persister
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_terminal_attrs(canonical, events, first_token_at, success_persistence) do
    terminal_attrs = terminal_attrs_from_events(events)

    result =
      if terminal_attrs.state == :completed and is_function(success_persistence, 2) do
        success_persistence
        |> apply_success_persistence(canonical, events)
        |> merge_success_attrs(terminal_attrs)
      else
        {:ok, terminal_attrs}
      end

    case result do
      {:ok, attrs} -> {:ok, maybe_put_first_token_at(attrs, first_token_at)}
      error -> error
    end
  end

  defp apply_success_persistence(success_persistence, canonical, events) do
    case success_persistence.(canonical, events) do
      attrs when is_map(attrs) -> {:ok, attrs}
      other -> {:error, {:invalid_success_persistence, other}}
    end
  rescue
    error -> {:error, {:success_persistence_failed, {:exception, error}}}
  catch
    :exit, reason -> {:error, {:success_persistence_failed, {:exit, reason}}}
    kind, reason -> {:error, {:success_persistence_failed, {kind, reason}}}
  end

  defp merge_success_attrs({:ok, success_attrs}, terminal_attrs),
    do: {:ok, Map.merge(terminal_attrs, success_attrs)}

  defp merge_success_attrs({:error, reason}, _terminal_attrs),
    do: {:error, reason}

  defp persist_terminal(
         db_request,
         canonical,
         events,
         terminal_attrs,
         %AttemptContext{} = context,
         %AttemptOutcome{} = outcome,
         retry_decision,
         terminal_persister
       ) do
    advance_fsm_best_effort(db_request.id, events, outcome)

    case terminal_persister.(
           db_request,
           terminal_attrs,
           post_observation_terminal_steps(
             db_request,
             canonical,
             events,
             terminal_attrs,
             context,
             outcome,
             retry_decision
           )
         ) do
      {:ok, _updated} ->
        advance_fsm_best_effort_terminal(db_request.id, terminal_attrs.state)
        emit_terminal_metrics(db_request, terminal_attrs.state, terminal_attrs, canonical)
        {:ok, canonical, events}

      {:error, reason} ->
        {:error, {:terminal_persist_failed, reason}}
    end
  end

  defp fail_request(
         db_request,
         reason,
         step_context,
         terminal_persister
       ) do
    terminal_attrs =
      reason
      |> ChatError.from_execute_error()
      |> ChatError.terminal_attrs()

    case terminal_persister.(
           db_request,
           terminal_attrs,
           failure_terminal_steps(db_request, terminal_attrs, step_context)
         ) do
      {:ok, _request} ->
        advance_fsm_best_effort_terminal(db_request.id, terminal_attrs.state)
        DomainMetrics.scheduler_rejection(reason)
        emit_terminal_metrics(db_request, terminal_attrs.state, terminal_attrs)
        :ok

      {:error, persist_reason} ->
        {:error, {:terminal_persist_failed, persist_reason}}
    end
  end

  defp advance_attempt_fsm_best_effort(
         request_id,
         {_owner, %AttemptContext{}, %AttemptOutcome{} = outcome, _decision}
       ) do
    advance_fsm_best_effort(request_id, outcome.events, outcome)
  end

  defp advance_attempt_fsm_best_effort(_request_id, _terminal_evidence), do: :ok

  defp advance_fsm_best_effort(request_id, _events, %AttemptOutcome{} = outcome) do
    if outcome.accepted do
      try_advance(request_id, :running)

      if outcome.output_committed do
        try_advance(request_id, :streaming)
      end
    end
  end

  defp advance_fsm_best_effort_terminal(request_id, state) do
    try_advance_terminal(request_id, state)
  end

  defp try_advance(request_id, state) do
    case advance_fsm(request_id, state) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :already_terminal} -> :ok
      {:error, error} -> log_warn("FSM advance to #{state} failed: #{inspect(error)}")
    end
  end

  defp try_advance_terminal(request_id, state) do
    case advance_fsm(request_id, state) do
      :ok -> :ok
      {:error, :not_found} -> append_terminal_state_event(request_id, state)
      {:error, :already_terminal} -> :ok
      {:error, error} -> log_warn("FSM terminal advance to #{state} failed: #{inspect(error)}")
    end
  end

  defp append_terminal_state_event(request_id, state) do
    attrs = %{
      event_type: "state_transition",
      state: state,
      payload: %{to_state: to_string(state), source: "request_orchestrator_terminal_fallback"}
    }

    case Requests.append_request_event(request_id, attrs) do
      {:ok, _event} ->
        :ok

      {:error, error} ->
        log_warn("FSM terminal fallback event for #{state} failed: #{inspect(error)}")
    end
  end

  defp terminal_attrs_from_events(events) do
    usage = extract_usage(events)

    base_attrs =
      case Enum.find(events, &InferenceEvent.terminal?/1) do
        nil ->
          terminal_conformance_failure_attrs(
            "runtime_endpoint_missing_terminal",
            "Runtime Endpoint stream ended without a terminal event"
          )

        %{event: %InferenceEvent.Completed{}} ->
          %{state: :completed, http_status: 200}

        %{event: %InferenceEvent.Failed{}} = event ->
          event
          |> ChatError.from_failed_event()
          |> ChatError.terminal_attrs()
      end

    Map.merge(base_attrs, usage)
  end

  defp terminal_conformance_failure_attrs(code, message) do
    code
    |> InferenceEvent.failed(message, false)
    |> ChatError.from_failed_event()
    |> ChatError.terminal_attrs()
  end

  defp inference_turn_step_context(canonical, attempt \\ 1, excluded_node_ids \\ []) do
    {:ok, context} =
      AttemptContext.new(%{
        turn_index: 1,
        attempt: attempt,
        excluded_node_ids: excluded_node_ids,
        model_id: canonical.model_ref.model_id,
        model_version: canonical.model_ref.version
      })

    context
  end

  defp persist_inference_turn_started(db_request, step_context, step_event_appender) do
    case step_event_appender.(db_request, [inference_turn_started_step(step_context)]) do
      {:ok, _step_events} -> {:ok, step_context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_observation_terminal_steps(
         db_request,
         canonical,
         events,
         terminal_attrs,
         %AttemptContext{} = context,
         %AttemptOutcome{} = outcome,
         retry_decision
       ) do
    build_tool_call_proposed_steps(canonical, events, context) ++
      [
        terminal_inference_turn_step(
          db_request,
          events,
          terminal_attrs,
          context,
          outcome,
          retry_decision
        )
      ]
  end

  defp failure_terminal_steps(_db_request, _terminal_attrs, nil), do: []

  defp failure_terminal_steps(
         db_request,
         terminal_attrs,
         {_owner, %AttemptContext{} = context, %AttemptOutcome{} = outcome, retry_decision}
       ) do
    [
      terminal_inference_turn_step(
        db_request,
        [],
        terminal_attrs,
        context,
        outcome,
        retry_decision
      )
    ]
  end

  defp inference_turn_started_step(step_context) do
    %{
      event_type: "request_step.started",
      step_id: step_context.step_id,
      step_type: "inference_turn",
      turn_index: step_context.turn_index,
      attempt: step_context.attempt,
      parent_step_id: nil,
      boundary: "pre_side_effect",
      result: %{},
      model_id: step_context.model_id,
      model_version: step_context.model_version
    }
  end

  defp terminal_inference_turn_step(
         db_request,
         events,
         terminal_attrs,
         %AttemptContext{} = context,
         %AttemptOutcome{} = outcome,
         retry_decision
       ) do
    event_type = RequestStepEvent.terminal_step_event_type!(terminal_attrs.state)

    %{
      event_type: event_type,
      step_id: context.step_id,
      step_type: "inference_turn",
      turn_index: context.turn_index,
      attempt: context.attempt,
      parent_step_id: nil,
      boundary: "post_observation",
      result:
        terminal_step_result(
          db_request,
          events,
          terminal_attrs,
          context,
          outcome,
          retry_decision,
          event_type
        ),
      model_id: context.model_id,
      model_version: context.model_version
    }
  end

  defp build_tool_call_proposed_steps(canonical, events, step_context) do
    case terminal_finish_reason(events) do
      "tool_calls" = finish_reason ->
        accumulate_tool_call_proposals(canonical, events, step_context, finish_reason)

      _other ->
        []
    end
  end

  defp accumulate_tool_call_proposals(canonical, events, step_context, finish_reason) do
    case ToolCallAccumulator.from_events(events) do
      {:ok, accumulator} ->
        accumulator
        |> ToolCallAccumulator.chat_tool_calls()
        |> Enum.map(fn tool_call ->
          tool_call_proposed_step(canonical, tool_call, step_context, finish_reason)
        end)

      {:error, reason} ->
        log_warn("tool call proposal reconstruction failed: #{inspect(reason)}")
        []
    end
  end

  defp tool_call_proposed_step(canonical, tool_call, step_context, finish_reason) do
    tool_call_id = map_value(tool_call, :id)
    function = map_value(tool_call, :function)

    %{
      event_type: "request_step.proposed",
      step_id: RequestStepEvent.tool_call_step_id(step_context.turn_index, tool_call_id),
      step_type: "tool_call",
      turn_index: step_context.turn_index,
      attempt: step_context.attempt,
      parent_step_id: step_context.step_id,
      boundary: "post_observation",
      result: %{"finish_reason" => finish_reason},
      call_id: tool_call_id,
      tool_name: map_value(function || %{}, :name),
      arguments_json: map_value(function || %{}, :arguments),
      model_id: canonical.model_ref.model_id,
      model_version: canonical.model_ref.version
    }
  end

  defp terminal_step_result(
         db_request,
         events,
         terminal_attrs,
         %AttemptContext{} = context,
         %AttemptOutcome{} = outcome,
         retry_decision,
         event_type
       ) do
    result =
      outcome
      |> attempt_result_fields(db_request, context, retry_decision)
      |> Map.merge(legacy_terminal_step_result(events, terminal_attrs))

    {:ok, normalized} = InferenceAttemptResult.new(event_type, context.attempt, result)
    normalized
  end

  defp legacy_terminal_step_result(events, terminal_attrs) do
    %{}
    |> maybe_put_result("finish_reason", terminal_finish_reason(events))
    |> maybe_put_result("input_tokens", Map.get(terminal_attrs, :input_tokens))
    |> maybe_put_result("output_tokens", Map.get(terminal_attrs, :output_tokens))
    |> maybe_put_result("error_message", Map.get(terminal_attrs, :error_message))
    |> maybe_put_result("http_status", Map.get(terminal_attrs, :http_status))
  end

  defp attempt_result_fields(
         %AttemptOutcome{} = outcome,
         _db_request,
         %AttemptContext{} = context,
         retry_decision
       ) do
    base = %{
      "attempt_outcome" => Atom.to_string(outcome.attempt_outcome),
      "started_at" => outcome.started_at,
      "ended_at" => outcome.ended_at,
      "accepted" => outcome.accepted,
      "output_committed" => outcome.output_committed,
      "execution_resolution" => Atom.to_string(outcome.execution_resolution),
      "capacity_release_outcome" => Atom.to_string(outcome.capacity_release_outcome),
      "excluded_node_ids" => context.excluded_node_ids
    }

    base
    |> maybe_put_result(
      "output_commitment_kind",
      commitment_kind_string(outcome.output_commitment_kind)
    )
    |> maybe_put_result("node_id", outcome.node_id)
    |> put_attempt_failure(outcome, retry_decision)
  end

  defp put_attempt_failure(
         result,
         %AttemptOutcome{attempt_outcome: :completed},
         nil
       ),
       do: result

  defp put_attempt_failure(
         result,
         %AttemptOutcome{failure: failure} = outcome,
         retry_decision
       )
       when is_atom(retry_decision) do
    result
    |> Map.merge(failure)
    |> maybe_put_result("runtime_retryable", outcome.runtime_retryable)
    |> Map.put("retry_decision", Atom.to_string(retry_decision))
  end

  defp commitment_kind_string(nil), do: nil
  defp commitment_kind_string(kind), do: Atom.to_string(kind)

  defp terminal_finish_reason(events) do
    case Enum.find(events, &(InferenceEvent.kind(&1) == :completed)) do
      %{event: %InferenceEvent.Completed{finish_reason: finish_reason}} ->
        map_finish_reason(finish_reason)

      _other ->
        nil
    end
  end

  defp map_finish_reason(:finish_reason_stop), do: "stop"
  defp map_finish_reason(:finish_reason_length), do: "length"
  defp map_finish_reason(:finish_reason_tool_calls), do: "tool_calls"
  defp map_finish_reason(:finish_reason_unspecified), do: "stop"
  defp map_finish_reason(_other), do: "stop"

  defp maybe_put_result(result, _key, nil), do: result
  defp maybe_put_result(result, key, value), do: Map.put(result, key, value)

  defp maybe_put_first_token_at(attrs, nil), do: attrs
  defp maybe_put_first_token_at(attrs, %DateTime{} = ts), do: Map.put(attrs, :first_token_at, ts)

  defp extract_usage(events) do
    case EventUsage.find(events) do
      nil ->
        %{input_tokens: 0, output_tokens: 0}

      usage ->
        %{input_tokens: usage.input_tokens, output_tokens: usage.output_tokens}
    end
  end

  defp build_execute_request(canonical, schedule) do
    deadline_ms =
      schedule
      |> Map.fetch!(:timeout_at)
      |> DateTime.to_unix(:millisecond)

    %ExecuteInferenceRequest{
      request_id: canonical.public_id,
      controller_session_id: canonical.internal_id,
      model_id: canonical.model_ref.model_id,
      version: canonical.model_ref.version,
      rendered_prompt_utf8: canonical.rendered_prompt,
      input_tokens: canonical.input_token_count,
      params: build_generation_params(canonical),
      deadline_unix_ms: deadline_ms,
      metadata_json: Jason.encode!(canonical.metadata),
      prompt_token_ids: canonical.prompt_token_ids || []
    }
    |> maybe_put_cache_affinity_fingerprint(canonical)
  end

  defp maybe_put_cache_affinity_fingerprint(execute_request, canonical) do
    cache_affinity_config = Inference.cache_affinity_config()

    if CacheAffinity.live_fingerprint_match_enabled?(cache_affinity_config) do
      put_cache_affinity_fingerprint(execute_request, canonical, cache_affinity_config)
    else
      execute_request
    end
  end

  defp put_cache_affinity_fingerprint(execute_request, canonical, cache_affinity_config) do
    case CacheAffinity.derive_key(canonical, cache_affinity_config) do
      {:ok, fingerprint} -> %{execute_request | cache_affinity_fingerprint: fingerprint}
      :unavailable -> execute_request
    end
  end

  defp build_model_load_request(model, schedule) do
    node_id =
      case Map.get(schedule, :node_id) do
        uuid when is_binary(uuid) -> uuid
        _ -> ""
      end

    %EnsureModelLoadedRequest{
      node_id: node_id,
      model_id: model.model_id,
      version: model.version,
      artifact_sha256: model.artifact_sha256,
      preload: false,
      # Sentinel: the effective load-operation deadline is set by
      # RequestDispatcher from the cold-start stage cap, not the absolute
      # Request deadline. A value of 0 is not a real deadline; the dispatcher
      # must overwrite it before any transport call is made.
      deadline_unix_ms: 0,
      artifact_source_uri: model.artifact_source_uri || ""
    }
  end

  defp build_generation_params(%CanonicalRequest{sampling: sampling, tooling: tooling}) do
    {tools_json, tool_choice_json} = serialize_tooling(tooling)

    %GenerationParams{
      max_output_tokens: effective_max_output_tokens(sampling),
      temperature: sampling.temperature,
      top_p: sampling.top_p,
      stop_sequences: sampling.stop,
      tools_json: tools_json,
      tool_choice_json: tool_choice_json
    }
  end

  defp validate_resolved_tooling(%CanonicalRequest{tooling: tooling}) do
    case unresolved_tooling_reason(tooling) do
      nil -> :ok
      reason -> {:error, {:invalid_canonical_tooling, reason}}
    end
  end

  defp unresolved_tooling_reason(%CanonicalRequest.Tooling{} = tooling) do
    cond do
      unresolved_runtime_tools?(tooling.tools) ->
        "tooling.tools must contain resolved function definitions only"

      unresolved_requested_refs?(tooling.requested_tools) and
          unresolved_registry_snapshot?(tooling.requested_tools, tooling.registry_snapshot) ->
        "tool registry refs must be resolved before execute/3"

      requested_tools_present?(tooling.requested_tools) and
          not requested_tooling_aligned?(tooling) ->
        "requested_tools, registry_snapshot, and tooling.tools must stay aligned"

      not execution_snapshot_aligned?(tooling) ->
        "execution_snapshot must stay aligned with requested_tools, registry_snapshot, and tooling.tools"

      true ->
        nil
    end
  end

  defp unresolved_runtime_tools?(tools) when is_list(tools) do
    Enum.any?(tools, &ref_tool?/1)
  end

  defp unresolved_runtime_tools?(_tools), do: false

  defp unresolved_requested_refs?(requested_tools) when is_list(requested_tools) do
    requested_tool_refs(requested_tools) != []
  end

  defp unresolved_requested_refs?(_requested_tools), do: false

  defp requested_tools_present?(requested_tools) when is_list(requested_tools),
    do: requested_tools != []

  defp requested_tools_present?(_requested_tools), do: false

  defp unresolved_registry_snapshot?(requested_tools, registry_snapshot) do
    requested_refs = requested_tool_refs(requested_tools)

    case registry_snapshot_refs(registry_snapshot) do
      {:ok, snapshot_refs} -> snapshot_refs != requested_refs
      :error -> true
    end
  end

  defp requested_tooling_aligned?(%CanonicalRequest.Tooling{} = tooling) do
    requested_tools = tooling.requested_tools
    runtime_tools = tooling.tools

    is_list(runtime_tools) and
      length(requested_tools) == length(runtime_tools) and
      requested_tools_match_runtime?(requested_tools, runtime_tools) and
      requested_refs_match_snapshot_and_runtime?(
        requested_tools,
        runtime_tools,
        tooling.registry_snapshot
      )
  end

  defp requested_tools_match_runtime?(requested_tools, runtime_tools) do
    requested_tools
    |> Enum.zip(runtime_tools)
    |> Enum.all?(fn {requested_tool, runtime_tool} ->
      case requested_tool_identity(requested_tool) do
        {:inline, requested_name} -> requested_name == runtime_tool_name(runtime_tool)
        {:ref, _requested_ref} -> is_binary(runtime_tool_name(runtime_tool))
        :error -> false
      end
    end)
  end

  defp requested_refs_match_snapshot_and_runtime?(
         requested_tools,
         runtime_tools,
         registry_snapshot
       ) do
    case requested_tool_refs(requested_tools) do
      [] ->
        inline_requested_tools_match_snapshot?(registry_snapshot)

      _requested_refs ->
        requested_refs_match_snapshot_entries?(requested_tools, runtime_tools, registry_snapshot)
    end
  end

  defp inline_requested_tools_match_snapshot?(registry_snapshot) do
    match?({:ok, []}, registry_snapshot_entries(registry_snapshot))
  end

  defp requested_refs_match_snapshot_entries?(requested_tools, runtime_tools, registry_snapshot) do
    with {:ok, registry_entries} <- registry_snapshot_entries(registry_snapshot),
         {:ok, []} <- consume_registry_entries(requested_tools, runtime_tools, registry_entries) do
      true
    else
      _other -> false
    end
  end

  defp consume_registry_entries(requested_tools, runtime_tools, registry_entries) do
    requested_tools
    |> Enum.zip(runtime_tools)
    |> Enum.reduce_while({:ok, registry_entries}, &consume_registry_entry/2)
  end

  defp consume_registry_entry({requested_tool, runtime_tool}, {:ok, entries}) do
    case requested_tool_identity(requested_tool) do
      {:inline, _requested_name} -> {:cont, {:ok, entries}}
      {:ref, requested_ref} -> consume_ref_registry_entry(entries, requested_ref, runtime_tool)
      :error -> {:halt, :error}
    end
  end

  defp consume_ref_registry_entry([entry | rest], requested_ref, runtime_tool) do
    if registry_entry_matches_runtime?(entry, requested_ref, runtime_tool) do
      {:cont, {:ok, rest}}
    else
      {:halt, :error}
    end
  end

  defp consume_ref_registry_entry([], _requested_ref, _runtime_tool), do: {:halt, :error}

  defp registry_entry_matches_runtime?(entry, requested_ref, runtime_tool) do
    runtime_name = runtime_tool_name(runtime_tool)

    map_value(entry, :ref) == requested_ref and map_value(entry, :name) == runtime_name and
      is_binary(runtime_name)
  end

  defp requested_tool_refs(requested_tools) when is_list(requested_tools) do
    Enum.flat_map(requested_tools, fn tool ->
      case map_value(tool, :ref) do
        ref when is_binary(ref) -> [ref]
        _other -> []
      end
    end)
  end

  defp requested_tool_refs(_requested_tools), do: []

  defp requested_tool_identity(tool) when is_map(tool) do
    ref = map_value(tool, :ref)
    name = tool |> map_value(:function) |> function_name()
    has_ref? = map_has_key?(tool, :ref)
    has_function? = map_has_key?(tool, :function)

    cond do
      has_ref? and has_function? -> :error
      has_ref? and is_binary(ref) -> {:ref, ref}
      has_function? and is_binary(name) -> {:inline, name}
      true -> :error
    end
  end

  defp requested_tool_identity(_tool), do: :error

  defp runtime_tool_name(tool) when is_map(tool) do
    if is_nil(map_value(tool, :ref)) do
      tool |> map_value(:function) |> function_name()
    else
      nil
    end
  end

  defp runtime_tool_name(_tool), do: nil

  defp function_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp function_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp function_name(_function), do: nil

  defp registry_snapshot_entries(%{entries: entries}) when is_list(entries), do: {:ok, entries}

  defp registry_snapshot_entries(%{"entries" => entries}) when is_list(entries),
    do: {:ok, entries}

  defp registry_snapshot_entries(_registry_snapshot), do: :error

  defp registry_snapshot_refs(%{entries: entries}), do: registry_snapshot_refs(entries)
  defp registry_snapshot_refs(%{"entries" => entries}), do: registry_snapshot_refs(entries)

  defp registry_snapshot_refs(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, refs} ->
      case map_value(entry, :ref) do
        ref when is_binary(ref) -> {:cont, {:ok, [ref | refs]}}
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      :error -> :error
    end
  end

  defp registry_snapshot_refs(_registry_snapshot), do: :error

  defp execution_snapshot_aligned?(%CanonicalRequest.Tooling{} = tooling) do
    case ToolExecutionSemantics.build(tooling) do
      {:ok, expected_snapshot} -> snapshots_match?(tooling.execution_snapshot, expected_snapshot)
      {:error, _reason} -> false
    end
  end

  defp snapshots_match?(%{entries: actual_entries}, %{entries: expected_entries})
       when is_list(actual_entries) and is_list(expected_entries) do
    length(actual_entries) == length(expected_entries) and
      Enum.zip(actual_entries, expected_entries)
      |> Enum.all?(fn {actual_entry, expected_entry} ->
        snapshot_entry_matches?(actual_entry, expected_entry)
      end)
  end

  defp snapshot_entry_matches?(actual_entry, expected_entry) when is_map(actual_entry) do
    Enum.all?([:name, :provenance, :disposition, :execution_mode], fn key ->
      normalized_snapshot_value(actual_entry, key) ==
        normalized_snapshot_value(expected_entry, key)
    end)
  end

  defp snapshot_entry_matches?(_actual_entry, _expected_entry), do: false

  defp normalized_snapshot_value(entry, key) do
    case map_value(entry, key) do
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp ref_tool?(tool) when is_map(tool) do
    match?(value when is_binary(value), map_value(tool, :ref))
  end

  defp ref_tool?(_tool), do: false

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_has_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp serialize_tooling(%CanonicalRequest.Tooling{tools: tools, tool_choice: tool_choice}) do
    if ToolingValidation.effective_tool_calling?(tools, tool_choice) do
      {Jason.encode!(tools), serialize_tool_choice(tool_choice)}
    else
      {"", ""}
    end
  end

  defp serialize_tool_choice(nil), do: ""
  defp serialize_tool_choice(tool_choice), do: Jason.encode!(tool_choice)

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{max_output_tokens: value})
       when is_integer(value) and value > 0,
       do: value

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{}), do: 4096

  defp serialize_canonical_request(canonical) do
    {:ok, CanonicalRequestSerializer.serialize(canonical)}
  rescue
    error in ArgumentError ->
      log_warn("canonical_request serialization failed: #{Exception.message(error)}")
      {:error, {:canonical_request_serialization_failed, Exception.message(error)}}
  end

  defp orchestration_crash(phase, {:exception, error}) do
    {:orchestration_crash,
     %{phase: phase, category: :exception, exception: exception_name(error)}}
  end

  defp orchestration_crash(phase, category) do
    {:orchestration_crash, %{phase: phase, category: category}}
  end

  defp exception_name(%{__struct__: module}) when is_atom(module), do: Atom.to_string(module)

  defp maybe_emit_tenant_quota_rejection(db_request, metadata, :queue_timeout) do
    queue_wait_reason =
      Map.get(metadata, :queue_wait_reason) || Map.get(metadata, "queue_wait_reason")

    if queue_wait_reason in [:tenant_active_capacity, "tenant_active_capacity"] do
      DomainMetrics.quota_rejection(db_request.tenant_id, :tenant_concurrency)
    end

    :ok
  end

  defp maybe_emit_tenant_quota_rejection(_db_request, _metadata, _reason), do: :ok

  defp emit_terminal_metrics(db_request, status, attrs \\ %{}, canonical \\ nil) do
    DomainMetrics.inference_terminal(
      db_request.endpoint,
      db_request.tenant_id,
      terminal_model_id(db_request, canonical),
      status,
      request_duration_seconds(),
      terminal_output_tokens(attrs, db_request)
    )

    emit_attempt_metrics(db_request)
  end

  defp emit_attempt_metrics(db_request) do
    result =
      db_request
      |> Requests.list_request_step_events()
      |> InferenceAttemptProjection.project()

    case result do
      {:ok, projection} -> emit_attempt_projection(projection)
      {:error, reason} -> Status.degrade({:inference_attempt_projection, reason})
    end
  rescue
    _exception -> Status.degrade({:inference_attempt_projection, :unavailable})
  catch
    _kind, _reason -> Status.degrade({:inference_attempt_projection, :unavailable})
  end

  defp emit_attempt_projection(projection) do
    Enum.each(projection.attempts, fn attempt ->
      DomainMetrics.inference_attempt(
        attempt.attempt,
        attempt.outcome,
        attempt.failure_class,
        attempt.duration_seconds
      )
    end)

    case projection.retry do
      %{reason: reason, result: result} -> DomainMetrics.inference_retry(reason, result)
      nil -> :ok
    end
  end

  defp terminal_model_id(_db_request, %CanonicalRequest{} = canonical),
    do: canonical.model_ref.model_id

  defp terminal_model_id(db_request, nil) do
    get_in(db_request.canonical_request, ["model_ref", "model_id"]) ||
      Request.canonical_model_id(db_request.requested_model)
  end

  defp terminal_output_tokens(attrs, db_request) do
    case Map.get(attrs, :output_tokens, db_request.output_tokens) do
      tokens when is_integer(tokens) and tokens >= 0 -> tokens
      _other -> 0
    end
  end

  defp request_duration_seconds do
    case Process.get({__MODULE__, :metrics_started_at}) do
      started_at when is_integer(started_at) ->
        System.monotonic_time()
        |> Kernel.-(started_at)
        |> System.convert_time_unit(:native, :nanosecond)
        |> Kernel./(1_000_000_000)

      _missing ->
        0.0
    end
  end

  defp terminal_status_for_queue_reason(:queue_timeout), do: :timed_out
  defp terminal_status_for_queue_reason(:request_caller_disconnect), do: :cancelled
  defp terminal_status_for_queue_reason(:request_controller_restarted), do: :interrupted
  defp terminal_status_for_queue_reason(_reason), do: :failed

  defp restore_metrics_started_at(nil), do: Process.delete({__MODULE__, :metrics_started_at})

  defp restore_metrics_started_at(previous_started_at) do
    Process.put({__MODULE__, :metrics_started_at}, previous_started_at)
    :ok
  end

  defp log_warn(message) do
    require Logger
    Logger.warning("[RequestOrchestrator] #{message}")
  end

  defp log_error(message) do
    require Logger
    Logger.error("[RequestOrchestrator] #{message}")
  end
end
