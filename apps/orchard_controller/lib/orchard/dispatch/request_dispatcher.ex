defmodule Orchard.Dispatch.RequestDispatcher do
  @moduledoc """
  Orchestrates the dispatch of an inference request to a node-agent.

  Implements the current node-agent dispatch flow:

    schedule → connect → ensure_model_loaded → execute_inference → stream events

  Monitors for:
  - Request timeout → sends CancelInference to the node
  - Caller process exit → sends CancelInference to the node

  Transport failures during connect, pre-dispatch status, model load, or stream
  execution are recorded through node inventory so stale capacity for the failed
  target is cleared.

  Timing instrumentation logs one 'dispatch_timing' line per dispatch attempt,
  capturing cold/warm classification, stream timing, and outcome.
  """

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest
  }

  alias Orchard.Inference
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.{GrpcCompatibilityMapper, Observation, Operation, Target}
  alias Orchard.SentryContext
  alias Orchard.Tokenizer.Telemetry

  require Logger

  # Metrics structure for timing instrumentation
  defmodule Metrics do
    @moduledoc false

    defstruct request_id: nil,
              model_id: "unknown",
              version: "unknown",
              input_tokens: 0,
              node_id: nil,
              scheduler_strategy: nil,
              model_already_loaded: :unknown,
              ensure_model_loaded_ms: :na,
              accepted_monotonic_ms: nil,
              first_delta_monotonic_ms: nil,
              terminal_monotonic_ms: nil,
              accepted_to_first_delta_ms: :na,
              accepted_to_terminal_ms: :na,
              outcome: :ok,
              terminal_kind: :none,
              terminal_source: :none,
              terminal_detail: :na,
              event_count: 0,
              anomaly: :none

    @type t :: %__MODULE__{
            request_id: String.t(),
            model_id: String.t(),
            version: String.t(),
            input_tokens: non_neg_integer(),
            node_id: String.t() | nil,
            scheduler_strategy: atom() | String.t() | nil,
            model_already_loaded: boolean() | :unknown,
            ensure_model_loaded_ms: non_neg_integer() | :na,
            accepted_monotonic_ms: integer() | nil,
            first_delta_monotonic_ms: integer() | nil,
            terminal_monotonic_ms: integer() | nil,
            accepted_to_first_delta_ms: non_neg_integer() | :na,
            accepted_to_terminal_ms: non_neg_integer() | :na,
            outcome: :ok | :model_load_failed | :dispatch_failed,
            terminal_kind: :completed | :failed | :none,
            terminal_source: :stream | :synthesized | :none,
            terminal_detail: String.t() | :na,
            event_count: non_neg_integer(),
            anomaly: :none | :delta_before_accepted | :terminal_before_accepted
          }

    @spec new(keyword()) :: t()
    def new(opts) do
      %__MODULE__{
        request_id: Keyword.fetch!(opts, :request_id),
        model_id: Keyword.get(opts, :model_id, "unknown"),
        version: Keyword.get(opts, :version, "unknown"),
        input_tokens: Keyword.get(opts, :input_tokens, 0),
        node_id: Keyword.get(opts, :node_id),
        scheduler_strategy: Keyword.get(opts, :scheduler_strategy),
        model_already_loaded: :unknown,
        ensure_model_loaded_ms: :na,
        accepted_monotonic_ms: nil,
        first_delta_monotonic_ms: nil,
        terminal_monotonic_ms: nil,
        accepted_to_first_delta_ms: :na,
        accepted_to_terminal_ms: :na,
        outcome: :ok,
        terminal_kind: :none,
        terminal_source: :none,
        terminal_detail: :na,
        event_count: 0,
        anomaly: :none
      }
    end
  end

  @status_probe_timeout_ms 1_000

  if Mix.env() == :test do
    # Test-only seam for terminal-source gating. This avoids sleeping through
    # timeout/cancel paths just to exercise :stream vs. :synthesized telemetry behavior.
    @spec __test_metrics__(map()) :: Metrics.t()
    def __test_metrics__(attrs \\ %{}) when is_map(attrs) do
      struct!(Metrics, attrs)
    end

    @spec __test_update_metrics_for_terminal__(Metrics.t(), InferenceEvent.t(), atom()) ::
            Metrics.t()
    def __test_update_metrics_for_terminal__(
          %Metrics{} = metrics,
          %InferenceEvent{} = event,
          source
        ) do
      update_metrics_for_terminal(metrics, event, source)
    end
  end

  @type dispatch_result ::
          {:ok, [InferenceEvent.t()]}
          | {:error,
             {:model_load_failed, ModelLoadFailure.t()} | {:dispatch_failed, term()} | term()}

  @doc """
  Dispatch an inference request to a Runtime Endpoint and stream events back to the caller.

  `schedule` is the map returned by the configured scheduler containing:
  - `:runtime_endpoint_target` - typed Runtime Endpoint target for new schedulers
  - `:runtime_client_target` - legacy `[host: ..., port: ...]` gRPC compatibility target
  - `:request_id` - the canonical request ID
  - `:request_timeout_ms` - maximum wall-clock time for the entire dispatch

  `execute_request` is the protobuf compatibility `ExecuteInferenceRequest` to map into a Runtime Endpoint operation.

  `model_load_request` is the protobuf compatibility `EnsureModelLoadedRequest` to map into a Runtime Endpoint operation.

  Options:
  - `:caller` - PID to monitor for disconnect (default: `self()`)
  - `:event_handler` - function called with each `InferenceEvent`.
                        Return `:cancel` to abort dispatch (e.g. on SSE client disconnect).
                        (default: sends `{:inference_event, request_id, event}` to caller)
  - `:on_node_resolved` - optional callback `(node_id :: String.t() -> any())`.
                           Called when the pre-dispatch status probe discovers a
                           valid node UUID. Synchronous, lightweight, observational only.
                           Exceptions and exits are logged and ignored; return value is ignored.
  - `:client_impl` - Runtime Endpoint client module
                     (default: `Inference.runtime_endpoint_client/0`)

  Returns `{:ok, events}` with the list of all events received (including terminal),
  or `{:error, reason}` if dispatch fails before streaming begins.
  """
  @spec dispatch(
          schedule :: map(),
          execute_request :: ExecuteInferenceRequest.t(),
          model_load_request :: EnsureModelLoadedRequest.t(),
          opts :: keyword()
        ) :: dispatch_result()
  def dispatch(
        schedule,
        %ExecuteInferenceRequest{} = execute_request,
        %EnsureModelLoadedRequest{} = model_load_request,
        opts \\ []
      ) do
    target = runtime_endpoint_target(schedule)
    request_id = Map.fetch!(schedule, :request_id)
    timeout_ms = Map.fetch!(schedule, :request_timeout_ms)
    model_load_timeout = Map.get(schedule, :model_load_timeout_ms, 120_000)
    caller = Keyword.get(opts, :caller, self())
    event_handler = Keyword.get(opts, :event_handler)
    on_node_resolved = Keyword.get(opts, :on_node_resolved)
    client = Keyword.get(opts, :client_impl, Inference.runtime_endpoint_client())

    # Initialize timing metrics
    metrics =
      Metrics.new(
        request_id: request_id,
        model_id: model_load_request.model_id,
        version: model_load_request.version,
        input_tokens: execute_request.input_tokens,
        scheduler_strategy: Map.get(schedule, :strategy)
      )

    put_dispatch_base_context(metrics)

    context = %{
      client: client,
      target: target,
      schedule: schedule,
      execute_request: execute_request,
      model_load_request: model_load_request,
      metrics: metrics,
      model_load_timeout: model_load_timeout,
      timeout_ms: timeout_ms,
      caller: caller,
      event_handler: event_handler,
      on_node_resolved: on_node_resolved
    }

    case preensure_prompt_token_ids_gate(execute_request, schedule, model_load_request) do
      :ok ->
        dispatch_after_preensure_gate(context)

      {:error, reason} ->
        error_metrics = finalize_metrics(metrics, {:error, {:dispatch_failed, reason}})
        put_dispatch_terminal_context(error_metrics, target)
        emit_timing_log(error_metrics, {:error, {:dispatch_failed, reason}})
        {:error, {:dispatch_failed, reason}}
    end
  end

  # -- Private ---------------------------------------------------------------

  defp dispatch_after_preensure_gate(%{client: client, target: target} = context) do
    case client.connect(target) do
      {:ok, channel} ->
        dispatch_with_channel(Map.put(context, :channel, channel))

      {:error, reason} ->
        handle_dispatch_connect_failure(target, reason, context.metrics)
    end
  end

  defp dispatch_with_channel(%{client: client, channel: channel} = context) do
    do_dispatch_with_channel(context)
  after
    disconnect_best_effort(client, channel)
  end

  defp disconnect_best_effort(client, channel) do
    client.disconnect(channel)
    :ok
  rescue
    error ->
      Logger.warning("Runtime endpoint disconnect failed: #{exception_name(error)}")
      :ok
  catch
    :exit, _reason ->
      Logger.warning("Runtime endpoint disconnect exited")
      :ok

    _kind, _reason ->
      Logger.warning("Runtime endpoint disconnect threw")
      :ok
  end

  defp do_dispatch_with_channel(%{} = context) do
    {model_load_request, metrics} =
      probe_and_resolve_node(
        context.client,
        context.channel,
        context.target,
        context.model_load_request,
        context.on_node_resolved,
        context.metrics
      )

    context = %{context | model_load_request: model_load_request, metrics: metrics}
    ensure_start = System.monotonic_time(:millisecond)
    put_ensure_model_load_started_context(metrics)

    context.client
    |> ensure_loaded_for_dispatch(
      context.channel,
      context.target,
      model_load_request,
      context.model_load_timeout
    )
    |> handle_ensure_result(context, ensure_start)
  end

  defp ensure_loaded_for_dispatch(client, channel, target, model_load_request, model_load_timeout) do
    do_ensure_model_loaded(client, channel, target, model_load_request, model_load_timeout)
  end

  defp handle_ensure_result({:ok, ensure_load_meta}, context, ensure_start) do
    ensure_end = System.monotonic_time(:millisecond)

    metrics = %{
      context.metrics
      | ensure_model_loaded_ms: ensure_end - ensure_start,
        model_already_loaded: ensure_load_meta.already_loaded
    }

    put_ensure_model_load_completed_context(metrics)

    result =
      case gate_prompt_token_ids(
             context.execute_request,
             ensure_load_meta,
             context.schedule,
             context.model_load_request
           ) do
        {:ok, gated_execute_request} ->
          do_execute_and_stream(
            context.client,
            context.channel,
            context.target,
            gated_execute_request,
            metrics,
            context.timeout_ms,
            context.caller,
            context.event_handler
          )

        {:error, reason} ->
          {:error, {:dispatch_failed, reason}}
      end

    handle_dispatch_result(result, metrics, context.target)
  end

  defp handle_ensure_result({:error, reason}, context, ensure_start) do
    ensure_end = System.monotonic_time(:millisecond)

    metrics = %{
      context.metrics
      | ensure_model_loaded_ms: ensure_end - ensure_start,
        model_already_loaded: false
    }

    error_metrics = finalize_metrics(metrics, {:error, {:model_load_failed, reason}})
    put_dispatch_terminal_context(error_metrics, context.target)
    emit_timing_log(error_metrics, {:error, {:model_load_failed, reason}})
    {:error, {:model_load_failed, reason}}
  end

  defp handle_dispatch_result({:ok, events, final_metrics}, _metrics, target) do
    final_metrics = finalize_metrics(final_metrics, :ok)
    put_dispatch_terminal_context(final_metrics, target)
    emit_timing_log(final_metrics, :ok)
    {:ok, events}
  end

  defp handle_dispatch_result({:error, reason}, metrics, target) do
    error_metrics = finalize_metrics(metrics, {:error, reason})
    put_dispatch_terminal_context(error_metrics, target)
    emit_timing_log(error_metrics, {:error, reason})
    {:error, reason}
  end

  defp handle_dispatch_connect_failure(target, reason, metrics) do
    mark_transport_failure(target, reason)

    error_metrics = finalize_metrics(metrics, {:error, {:model_load_failed, :node_unavailable}})
    put_dispatch_terminal_context(error_metrics, target)
    emit_timing_log(error_metrics, {:error, {:model_load_failed, :node_unavailable}})

    {:error, {:model_load_failed, ModelLoadFailure.from_transport_reason(:node_unavailable)}}
  end

  # Pre-dispatch status probe: best-effort node identity resolution.
  # Never aborts dispatch on failure.
  defp probe_and_resolve_node(
         client,
         channel,
         target,
         model_load_request,
         on_node_resolved,
         metrics
       ) do
    case client.status(channel, timeout: @status_probe_timeout_ms) do
      {:ok, response} ->
        observed_at = DateTime.utc_now()
        observation = normalize_status_observation(target, response)

        {resolved_node_id, model_load_request, metrics} =
          case extract_node_id(observation) do
            {:ok, node_id} ->
              metrics = %{metrics | node_id: node_id}
              put_node_resolved_context(metrics, target)
              {node_id, %{model_load_request | node_id: node_id}, metrics}

            :error ->
              {nil, model_load_request, metrics}
          end

        try do
          Orchard.Nodes.observe_status(observation_target(target), observation, observed_at)
        rescue
          error ->
            Logger.warning("Node observation failed during dispatch probe: #{inspect(error)}")
        end

        if is_binary(resolved_node_id) do
          invoke_callback_safe(on_node_resolved, resolved_node_id)
        end

        {model_load_request, metrics}

      {:error, reason} ->
        # Probe failure is non-fatal, but we still record transport reachability
        # best-effort for node health.
        mark_transport_failure(target, reason)
        {model_load_request, metrics}
    end
  rescue
    error ->
      Logger.warning("Status probe failed unexpectedly: #{inspect(error)}")
      {model_load_request, metrics}
  end

  defp extract_node_id(%Observation{} = observation) do
    observation
    |> Observation.node_id()
    |> extract_node_id()
  end

  defp extract_node_id(node_id) when is_binary(node_id) do
    Ecto.UUID.cast(node_id)
  end

  defp extract_node_id(_), do: :error

  defp invoke_callback_safe(nil, _node_id), do: :ok

  defp invoke_callback_safe(callback, node_id) when is_function(callback, 1) do
    callback.(node_id)
  rescue
    error ->
      Logger.warning("on_node_resolved callback failed: #{inspect(error)}")
  catch
    :exit, reason ->
      Logger.warning("on_node_resolved callback exited: #{inspect(reason)}")
  end

  defp do_ensure_model_loaded(client, channel, target, request, timeout_ms) do
    case client.ensure_model_loaded(channel, ensure_model_loaded_operation(request),
           timeout: timeout_ms
         ) do
      {:ok, %Operation.EnsureModelLoadedResult{} = response} ->
        case normalize_placement_state(response.placement_state) do
          :loaded ->
            {:ok,
             %{
               already_loaded: response.already_loaded,
               worker_supports_prompt_token_ids: response.worker_supports_prompt_token_ids
             }}

          :failed ->
            {:error, ModelLoadFailure.from_result(response)}

          {:unexpected, placement_state} ->
            {:error,
             ModelLoadFailure.from_transport_reason(
               {:unexpected_placement_state, placement_state}
             )}
        end

      {:error, reason} ->
        mark_transport_failure(target, reason)
        {:error, ModelLoadFailure.from_transport_reason(reason)}
    end
  end

  defp preensure_prompt_token_ids_gate(request, schedule, model_load_request) do
    mode = Inference.tokenizer_safe_mode()
    prompt_token_ids = request.prompt_token_ids || []

    if mode == :reject and prompt_token_ids == [] do
      metadata =
        prompt_token_id_gate_metadata(request, %{}, schedule, model_load_request)
        |> Map.put(:reason, :missing_prompt_token_ids)

      {:error, {:missing_prompt_token_ids, metadata}}
    else
      :ok
    end
  end

  # supports_prompt_token_ids persisted under Nodes capabilities is observational
  # inventory from status probes and must not be used as dispatch eligibility
  # authority. The Runtime Endpoint ensure-model-loaded result is the
  # authoritative capability gate.
  defp gate_prompt_token_ids(request, ensure_result, schedule, model_load_request) do
    mode = Inference.tokenizer_safe_mode()
    prompt_token_ids = request.prompt_token_ids || []
    supports_prompt_token_ids? = Map.get(ensure_result, :worker_supports_prompt_token_ids, false)
    metadata = prompt_token_id_gate_metadata(request, ensure_result, schedule, model_load_request)

    apply_prompt_token_ids_gate(
      mode,
      request,
      prompt_token_ids,
      supports_prompt_token_ids?,
      metadata
    )
  end

  defp apply_prompt_token_ids_gate(:off, request, _prompt_token_ids, _supports?, _metadata) do
    {:ok, %{request | prompt_token_ids: []}}
  end

  defp apply_prompt_token_ids_gate(mode, request, prompt_token_ids, true, metadata)
       when mode in [:on, :reject] and prompt_token_ids != [] do
    Telemetry.prompt_token_ids_dispatched(metadata, length(prompt_token_ids))
    {:ok, request}
  end

  defp apply_prompt_token_ids_gate(:on, request, prompt_token_ids, false, metadata) do
    if prompt_token_ids != [] do
      Telemetry.unsafe_mode_active(Map.put(metadata, :reason, :legacy_worker_no_capability))
    end

    {:ok, %{request | prompt_token_ids: []}}
  end

  defp apply_prompt_token_ids_gate(:on, request, [], _supports?, _metadata) do
    {:ok, %{request | prompt_token_ids: []}}
  end

  defp apply_prompt_token_ids_gate(:reject, _request, [], _supports?, metadata) do
    {:error, {:missing_prompt_token_ids, Map.put(metadata, :reason, :missing_prompt_token_ids)}}
  end

  defp apply_prompt_token_ids_gate(:reject, _request, _prompt_token_ids, false, metadata) do
    {:error,
     {:legacy_worker_no_capability, Map.put(metadata, :reason, :legacy_worker_no_capability)}}
  end

  defp prompt_token_id_gate_metadata(request, ensure_result, schedule, model_load_request) do
    %{
      model_id: request.model_id || model_load_request.model_id,
      version: request.version || model_load_request.version,
      request_id: request.request_id,
      node_id: model_load_request.node_id,
      worker_id:
        Map.get(schedule, :worker_id) || Map.get(schedule, :node_id) || model_load_request.node_id,
      scheduler_strategy: Map.get(schedule, :strategy),
      worker_supports_prompt_token_ids:
        Map.get(ensure_result, :worker_supports_prompt_token_ids, false)
    }
    |> compact_nil_values()
  end

  defp normalize_placement_state(:PLACEMENT_STATE_LOADED), do: :loaded
  defp normalize_placement_state(7), do: :loaded
  defp normalize_placement_state(:loaded), do: :loaded
  defp normalize_placement_state(:PLACEMENT_STATE_FAILED), do: :failed
  defp normalize_placement_state(10), do: :failed
  defp normalize_placement_state(:failed), do: :failed
  defp normalize_placement_state(other), do: {:unexpected, other}

  defp do_execute_and_stream(
         client,
         channel,
         target,
         request,
         metrics,
         timeout_ms,
         caller,
         event_handler
       ) do
    caller_ref = Process.monitor(caller)
    timer_ref = start_timeout_timer(timeout_ms)

    execute_request = execute_operation(request)
    {:ok, task_ref} = client.execute_inference(channel, execute_request, owner: self())

    loop_ctx = %{
      caller_ref: caller_ref,
      channel: channel,
      client: client,
      controller_session_id: execute_request.controller_session_id,
      event_handler: event_handler,
      metrics: metrics,
      target: target,
      task_ref: task_ref,
      timer_ref: timer_ref
    }

    result = receive_loop(loop_ctx, [])

    cleanup(timer_ref, caller_ref)
    result
  end

  defp receive_loop(%{} = loop_ctx, events) do
    %{
      client: client,
      channel: channel,
      target: target,
      metrics: metrics,
      task_ref: task_ref,
      timer_ref: timer_ref,
      caller_ref: caller_ref,
      event_handler: event_handler
    } = loop_ctx

    request_id = metrics.request_id

    receive do
      {:runtime_endpoint_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        handler_result = emit_event(event, request_id, event_handler)
        events = [event | events]
        metrics = update_metrics_for_event(metrics, event)

        cond do
          InferenceEvent.terminal?(event) ->
            {:ok, Enum.reverse(events), metrics}

          cancelled_by_handler?(handler_result) ->
            put_cancel_sent_context(metrics, :client_disconnect)
            _ = cancel_inference(client, channel, request_id, loop_ctx.controller_session_id)

            drain_until_terminal_or_done(
              %{loop_ctx | metrics: metrics},
              events,
              :client_disconnect
            )

          true ->
            receive_loop(%{loop_ctx | metrics: metrics}, events)
        end

      {:runtime_endpoint_done, ^task_ref, :ok} ->
        {:ok, Enum.reverse(events), metrics}

      {:runtime_endpoint_done, ^task_ref, {:error, reason}} ->
        mark_transport_failure(target, reason)

        if events == [] do
          {:error, {:dispatch_failed, reason}}
        else
          has_terminal? = Enum.any?(events, &InferenceEvent.terminal?/1)

          if has_terminal? do
            {:ok, Enum.reverse(events), metrics}
          else
            failed_event =
              InferenceEvent.failed(
                "stream_error",
                "stream ended with error: #{inspect(reason)}",
                false
              )

            emit_event(failed_event, request_id, event_handler)
            metrics = update_metrics_for_terminal(metrics, failed_event, :stream)
            {:ok, Enum.reverse([failed_event | events]), metrics}
          end
        end

      {:dispatch_timeout, ^timer_ref} ->
        put_cancel_sent_context(metrics, :timeout)
        _ = cancel_inference(client, channel, request_id, loop_ctx.controller_session_id)
        drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, :timeout)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        put_cancel_sent_context(metrics, :caller_disconnect)
        _ = cancel_inference(client, channel, request_id, loop_ctx.controller_session_id)
        drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, :caller_disconnect)
    end
  end

  # After sending cancel (due to timeout or disconnect), drain remaining events
  # until we get a terminal event or the stream completes.
  defp drain_until_terminal_or_done(%{} = loop_ctx, events, cancel_reason) do
    %{task_ref: task_ref, metrics: metrics, event_handler: event_handler} = loop_ctx
    request_id = metrics.request_id

    receive do
      {:runtime_endpoint_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        emit_event(event, request_id, event_handler)
        events = [event | events]
        metrics = update_metrics_for_event(metrics, event)

        if InferenceEvent.terminal?(event) do
          {:ok, Enum.reverse(events), metrics}
        else
          drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, cancel_reason)
        end

      {:runtime_endpoint_done, ^task_ref, _result} ->
        # Stream ended without a terminal event after cancel.
        # Synthesize a terminal event so the caller always gets one.
        timeout_event =
          InferenceEvent.failed(
            "request_#{cancel_reason}",
            "request #{cancel_reason}",
            false
          )

        emit_event(timeout_event, request_id, event_handler)

        metrics =
          metrics
          |> increment_event_count()
          |> update_metrics_for_terminal(timeout_event, :synthesized)

        put_terminal_synthesized_context(metrics, cancel_reason)

        {:ok, Enum.reverse([timeout_event | events]), metrics}
    after
      5_000 ->
        # Safety valve: if neither terminal event nor stream completion
        # arrives within 5s after cancel, synthesize and return.
        timeout_event =
          InferenceEvent.failed(
            "request_#{cancel_reason}",
            "request #{cancel_reason} (drain timeout)",
            false
          )

        emit_event(timeout_event, request_id, event_handler)

        metrics =
          metrics
          |> increment_event_count()
          |> update_metrics_for_terminal(timeout_event, :synthesized)

        put_terminal_synthesized_context(metrics, cancel_reason)

        {:ok, Enum.reverse([timeout_event | events]), metrics}
    end
  end

  defp mark_transport_failure(target, reason) do
    Orchard.Nodes.record_transport_failure(target, reason, DateTime.utc_now())
  rescue
    error ->
      Logger.warning(
        "Failed to mark runtime endpoint transport failure: #{exception_name(error)}"
      )
  end

  defp exception_name(%{__struct__: module}) when is_atom(module), do: Atom.to_string(module)

  defp emit_event(_event, _request_id, nil), do: :ok

  defp emit_event(event, request_id, handler) when is_function(handler, 2) do
    handler.(request_id, event)
  end

  defp cancelled_by_handler?(handler_result), do: handler_result == :cancel

  defp start_timeout_timer(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    ref = make_ref()
    Process.send_after(self(), {:dispatch_timeout, ref}, timeout_ms)
    ref
  end

  defp cleanup(timer_ref, caller_ref) do
    # Cancel the timeout timer and flush if it already fired
    Process.cancel_timer(timer_ref)

    receive do
      {:dispatch_timeout, ^timer_ref} -> :ok
    after
      0 -> :ok
    end

    Process.demonitor(caller_ref, [:flush])
  end

  defp put_dispatch_base_context(%Metrics{} = metrics) do
    if SentryContext.controller_enabled?() do
      metrics
      |> SentryContext.build_dispatch_tags(scheduler_strategy: metrics.scheduler_strategy)
      |> SentryContext.put_tags()
    end
  end

  defp put_node_resolved_context(%Metrics{} = metrics, target) do
    if SentryContext.controller_enabled?() do
      metrics
      |> SentryContext.build_dispatch_extra(dispatch_context_opts(metrics, target))
      |> SentryContext.put_extra()

      put_dispatch_breadcrumb("node.resolved", :info, %{
        node_hash: SentryContext.hash_id(metrics.node_id),
        scheduler_strategy: metrics.scheduler_strategy,
        target_host_sanitized: "[redacted]"
      })
    end
  end

  defp put_ensure_model_load_started_context(%Metrics{} = metrics) do
    put_dispatch_breadcrumb("ensure_model_load.started", :info, model_context_data(metrics))
  end

  defp put_ensure_model_load_completed_context(%Metrics{} = metrics) do
    data =
      metrics
      |> model_context_data()
      |> Map.merge(%{
        already_loaded: metrics.model_already_loaded,
        ensure_model_loaded_ms: metrics.ensure_model_loaded_ms
      })

    put_dispatch_breadcrumb("ensure_model_load.completed", :info, data)
  end

  defp put_first_delta_context(%Metrics{} = metrics) do
    data =
      metrics
      |> model_context_data()
      |> Map.put(:accepted_to_first_delta_ms, metrics.accepted_to_first_delta_ms)

    put_dispatch_breadcrumb("first_delta.received", :info, data)
  end

  defp put_cancel_sent_context(%Metrics{} = metrics, reason) do
    data =
      metrics
      |> model_context_data()
      |> Map.put(:reason, reason)

    put_dispatch_breadcrumb("cancel.sent", :warning, data)
  end

  defp put_terminal_synthesized_context(%Metrics{} = metrics, reason) do
    data =
      metrics
      |> model_context_data()
      |> Map.merge(%{reason: reason, terminal_source: :synthesized})

    put_dispatch_breadcrumb("terminal.synthesized", :warning, data)
  end

  defp put_dispatch_terminal_context(%Metrics{} = metrics, target) do
    if SentryContext.controller_enabled?() do
      metrics
      |> SentryContext.build_dispatch_extra(dispatch_context_opts(metrics, target))
      |> SentryContext.put_extra()

      metrics
      |> SentryContext.build_dispatch_tags(scheduler_strategy: metrics.scheduler_strategy)
      |> SentryContext.put_tags()
    end
  end

  defp put_dispatch_breadcrumb(message, level, data) do
    if SentryContext.controller_enabled?() do
      SentryContext.add_breadcrumb(
        category: "orchard.dispatch",
        message: message,
        level: level,
        data: compact_nil_values(data)
      )
    end
  end

  defp dispatch_context_opts(%Metrics{} = metrics, target) do
    [
      node_id: metrics.node_id,
      scheduler_strategy: metrics.scheduler_strategy,
      target_host: target_host(target)
    ]
  end

  defp model_context_data(%Metrics{} = metrics) do
    %{
      node_hash: SentryContext.hash_id(metrics.node_id),
      model_id: metrics.model_id,
      model_version: metrics.version,
      scheduler_strategy: metrics.scheduler_strategy
    }
    |> compact_nil_values()
  end

  defp target_host(%Target{transport: :grpc_compat, address: address}), do: target_host(address)
  defp target_host(target) when is_list(target), do: Keyword.get(target, :host)
  defp target_host(%{} = target), do: Map.get(target, :host) || Map.get(target, "host")
  defp target_host(_target), do: nil

  defp runtime_endpoint_target(schedule) do
    case Map.get(schedule, :runtime_endpoint_target) do
      %Target{} = target ->
        target

      nil ->
        schedule
        |> Map.fetch!(:runtime_client_target)
        |> Target.grpc_compat()
    end
  end

  defp observation_target(%Target{transport: :grpc_compat, address: address}), do: address
  defp observation_target(target), do: target

  defp normalize_status_observation(_target, %Observation{} = observation), do: observation

  defp normalize_status_observation(target, %{} = status_response) do
    GrpcCompatibilityMapper.observation_from_status(target, status_response)
  end

  defp ensure_model_loaded_operation(%EnsureModelLoadedRequest{} = request) do
    Operation.EnsureModelLoadedRequest.new!(
      node_id: blank_to_nil(request.node_id),
      model_ref: %{model_id: request.model_id, version: request.version},
      artifact_sha256: blank_to_nil(request.artifact_sha256),
      preload: request.preload,
      deadline_unix_ms: zero_to_nil(request.deadline_unix_ms),
      artifact_source_uri: blank_to_nil(request.artifact_source_uri)
    )
  end

  defp execute_operation(%ExecuteInferenceRequest{} = request) do
    Operation.ExecuteRequest.new!(
      request_id: request.request_id,
      controller_session_id: request.controller_session_id,
      model_ref: %{model_id: request.model_id, version: request.version},
      rendered_prompt_utf8: request.rendered_prompt_utf8,
      input_tokens: request.input_tokens,
      params: request.params || %{},
      deadline_unix_ms: zero_to_nil(request.deadline_unix_ms),
      metadata_json: request.metadata_json || "{}",
      cache_affinity_fingerprint: blank_to_nil(request.cache_affinity_fingerprint),
      prompt_token_ids: request.prompt_token_ids || []
    )
  end

  defp cancel_inference(client, channel, request_id, controller_session_id) do
    client.cancel_inference(
      channel,
      Operation.CancelRequest.new!(
        request_id: request_id,
        controller_session_id: controller_session_id
      ),
      []
    )
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(nil), do: nil
  defp zero_to_nil(value), do: value

  defp compact_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  # -- Metrics tracking -----------------------------------------------------

  # Update metrics based on the event type.
  # Tracks first Accepted timestamp, first delta timestamp, and terminal events.
  defp update_metrics_for_event(%Metrics{} = metrics, %InferenceEvent{} = event) do
    metrics
    |> increment_event_count()
    |> track_accepted_event(event)
    |> track_first_delta(event)
    |> track_terminal_event(event)
  end

  defp increment_event_count(%Metrics{event_count: count} = metrics) do
    %{metrics | event_count: count + 1}
  end

  # Track first Accepted event (cold start measurement starts from this)
  defp track_accepted_event(
         %Metrics{accepted_monotonic_ms: nil} = metrics,
         %InferenceEvent{event: %InferenceEvent.Accepted{}} = _event
       ) do
    %{metrics | accepted_monotonic_ms: System.monotonic_time(:millisecond)}
  end

  defp track_accepted_event(metrics, _event), do: metrics

  # Track first OutputTextDelta (measures time from accepted to first output)
  defp track_first_delta(
         %Metrics{first_delta_monotonic_ms: nil} = metrics,
         %InferenceEvent{event: %InferenceEvent.OutputTextDelta{delta: delta}}
       )
       when delta != "" do
    now_ms = System.monotonic_time(:millisecond)
    metrics = %{metrics | first_delta_monotonic_ms: now_ms}

    metrics =
      case metrics.accepted_monotonic_ms do
        nil ->
          if metrics.anomaly == :none,
            do: %{metrics | anomaly: :delta_before_accepted},
            else: metrics

        accepted_ms ->
          %{metrics | accepted_to_first_delta_ms: now_ms - accepted_ms}
      end

    put_first_delta_context(metrics)
    metrics
  end

  defp track_first_delta(metrics, _event), do: metrics

  # Track terminal events (Completed or Failed)
  defp track_terminal_event(%Metrics{} = metrics, %InferenceEvent{} = event) do
    if InferenceEvent.terminal?(event) do
      update_metrics_for_terminal(metrics, event, :stream)
    else
      metrics
    end
  end

  # Update metrics for a terminal event (from stream or synthesized)
  defp update_metrics_for_terminal(%Metrics{} = metrics, %InferenceEvent{} = event, source) do
    now_ms = System.monotonic_time(:millisecond)
    metrics = %{metrics | terminal_monotonic_ms: now_ms, terminal_source: source}

    # Set terminal_kind based on event type
    metrics =
      case event.event do
        %InferenceEvent.Completed{} ->
          %{metrics | terminal_kind: :completed}

        %InferenceEvent.Failed{code: code, message: message} ->
          %{metrics | terminal_kind: :failed, terminal_detail: "#{code}: #{message}"}

        _ ->
          metrics
      end

    maybe_emit_parity_drift(metrics, event, source)

    # Compute accepted_to_terminal_ms if we have accepted timestamp
    case metrics.accepted_monotonic_ms do
      nil ->
        if metrics.anomaly == :none,
          do: %{metrics | anomaly: :terminal_before_accepted},
          else: metrics

      accepted_ms ->
        %{metrics | accepted_to_terminal_ms: now_ms - accepted_ms}
    end
  end

  defp maybe_emit_parity_drift(
         %Metrics{} = metrics,
         %InferenceEvent{
           event: %InferenceEvent.Failed{
             code: "prompt_token_ids_length_mismatch",
             message: message
           }
         },
         :stream
       ) do
    Telemetry.parity_drift(%{
      request_id: metrics.request_id,
      model_id: metrics.model_id,
      version: metrics.version,
      node_id: metrics.node_id,
      scheduler_strategy: metrics.scheduler_strategy,
      input_tokens: metrics.input_tokens,
      code: "prompt_token_ids_length_mismatch",
      worker_message: message
    })
  end

  defp maybe_emit_parity_drift(_metrics, _event, _source), do: :ok

  defp emit_timing_log(%Metrics{} = metrics, result) do
    # Finalize metrics based on result
    metrics = finalize_metrics(metrics, result)

    Logger.info(
      "dispatch_timing " <>
        "request_id=#{metrics.request_id} " <>
        "model_id=#{metrics.model_id} " <>
        "version=#{metrics.version} " <>
        "input_tokens=#{metrics.input_tokens} " <>
        "model_already_loaded=#{serialize_bool(metrics.model_already_loaded)} " <>
        "ensure_model_loaded_ms=#{serialize_na(metrics.ensure_model_loaded_ms)} " <>
        "accepted_to_first_delta_ms=#{serialize_na(metrics.accepted_to_first_delta_ms)} " <>
        "accepted_to_terminal_ms=#{serialize_na(metrics.accepted_to_terminal_ms)} " <>
        "terminal_kind=#{metrics.terminal_kind} " <>
        "terminal_source=#{metrics.terminal_source} " <>
        "terminal_detail=#{serialize_na(metrics.terminal_detail)} " <>
        "outcome=#{metrics.outcome} " <>
        "event_count=#{metrics.event_count} " <>
        "anomaly=#{metrics.anomaly}"
    )
  end

  # For successful streams, finalize_metrics is not used - result already has final_metrics
  defp finalize_metrics(%Metrics{} = metrics, :ok) do
    %{metrics | outcome: :ok}
  end

  defp finalize_metrics(%Metrics{} = metrics, {:error, {:model_load_failed, _reason}}) do
    %{metrics | outcome: :model_load_failed, terminal_kind: :none, terminal_source: :none}
  end

  defp finalize_metrics(%Metrics{} = metrics, {:error, {:dispatch_failed, _reason}}) do
    %{metrics | outcome: :dispatch_failed, terminal_kind: :none, terminal_source: :none}
  end

  defp serialize_bool(true), do: "true"
  defp serialize_bool(false), do: "false"
  defp serialize_bool(:unknown), do: "unknown"

  defp serialize_na(:na), do: "na"
  defp serialize_na(value) when is_integer(value), do: Integer.to_string(value)
  defp serialize_na(value), do: inspect(value)
end
