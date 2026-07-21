defmodule Orchard.Dispatch.RequestDispatcher do
  @moduledoc """
  Orchestrates the dispatch of an inference request to a node-agent.

  Implements the current node-agent dispatch flow:

    schedule → connect → ensure_model_loaded → execute_inference → stream events

  Monitors for:
  - Request timeout → sends CancelInference to the node
  - Caller process exit → sends CancelInference to the node

  A managed schedule acquires exactly one Node-scoped capacity claim from the
  shared allocation authority before model loading, holds it through acceptance
  and terminal completion, and releases it exactly once on failure,
  cancellation, retry, or completion. Immediately before `ExecuteInference` the
  dispatcher takes that Node's acceptance gate, revalidates the recognized
  claim without counting it twice, and holds the gate until the node accepts or
  the attempt fails pre-acceptance. Gate acquisition is bounded by the time left
  on the request deadline, which the schedule's required `:request_timeout_ms`
  opens at dispatch entry, and fails the dispatch with
  `:dispatch_capacity_acceptance_gate_busy` rather than waiting behind another
  in-flight dispatch to the same Node indefinitely. An already-elapsed deadline
  fails as `:dispatch_timeout` without taking the gate. Unavailable capacity fails
  the dispatch rather than proceeding, and reports the authority's own reason —
  `:dispatch_capacity_unavailable`, `:dispatch_capacity_request_already_claimed`
  for a request whose prior claim was never released, or
  `:dispatch_capacity_facts_unavailable` when the schedule carries no
  acquisition input — so an operator is not sent to look at Node capacity for a
  leaked claim.

  Transport failures during connect, pre-dispatch status, model load, or stream
  execution are recorded through node inventory so stale capacity for the failed
  target is cleared.
  Runtime Endpoint disconnect cleanup is best-effort and does not override the
  dispatch outcome.

  Timing instrumentation logs one 'dispatch_timing' line per dispatch attempt,
  capturing cold/warm classification, stream timing, and outcome.
  """

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest
  }

  use Orchard.DispatchCapacity.Consumer, wiring: :final_dispatch_revalidation

  alias Orchard.Inference
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent

  alias Orchard.RuntimeEndpoint.{
    BeamIdentity,
    GrpcCompatibilityMapper,
    Observation,
    Operation,
    Target
  }

  alias Orchard.SentryContext
  alias Orchard.Tokenizer.Telemetry

  require Logger

  @maximum_cancel_drain_timeout_ms 5_000
  @pending_cancel_reconciliation_key {__MODULE__, :pending_cancel_reconciliation}

  @doc "Revalidates a recognized dispatch claim through the production QueueManager seam."
  @spec revalidate_dispatch_capacity(
          AllocationAuthority.Claim.t(),
          Evaluator.Input.t(),
          keyword()
        ) ::
          {:ok, Evaluator.Result.t()}
          | {:error, :dispatch_capacity_revalidation_failed, Evaluator.Result.t()}
  def revalidate_dispatch_capacity(claim, input, opts \\ []) do
    QueueManager.revalidate_dispatch_capacity(claim, input, opts)
  end

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
  - `:request_timeout_ms` - maximum wall-clock time for the dispatch excluding
    model load, which is bounded separately by `:model_load_timeout_ms`. The
    deadline runs from dispatch entry and covers connect, probe, acceptance-gate
    acquisition, and streaming, so a slow cold start cannot starve the stream.

  BEAM schedules may omit `:runtime_client_target`.
  If a configured BEAM target node ID conflicts with observed endpoint metadata,
  dispatch fails before model load rather than trusting the mismatched identity.

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
  - `:cancel_drain_timeout_ms` - bounded cancellation reconciliation grace period
                                 (default: the lesser of request timeout and 5 seconds)

  Returns `{:ok, events}` with the list of all events received (including terminal),
  or `{:error, reason}` if dispatch fails before streaming begins.
  Runtime Endpoint disconnect cleanup failures are logged and ignored after the
  dispatch outcome is known.
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
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    model_load_timeout = Map.get(schedule, :model_load_timeout_ms, 120_000)
    caller = Keyword.get(opts, :caller, self())
    caller_ref = Process.monitor(caller)
    event_handler = Keyword.get(opts, :event_handler)
    on_node_resolved = Keyword.get(opts, :on_node_resolved)
    client = Keyword.get(opts, :client_impl, Inference.runtime_endpoint_client())

    cancel_drain_timeout_ms =
      cancel_drain_timeout_ms(Keyword.get(opts, :cancel_drain_timeout_ms), timeout_ms)

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
      deadline_ms: deadline_ms,
      caller: caller,
      caller_ref: caller_ref,
      cancel_drain_timeout_ms: cancel_drain_timeout_ms,
      event_handler: event_handler,
      on_node_resolved: on_node_resolved
    }

    try do
      case preensure_prompt_token_ids_gate(execute_request, schedule, model_load_request) do
        :ok ->
          dispatch_with_capacity_claim(context)

        {:error, reason} ->
          error_metrics = finalize_metrics(metrics, {:error, {:dispatch_failed, reason}})
          put_dispatch_terminal_context(error_metrics, target)
          emit_timing_log(error_metrics, {:error, {:dispatch_failed, reason}})
          {:error, {:dispatch_failed, reason}}
      end
    after
      Process.demonitor(caller_ref, [:flush])
    end
  end

  # -- Private ---------------------------------------------------------------

  defp dispatch_with_capacity_claim(%{schedule: schedule} = context) do
    case acquire_capacity_claim(schedule) do
      {:ok, nil} ->
        dispatch_after_preensure_gate(context)

      {:ok, claim} ->
        try do
          dispatch_after_preensure_gate(Map.put(context, :capacity_claim, claim))
        after
          release_capacity_claim(schedule, claim)
        end

      {:error, reason} ->
        handle_dispatch_result(
          {:error, {:dispatch_failed, reason}},
          context.metrics,
          context.target
        )
    end
  end

  defp acquire_capacity_claim(
         %{
           node_id: node_id,
           request_id: request_id
         } = schedule
       )
       when is_binary(node_id) and is_binary(request_id) do
    case dispatch_capacity_acquisition_input(schedule) do
      %Orchard.DispatchCapacity.Evaluator.Input{} = input ->
        opts = capacity_authority_opts(schedule)

        case QueueManager.acquire_dispatch_capacity(node_id, request_id, input, opts) do
          {:ok, claim, _result} -> {:ok, claim}
          {:error, reason, _result} -> {:error, reason}
        end

      _missing_input ->
        {:error, :dispatch_capacity_facts_unavailable}
    end
  end

  defp acquire_capacity_claim(
         %{
           dispatch_capacity_input: %Orchard.DispatchCapacity.Evaluator.Input{} = input,
           dispatch_capacity_evaluation: %Orchard.DispatchCapacity.Evaluator.Result{} = result,
           request_id: request_id
         } = schedule
       )
       when is_binary(request_id) do
    with true <- unmanaged_dispatch_authorized?(input, result),
         %Orchard.DispatchCapacity.Evaluator.Input{} = fresh_input <-
           dispatch_capacity_acquisition_input(schedule),
         fresh_result <-
           evaluate_dispatch_capacity(capacity_authority(schedule), nil, fresh_input),
         true <- unmanaged_dispatch_authorized?(fresh_input, fresh_result) do
      {:ok, nil}
    else
      _unavailable -> {:error, :dispatch_capacity_unavailable}
    end
  end

  defp acquire_capacity_claim(_schedule), do: {:error, :dispatch_capacity_facts_unavailable}

  defp dispatch_capacity_acquisition_input(schedule) do
    case Map.get(schedule, :dispatch_capacity_acquisition_input_provider) do
      provider when is_function(provider, 0) -> provider.()
      _provider -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp unmanaged_dispatch_authorized?(
         %Orchard.DispatchCapacity.Evaluator.Input{
           management_classification: {:ok, management_class}
         },
         %Orchard.DispatchCapacity.Evaluator.Result{
           authority_decision: authority_decision,
           management_class: management_class,
           eligible?: true,
           available_slots: slots
         }
       )
       when management_class in [:unmanaged_source_development, :unmanaged_compatibility] and
              authority_decision == management_class and slots > 0,
       do: true

  defp unmanaged_dispatch_authorized?(_input, _result), do: false

  defp release_capacity_claim(schedule, claim) do
    QueueManager.release_dispatch_capacity(claim, capacity_authority_opts(schedule))
  end

  defp capacity_authority_opts(schedule) do
    case Map.get(schedule, :dispatch_capacity_authority) do
      nil -> []
      authority -> [authority: authority]
    end
  end

  defp capacity_authority(schedule),
    do: Map.get(schedule, :dispatch_capacity_authority, AllocationAuthority)

  defp dispatch_after_preensure_gate(%{client: client, target: target} = context) do
    case authorize_dispatch_target(target) do
      :ok ->
        case client.connect(target) do
          {:ok, channel} ->
            dispatch_with_channel(Map.put(context, :channel, channel))

          {:error, reason} ->
            handle_dispatch_connect_failure(target, reason, context.metrics)
        end

      {:error, :runtime_target_not_active} ->
        handle_dispatch_result(
          {:error, {:dispatch_failed, :node_not_active}},
          context.metrics,
          target
        )

      {:error, :node_inventory_unavailable} ->
        handle_dispatch_result(
          {:error, {:dispatch_failed, :node_inventory_unavailable}},
          context.metrics,
          target
        )
    end
  end

  defp authorize_dispatch_target(%Target{} = target) do
    cond do
      activation_probe_target?(target) -> {:error, :runtime_target_not_active}
      Inference.static_runtime_target?(target) -> :ok
      true -> Orchard.Nodes.authorize_inference_target(target)
    end
  end

  defp activation_probe_target?(%Target{metadata: metadata}) do
    Map.get(metadata, :authorization) == :activation_probe or
      Map.get(metadata, "authorization") == "activation_probe"
  end

  defp dispatch_with_channel(%{client: client, channel: channel} = context) do
    Process.delete(@pending_cancel_reconciliation_key)

    try do
      do_dispatch_with_channel(context)
    after
      disconnect_result = disconnect_best_effort(client, channel)
      finalize_pending_cancel_reconciliation(disconnect_result)
    end
  end

  defp disconnect_best_effort(client, channel) do
    case client.disconnect(channel) do
      {:ok, :disconnected} -> :ok
      :ok -> {:error, :disconnect_unproven}
      _unconfirmed -> {:error, :disconnect_unconfirmed}
    end
  rescue
    error ->
      Logger.warning("Runtime endpoint disconnect failed: #{exception_name(error)}")
      {:error, :disconnect_failed}
  catch
    :exit, _reason ->
      Logger.warning("Runtime endpoint disconnect exited")
      {:error, :disconnect_failed}

    _kind, _reason ->
      Logger.warning("Runtime endpoint disconnect threw")
      {:error, :disconnect_failed}
  end

  defp do_dispatch_with_channel(%{} = context) do
    case probe_and_resolve_node(
           context.client,
           context.channel,
           context.target,
           context.model_load_request,
           claimed_node_id(context),
           context.on_node_resolved,
           context.metrics
         ) do
      {:ok, model_load_request, metrics} ->
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

      {:error, reason, metrics} ->
        handle_dispatch_result({:error, {:dispatch_failed, reason}}, metrics, context.target)
    end
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

    context = %{context | deadline_ms: context.deadline_ms + (ensure_end - ensure_start)}

    result = execute_loaded_request(context, ensure_load_meta, metrics)

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

  defp execute_loaded_request(context, ensure_load_meta, metrics) do
    case gate_prompt_token_ids(
           context.execute_request,
           ensure_load_meta,
           context.schedule,
           context.model_load_request
         ) do
      {:ok, gated_execute_request} ->
        execute_under_acceptance_gate(context, gated_execute_request, metrics)

      {:error, reason} ->
        {:error, {:dispatch_failed, reason}}
    end
  end

  defp execute_under_acceptance_gate(context, gated_execute_request, metrics) do
    case acquire_dispatch_acceptance_gate(context) do
      {:ok, acceptance_gate} ->
        stream_under_acceptance_gate(context, gated_execute_request, metrics, acceptance_gate)

      {:error, reason} ->
        {:error, {:dispatch_failed, reason}}
    end
  end

  defp stream_under_acceptance_gate(context, gated_execute_request, metrics, acceptance_gate) do
    case revalidate_capacity_claim(context) do
      :ok ->
        stream_context = %{
          acceptance_gate: acceptance_gate,
          caller_ref: context.caller_ref,
          cancel_drain_timeout_ms: context.cancel_drain_timeout_ms,
          capacity_authority: capacity_authority(context.schedule),
          capacity_node_id: Map.get(context.schedule, :node_id),
          channel: context.channel,
          client: context.client,
          event_handler: context.event_handler,
          target: context.target,
          timeout_ms: remaining_request_timeout_ms(context.deadline_ms)
        }

        do_execute_and_stream(stream_context, gated_execute_request, metrics)

      {:error, :dispatch_capacity_revalidation_failed, _result} ->
        {:error, {:dispatch_failed, :dispatch_capacity_revalidation_failed}}
    end
  after
    release_dispatch_acceptance_gate(acceptance_gate)
  end

  defp revalidate_capacity_claim(%{capacity_claim: claim, schedule: schedule}) do
    with %Orchard.DispatchCapacity.Evaluator.Input{} = input <-
           dispatch_capacity_revalidation_input(schedule),
         result <-
           revalidate_dispatch_capacity(
             claim,
             input,
             capacity_authority_opts(schedule)
           ) do
      case result do
        {:ok, _evaluation} -> :ok
        {:error, :dispatch_capacity_revalidation_failed, _evaluation} = error -> error
      end
    else
      _missing_input -> {:error, :dispatch_capacity_revalidation_failed, nil}
    end
  end

  defp revalidate_capacity_claim(%{schedule: schedule}) do
    with %Orchard.DispatchCapacity.Evaluator.Input{} = input <-
           dispatch_capacity_revalidation_input(schedule),
         result <- evaluate_dispatch_capacity(capacity_authority(schedule), nil, input),
         true <- unmanaged_dispatch_authorized?(input, result) do
      :ok
    else
      _unavailable -> {:error, :dispatch_capacity_revalidation_failed, nil}
    end
  end

  defp dispatch_capacity_revalidation_input(schedule) do
    case Map.get(schedule, :dispatch_capacity_input_provider) do
      provider when is_function(provider, 0) -> provider.()
      _provider -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp acquire_dispatch_acceptance_gate(%{capacity_claim: claim, schedule: schedule} = context) do
    opts = capacity_authority_opts(schedule)
    gate_timeout_ms = remaining_request_timeout_ms(context.deadline_ms)

    if gate_timeout_ms <= 0 do
      {:error, :dispatch_timeout}
    else
      gate_opts =
        opts
        |> Keyword.put(:gate_timeout_ms, gate_timeout_ms)
        |> Keyword.put(:abort_monitor_ref, context.caller_ref)
        |> Keyword.put(:abort_pid, context.caller)

      case QueueManager.acquire_acceptance_gate(claim.node_id, gate_opts) do
        {:ok, lease} -> {:ok, {lease, opts}}
        {:error, :dispatch_capacity_caller_down} -> {:error, :caller_disconnect}
        {:error, _reason} = error -> error
      end
    end
  end

  defp acquire_dispatch_acceptance_gate(_context), do: {:ok, nil}

  defp remaining_request_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp release_dispatch_acceptance_gate(nil), do: :ok

  defp release_dispatch_acceptance_gate({lease, opts}) do
    QueueManager.release_acceptance_gate(lease, opts)
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

  defp probe_and_resolve_node(
         client,
         channel,
         target,
         model_load_request,
         claimed_node_id,
         on_node_resolved,
         metrics
       ) do
    case client.status(channel, timeout: @status_probe_timeout_ms) do
      {:ok, response} ->
        resolve_probe_status(
          response,
          target,
          model_load_request,
          claimed_node_id,
          on_node_resolved,
          metrics
        )

      {:error, :authenticated_observation_rejected} ->
        {:error, :authenticated_observation_rejected, metrics}

      {:error, reason} ->
        mark_transport_failure(target, reason)
        unverified_probe_identity(model_load_request, claimed_node_id, metrics)
    end
  rescue
    error ->
      Logger.warning("Status probe failed unexpectedly: #{inspect(error)}")
      unverified_probe_identity(model_load_request, claimed_node_id, metrics)
  end

  defp unverified_probe_identity(model_load_request, nil, metrics),
    do: {:ok, model_load_request, metrics}

  defp unverified_probe_identity(_model_load_request, _claimed_node_id, metrics),
    do: {:error, :dispatch_capacity_node_identity_mismatch, metrics}

  defp resolve_probe_status(
         response,
         target,
         model_load_request,
         claimed_node_id,
         on_node_resolved,
         metrics
       ) do
    observed_at = DateTime.utc_now()
    observation = normalize_status_observation(target, response)

    case BeamIdentity.resolve_candidate_node_id(target, observation) do
      {:rejected, reason} ->
        {:error, reason, metrics}

      identity_result ->
        if dispatch_probe_identity_matches?(identity_result, claimed_node_id) do
          persist_resolved_probe(
            identity_result,
            target,
            observation,
            observed_at,
            model_load_request,
            on_node_resolved,
            metrics
          )
        else
          {:error, :dispatch_capacity_node_identity_mismatch, metrics}
        end
    end
  end

  defp claimed_node_id(%{capacity_claim: %{node_id: node_id}}), do: node_id
  defp claimed_node_id(_context), do: nil

  defp dispatch_probe_identity_matches?({:ok, node_id}, node_id), do: true
  defp dispatch_probe_identity_matches?(_identity_result, nil), do: true
  defp dispatch_probe_identity_matches?(_identity_result, _claimed_node_id), do: false

  defp persist_resolved_probe(
         identity_result,
         target,
         observation,
         observed_at,
         model_load_request,
         on_node_resolved,
         metrics
       ) do
    {resolved_node_id, model_load_request, metrics} =
      resolved_probe_identity(identity_result, target, model_load_request, metrics)

    observe_probe_status(target, observation, observed_at)

    if is_binary(resolved_node_id) do
      invoke_callback_safe(on_node_resolved, resolved_node_id)
    end

    {:ok, model_load_request, metrics}
  end

  defp observe_probe_status(target, observation, observed_at) do
    Orchard.Nodes.observe_status(observation_target(target), observation, observed_at)
  rescue
    error ->
      Logger.warning("Node observation failed during dispatch probe: #{inspect(error)}")
  end

  defp resolved_probe_identity({:ok, node_id}, target, model_load_request, metrics) do
    metrics = %{metrics | node_id: node_id}
    put_node_resolved_context(metrics, target)
    {node_id, %{model_load_request | node_id: node_id}, metrics}
  end

  defp resolved_probe_identity(:missing, _target, model_load_request, metrics) do
    {nil, model_load_request, metrics}
  end

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

  defp do_execute_and_stream(%{timeout_ms: timeout_ms}, _request, _metrics)
       when timeout_ms <= 0 do
    {:error, {:dispatch_failed, :dispatch_timeout}}
  end

  defp do_execute_and_stream(stream_context, request, metrics) do
    %{
      acceptance_gate: acceptance_gate,
      cancel_drain_timeout_ms: cancel_drain_timeout_ms,
      capacity_authority: capacity_authority,
      capacity_node_id: capacity_node_id,
      caller_ref: caller_ref,
      channel: channel,
      client: client,
      event_handler: event_handler,
      target: target,
      timeout_ms: timeout_ms
    } = stream_context

    timer_ref = start_timeout_timer(timeout_ms)

    execute_request = execute_operation(request)

    try do
      if caller_disconnected?(caller_ref) do
        {:error, {:dispatch_failed, :caller_disconnect}}
      else
        case client.execute_inference(channel, execute_request, owner: self()) do
          {:ok, task_ref} ->
            receive_loop(
              %{
                caller_ref: caller_ref,
                channel: channel,
                client: client,
                controller_session_id: execute_request.controller_session_id,
                event_handler: event_handler,
                accepted?: false,
                acceptance_gate: acceptance_gate,
                cancel_drain_timeout_ms: cancel_drain_timeout_ms,
                capacity_authority: capacity_authority,
                capacity_node_id: capacity_node_id,
                cancellation_started_before_acceptance?: false,
                metrics: metrics,
                target: target,
                task_ref: task_ref,
                timer_ref: timer_ref
              },
              []
            )

          {:error, reason} ->
            {:error, {:dispatch_failed, reason}}

          _invalid ->
            {:error, {:dispatch_failed, :runtime_endpoint_protocol_error}}
        end
      end
    after
      cleanup_timer(timer_ref)
    end
  end

  defp caller_disconnected?(caller_ref) do
    receive do
      {:DOWN, ^caller_ref, :process, _pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp receive_loop(%{} = loop_ctx, events) do
    %{
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
        loop_ctx = maybe_record_acceptance(loop_ctx, event)
        events = [event | events]
        metrics = update_metrics_for_event(metrics, event)
        handler_result = emit_event_safely(event, request_id, event_handler)

        cond do
          InferenceEvent.terminal?(event) ->
            stream_terminal_result(loop_ctx, events, metrics)

          handler_failed?(handler_result) ->
            cancel_and_drain(
              %{loop_ctx | metrics: metrics},
              events,
              :event_handler_failed
            )

          cancelled_by_handler?(handler_result) ->
            cancel_and_drain(
              %{loop_ctx | metrics: metrics},
              events,
              :client_disconnect
            )

          true ->
            receive_loop(%{loop_ctx | metrics: metrics}, events)
        end

      {:runtime_endpoint_done, ^task_ref, :ok} ->
        stream_terminal_result(loop_ctx, events, metrics)

      {:runtime_endpoint_done, ^task_ref, {:error, reason}} ->
        mark_transport_failure(target, reason)
        stream_error_result(loop_ctx, events, metrics, reason)

      {:dispatch_timeout, ^timer_ref} ->
        cancel_and_drain(%{loop_ctx | metrics: metrics}, events, :timeout)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        cancel_and_drain(%{loop_ctx | metrics: metrics}, events, :caller_disconnect)
    end
  end

  defp maybe_record_acceptance(
         %{acceptance_gate: acceptance_gate} = loop_ctx,
         %InferenceEvent{event: %InferenceEvent.Accepted{}}
       ) do
    release_dispatch_acceptance_gate(acceptance_gate)
    %{loop_ctx | acceptance_gate: nil, accepted?: true}
  end

  defp maybe_record_acceptance(loop_ctx, _event), do: loop_ctx

  defp stream_error_result(
         %{accepted?: true, cancellation_started_before_acceptance?: false} = loop_ctx,
         events,
         metrics,
         reason
       ) do
    failed_event =
      InferenceEvent.failed(
        "stream_error",
        "stream ended with error: #{inspect(reason)}",
        false
      )

    _handler_result = emit_event_safely(failed_event, metrics.request_id, loop_ctx.event_handler)
    metrics = update_metrics_for_terminal(metrics, failed_event, :stream)
    stream_terminal_result(loop_ctx, [failed_event | events], metrics)
  end

  defp stream_error_result(_loop_ctx, _events, _metrics, reason),
    do: {:error, {:dispatch_failed, reason}}

  defp stream_terminal_result(loop_ctx, events, metrics),
    do: stream_terminal_result(loop_ctx, events, metrics, nil)

  defp stream_terminal_result(
         %{accepted?: true, cancellation_started_before_acceptance?: false},
         events,
         metrics,
         _cancel_reason
       ),
       do: {:ok, Enum.reverse(events), metrics}

  defp stream_terminal_result(_loop_ctx, _events, _metrics, cancel_reason),
    do: {:error, {:dispatch_failed, pre_acceptance_failure_reason(cancel_reason)}}

  defp pre_acceptance_failure_reason(:timeout), do: :request_timeout

  defp pre_acceptance_failure_reason(reason)
       when reason in [:caller_disconnect, :client_disconnect],
       do: :request_caller_disconnect

  defp pre_acceptance_failure_reason(_cancel_reason), do: :node_acceptance_missing

  defp cancel_and_drain(loop_ctx, events, cancel_reason) do
    %{client: client, channel: channel, metrics: metrics} = loop_ctx
    request_id = metrics.request_id

    loop_ctx = %{
      loop_ctx
      | cancellation_started_before_acceptance?: not loop_ctx.accepted?
    }

    put_cancel_sent_context(metrics, cancel_reason)
    cancel_inference_safely(client, channel, request_id, loop_ctx.controller_session_id)

    cancel_deadline =
      System.monotonic_time(:millisecond) + loop_ctx.cancel_drain_timeout_ms

    result = drain_until_terminal_or_done(loop_ctx, events, cancel_reason, cancel_deadline)

    if cancel_reason == :event_handler_failed do
      case result do
        {:ok, _events, _metrics} -> {:error, {:dispatch_failed, :event_handler_failed}}
        {:error, _reason} = error -> error
      end
    else
      result
    end
  end

  defp cancel_inference_safely(client, channel, request_id, controller_session_id) do
    _result = cancel_inference(client, channel, request_id, controller_session_id)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # After sending cancel (due to timeout or disconnect), drain remaining events
  # until we get a terminal event or the stream completes.
  defp drain_until_terminal_or_done(%{} = loop_ctx, events, cancel_reason, cancel_deadline) do
    %{
      task_ref: task_ref,
      metrics: metrics,
      event_handler: event_handler
    } = loop_ctx

    request_id = metrics.request_id
    remaining_ms = cancel_deadline - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      receive do
        {:runtime_endpoint_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
          loop_ctx = maybe_record_acceptance(loop_ctx, event)
          _handler_result = emit_event_safely(event, request_id, event_handler)
          events = [event | events]
          metrics = update_metrics_for_event(metrics, event)

          if InferenceEvent.terminal?(event) do
            stream_terminal_result(loop_ctx, events, metrics, cancel_reason)
          else
            drain_until_terminal_or_done(
              %{loop_ctx | metrics: metrics},
              events,
              cancel_reason,
              cancel_deadline
            )
          end

        {:runtime_endpoint_done, ^task_ref, _result} ->
          synthesize_cancel_terminal(loop_ctx, events, cancel_reason, "")
      after
        remaining_ms -> cancel_drain_timeout_result(loop_ctx, events, cancel_reason)
      end
    else
      cancel_drain_timeout_result(loop_ctx, events, cancel_reason)
    end
  end

  defp cancel_drain_timeout_result(loop_ctx, events, cancel_reason) do
    reconcile_cancel_drain_timeout(loop_ctx)
    synthesize_cancel_terminal(loop_ctx, events, cancel_reason, " after drain timeout")
  end

  defp synthesize_cancel_terminal(loop_ctx, events, cancel_reason, message_suffix) do
    %{metrics: metrics, event_handler: event_handler} = loop_ctx
    request_id = metrics.request_id

    timeout_event =
      InferenceEvent.failed(
        "request_#{cancel_reason}",
        "request #{cancel_reason}#{message_suffix}",
        false
      )

    _handler_result = emit_event_safely(timeout_event, request_id, event_handler)

    metrics =
      metrics
      |> increment_event_count()
      |> update_metrics_for_terminal(timeout_event, :synthesized)

    put_terminal_synthesized_context(metrics, cancel_reason)
    stream_terminal_result(loop_ctx, [timeout_event | events], metrics, cancel_reason)
  end

  defp reconcile_cancel_drain_timeout(%{
         capacity_authority: authority,
         capacity_node_id: node_id,
         client: client,
         channel: channel,
         target: target
       }) do
    disconnect_result = disconnect_best_effort(client, channel)
    failure_result = mark_transport_failure(target, :node_timeout)

    unless disconnect_result == :ok or
             durable_reconciliation_confirmed?(failure_result, node_id) do
      Process.put(@pending_cancel_reconciliation_key, {authority, node_id})
    end

    :ok
  end

  defp finalize_pending_cancel_reconciliation(disconnect_result) do
    case Process.delete(@pending_cancel_reconciliation_key) do
      {authority, node_id} when disconnect_result != :ok ->
        AllocationAuthority.quarantine_node(authority, node_id)

      _reconciled_or_not_pending ->
        :ok
    end
  end

  defp durable_reconciliation_confirmed?(
         {:ok, %{id: node_id, health: health}},
         node_id
       )
       when health in [:unhealthy, :unreachable],
       do: true

  defp durable_reconciliation_confirmed?(_result, _node_id), do: false

  defp cancel_drain_timeout_ms(timeout, _request_timeout_ms)
       when is_integer(timeout) and timeout > 0,
       do: timeout

  defp cancel_drain_timeout_ms(_timeout, request_timeout_ms),
    do: min(request_timeout_ms, @maximum_cancel_drain_timeout_ms)

  defp mark_transport_failure(target, reason) do
    case Orchard.Nodes.record_transport_failure(target, reason, DateTime.utc_now()) do
      {:ok, _node} = confirmed -> confirmed
      _unconfirmed -> :noop
    end
  rescue
    error ->
      Logger.warning(
        "Failed to mark runtime endpoint transport failure: #{exception_name(error)}"
      )

      :noop
  end

  defp exception_name(%{__struct__: module}) when is_atom(module), do: Atom.to_string(module)

  defp emit_event(_event, _request_id, nil), do: :ok

  defp emit_event(event, request_id, handler) when is_function(handler, 2) do
    handler.(request_id, event)
  end

  defp emit_event_safely(event, request_id, handler) do
    {:ok, emit_event(event, request_id, handler)}
  rescue
    _error -> {:error, :event_handler_failed}
  catch
    _kind, _reason -> {:error, :event_handler_failed}
  end

  defp cancelled_by_handler?({:ok, handler_result}), do: handler_result == :cancel

  defp handler_failed?({:error, :event_handler_failed}), do: true
  defp handler_failed?(_handler_result), do: false

  defp start_timeout_timer(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    ref = make_ref()
    Process.send_after(self(), {:dispatch_timeout, ref}, timeout_ms)
    ref
  end

  defp cleanup_timer(timer_ref) do
    # Cancel the timeout timer and flush if it already fired
    Process.cancel_timer(timer_ref)

    receive do
      {:dispatch_timeout, ^timer_ref} -> :ok
    after
      0 -> :ok
    end
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
