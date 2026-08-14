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
  on the persisted Request deadline carried as `:timeout_at`, and fails the
  dispatch with `:dispatch_capacity_acceptance_gate_busy` rather than waiting
  behind another in-flight dispatch to the same Node indefinitely. An
  already-elapsed deadline fails as `:dispatch_timeout` without taking the gate.
  Unavailable capacity fails the dispatch rather than proceeding, and reports
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

  alias Orchard.Dispatch.{AttemptEventDelivery, AttemptOutcome}
  alias Orchard.DomainMetrics
  alias Orchard.Inference
  alias Orchard.Inference.{ModelLoadFailure, QueueManager, RequestDeadline}
  alias Orchard.InferenceEvent

  alias Orchard.RuntimeEndpoint.{
    BeamIdentity,
    GrpcCompatibilityMapper,
    Observation,
    Operation,
    Target
  }

  alias Orchard.Requests.InferenceAttemptFailure
  alias Orchard.SentryContext
  alias Orchard.Tokenizer.Telemetry

  require Logger

  @maximum_cancel_drain_timeout_ms 5_000

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
              output_tokens: 0,
              node_id: nil,
              scheduler_strategy: nil,
              model_already_loaded: :unknown,
              ensure_model_loaded_ms: :na,
              accepted_monotonic_ms: nil,
              first_delta_monotonic_ms: nil,
              first_token_at: nil,
              terminal_monotonic_ms: nil,
              accepted_to_first_delta_ms: :na,
              accepted_to_terminal_ms: :na,
              outcome: :ok,
              terminal_kind: :none,
              terminal_source: :none,
              terminal_detail: :na,
              event_count: 0,
              anomaly: :none,
              conformance_defect: :none

    @type t :: %__MODULE__{
            request_id: String.t(),
            model_id: String.t(),
            version: String.t(),
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            node_id: String.t() | nil,
            scheduler_strategy: atom() | String.t() | nil,
            model_already_loaded: boolean() | :unknown,
            ensure_model_loaded_ms: non_neg_integer() | :na,
            accepted_monotonic_ms: integer() | nil,
            first_delta_monotonic_ms: integer() | nil,
            first_token_at: DateTime.t() | nil,
            terminal_monotonic_ms: integer() | nil,
            accepted_to_first_delta_ms: non_neg_integer() | :na,
            accepted_to_terminal_ms: non_neg_integer() | :na,
            outcome: :ok | :model_load_failed | :dispatch_failed | :conformance_failed,
            terminal_kind: :completed | :failed | :none,
            terminal_source: :stream | :synthesized | :none,
            terminal_detail: String.t() | :na,
            event_count: non_neg_integer(),
            anomaly: :none | :delta_before_accepted | :terminal_before_accepted,
            conformance_defect: :none | :missing_terminal | :duplicate_terminal | :post_terminal
          }

    @spec new(keyword()) :: t()
    def new(opts) do
      %__MODULE__{
        request_id: Keyword.fetch!(opts, :request_id),
        model_id: Keyword.get(opts, :model_id, "unknown"),
        version: Keyword.get(opts, :version, "unknown"),
        input_tokens: Keyword.get(opts, :input_tokens, 0),
        output_tokens: 0,
        node_id: Keyword.get(opts, :node_id),
        scheduler_strategy: Keyword.get(opts, :scheduler_strategy),
        model_already_loaded: :unknown,
        ensure_model_loaded_ms: :na,
        accepted_monotonic_ms: nil,
        first_delta_monotonic_ms: nil,
        first_token_at: nil,
        terminal_monotonic_ms: nil,
        accepted_to_first_delta_ms: :na,
        accepted_to_terminal_ms: :na,
        outcome: :ok,
        terminal_kind: :none,
        terminal_source: :none,
        terminal_detail: :na,
        event_count: 0,
        anomaly: :none,
        conformance_defect: :none
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

  @type dispatch_result :: AttemptOutcome.t()

  @doc """
  Dispatch an inference request to a Runtime Endpoint and stream events back to the caller.

  `schedule` is the map returned by the configured scheduler containing:
  - `:runtime_endpoint_target` - typed Runtime Endpoint target for new schedulers
  - `:runtime_client_target` - legacy `[host: ..., port: ...]` gRPC compatibility target
  - `:request_id` - the canonical request ID
  - `:timeout_at` - the persisted absolute logical Request deadline. It covers
    queueing, scheduling, model loading, connect, probe, acceptance-gate
    acquisition, and streaming.

  BEAM schedules may omit `:runtime_client_target`.
  If a configured BEAM target node ID conflicts with observed endpoint metadata,
  dispatch fails before model load rather than trusting the mismatched identity.

  `execute_request` is the protobuf compatibility `ExecuteInferenceRequest` to map into a Runtime Endpoint operation.

  `model_load_request` is the protobuf compatibility `EnsureModelLoadedRequest` to map into a Runtime Endpoint operation.

  Options:
  - `:caller` - PID to monitor for disconnect (default: `self()`)
  - `:event_handler` - public delivery callback called only after attempt selection.
                        It must return `:ok`, `:cancel`, or `{:error, :serializer_failed}`.
  - `:on_accepted` - immediate internal callback for validated acceptance observation.
  - `:on_node_resolved` - optional callback `(node_id :: String.t() -> any())`.
                           Called when the pre-dispatch status probe discovers a
                           valid node UUID. Synchronous, lightweight, observational only.
                           Exceptions and exits are logged and ignored; return value is ignored.
  - `:client_impl` - Runtime Endpoint client module
                     (default: `Inference.runtime_endpoint_client/0`)
  - `:cancel_drain_timeout_ms` - bounded cancellation reconciliation grace period
                                 (default: the lesser of request timeout and 5 seconds)

  Returns one `Orchard.Dispatch.AttemptOutcome` containing the ordered caller-visible
  events and the evidence needed to persist this attempt. Invalid duplicate or
  post-terminal worker events are withheld and replaced by a stable conformance
  failure. Runtime Endpoint disconnect cleanup is reflected in execution and
  release evidence when termination cannot be proved.
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
    timeout_at = Map.fetch!(schedule, :timeout_at)
    now = DateTime.utc_now()
    system_ms = DateTime.to_unix(now, :millisecond)
    monotonic_ms = System.monotonic_time(:millisecond)
    timeout_ms = RequestDeadline.remaining_ms(timeout_at, now)
    deadline_ms = RequestDeadline.to_monotonic_ms(timeout_at, system_ms, monotonic_ms)

    model_load_timeout_cap_ms = Map.get(schedule, :model_load_timeout_ms, 120_000)
    caller = Keyword.get(opts, :caller, self())
    caller_ref = Process.monitor(caller)
    event_handler = Keyword.get(opts, :event_handler)
    on_accepted = Keyword.get(opts, :on_accepted)
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
      model_load_timeout_cap_ms: model_load_timeout_cap_ms,
      timeout_ms: timeout_ms,
      deadline_ms: deadline_ms,
      caller: caller,
      caller_ref: caller_ref,
      cancel_drain_timeout_ms: cancel_drain_timeout_ms,
      event_handler: event_handler,
      on_accepted: on_accepted,
      on_node_resolved: on_node_resolved
    }

    started_at = DateTime.truncate(now, :microsecond)

    try do
      {result, release_outcome} =
        if timeout_ms <= 0 do
          {{:error, {:dispatch_failed, :dispatch_timeout}}, :not_applicable}
        else
          case preensure_prompt_token_ids_gate(execute_request, schedule, model_load_request) do
            :ok ->
              dispatch_with_capacity_claim(context)

            {:error, reason} ->
              error_metrics = finalize_metrics(metrics, {:error, {:dispatch_failed, reason}})
              put_dispatch_terminal_context(error_metrics, target)
              emit_timing_log(error_metrics, {:error, {:dispatch_failed, reason}})
              {{:error, {:dispatch_failed, reason}}, :not_applicable}
          end
        end

      build_attempt_outcome(result, release_outcome, started_at, schedule)
    after
      Process.demonitor(caller_ref, [:flush])
    end
  end

  # -- Private ---------------------------------------------------------------

  defp build_attempt_outcome(result, release_outcome, started_at, schedule) do
    {result, execution_evidence, safety_state, first_token_at} = attempt_evidence(result)
    ended_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    events = result_events(result)
    accepted = Enum.any?(events, &match?(%InferenceEvent{event: %InferenceEvent.Accepted{}}, &1))
    terminal = List.last(events)
    delivery = result_delivery(result)
    attempt_outcome = attempt_outcome(result, terminal)

    attrs = %{
      attempt_outcome: attempt_outcome,
      node_id: trusted_node_id(schedule),
      accepted: accepted,
      events: events,
      failure: attempt_failure(result, terminal, attempt_outcome),
      execution_resolution: execution_evidence || execution_resolution(result, terminal),
      capacity_release_outcome:
        effective_release_outcome(release_outcome, execution_evidence, safety_state),
      started_at: started_at,
      ended_at: ended_at,
      first_token_at: first_token_at,
      output_committed: delivery_output_committed?(delivery),
      output_commitment_kind: delivery_commitment_kind(delivery),
      delivery_state: delivery_state(delivery),
      delivered_event_count: delivered_event_count(delivery)
    }

    {:ok, outcome} = AttemptOutcome.new(attrs)
    apply_delivery_failure(outcome, delivery)
  end

  defp attempt_evidence(
         {:attempt_evidence, {:attempt_timing, result, first_token_at}, execution_resolution,
          safety_state}
       ),
       do: {result, execution_resolution, safety_state, first_token_at}

  defp attempt_evidence({:attempt_evidence, result, execution_resolution, safety_state}),
    do: {result, execution_resolution, safety_state, nil}

  defp attempt_evidence({:attempt_timing, result, first_token_at}),
    do: {result, nil, :available, first_token_at}

  defp attempt_evidence(result), do: {result, nil, :available, nil}

  defp effective_release_outcome(_release_outcome, :unresolved, _safety_state), do: :unresolved

  defp effective_release_outcome(_release_outcome, _execution_resolution, :unavailable),
    do: :unresolved

  defp effective_release_outcome(release_outcome, _execution_resolution, _safety_state),
    do: release_outcome

  defp result_events({:ok, events, %AttemptEventDelivery{}}) when is_list(events), do: events
  defp result_events(_result), do: []

  defp result_delivery({:ok, _events, %AttemptEventDelivery{} = delivery}), do: delivery
  defp result_delivery(_result), do: nil

  defp apply_delivery_failure(outcome, %AttemptEventDelivery{} = delivery) do
    case AttemptEventDelivery.failure_reason(delivery) do
      :cancel ->
        AttemptOutcome.cancel_delivery(outcome, outcome.delivered_event_count)

      reason when reason in [:serializer_failed, :event_handler_failed] ->
        AttemptOutcome.fail_delivery(outcome, outcome.delivered_event_count)

      nil ->
        outcome
    end
  end

  defp apply_delivery_failure(outcome, nil), do: outcome

  defp delivery_output_committed?(%AttemptEventDelivery{} = delivery),
    do: AttemptEventDelivery.output_committed?(delivery)

  defp delivery_output_committed?(nil), do: false

  defp delivery_commitment_kind(%AttemptEventDelivery{} = delivery),
    do: AttemptEventDelivery.commitment_kind(delivery)

  defp delivery_commitment_kind(nil), do: nil

  defp delivery_state(%AttemptEventDelivery{} = delivery),
    do: AttemptEventDelivery.delivery_state(delivery)

  defp delivery_state(nil), do: :pending

  defp delivered_event_count(%AttemptEventDelivery{} = delivery),
    do: AttemptEventDelivery.delivered_event_count(delivery)

  defp delivered_event_count(nil), do: 0

  defp attempt_outcome(_result, %InferenceEvent{event: %InferenceEvent.Completed{}}),
    do: :completed

  defp attempt_outcome(_result, %InferenceEvent{event: %InferenceEvent.Failed{code: code}})
       when code in ["deadline_exceeded", "request_timeout", "request_timed_out", "timed_out"],
       do: :timed_out

  defp attempt_outcome(_result, %InferenceEvent{event: %InferenceEvent.Failed{code: code}})
       when code in [
              "cancelled",
              "request_cancelled",
              "request_caller_disconnect",
              "request_client_disconnect"
            ],
       do: :cancelled

  defp attempt_outcome(_result, %InferenceEvent{event: %InferenceEvent.Failed{}}), do: :failed

  defp attempt_outcome({:error, {:dispatch_failed, reason}}, _terminal)
       when reason in [:dispatch_timeout, :request_timeout],
       do: :timed_out

  defp attempt_outcome({:error, {:dispatch_failed, reason}}, _terminal)
       when reason in [:caller_disconnect, :request_caller_disconnect],
       do: :cancelled

  defp attempt_outcome(_result, _terminal), do: :failed

  defp attempt_failure(_result, _terminal, :completed), do: nil

  defp attempt_failure(
         _result,
         %InferenceEvent{event: %InferenceEvent.Failed{code: code}},
         _outcome
       ) do
    InferenceAttemptFailure.normalize(failure_source(code))
  end

  defp attempt_failure(
         {:error, {:model_load_failed, %ModelLoadFailure{} = failure}},
         _terminal,
         _outcome
       ) do
    evidence =
      InferenceAttemptFailure.normalize(%{
        category: :model_load,
        code: failure.category,
        phase: :model_load
      })

    if failure.code == evidence["failure_code"] do
      evidence
    else
      Map.put(evidence, "raw_source_code", failure.code)
    end
  end

  defp attempt_failure({:error, {:dispatch_failed, reason}}, _terminal, _outcome) do
    InferenceAttemptFailure.normalize(failure_source(reason))
  end

  defp attempt_failure(_result, _terminal, _outcome),
    do: InferenceAttemptFailure.normalize(%{category: :controller, code: :internal_error})

  defp failure_source(reason) when reason in [:dispatch_timeout, :request_timeout],
    do: %{category: :deadline, code: :request_timeout}

  defp failure_source(reason) when reason in [:caller_disconnect, :request_caller_disconnect],
    do: %{category: :cancellation, code: :request_caller_disconnect}

  defp failure_source(code)
       when code in ["deadline_exceeded", "request_timeout", "request_timed_out", "timed_out"],
       do: %{category: :deadline, code: code}

  defp failure_source(code)
       when code in [
              "cancelled",
              "request_cancelled",
              "request_caller_disconnect",
              "request_client_disconnect"
            ],
       do: %{category: :cancellation, code: code}

  defp failure_source(code)
       when code in [
              "runtime_endpoint_missing_terminal",
              "runtime_endpoint_duplicate_terminal",
              "runtime_endpoint_post_terminal_event"
            ],
       do: %{category: :terminal_conformance, code: code}

  defp failure_source(reason)
       when reason in [
              :dispatch_capacity_unavailable,
              :dispatch_capacity_facts_unavailable,
              :dispatch_capacity_request_already_claimed,
              :dispatch_capacity_revalidation_failed,
              :dispatch_capacity_acceptance_gate_busy,
              :dispatch_capacity_node_identity_mismatch,
              :dispatch_capacity_quarantine_store_unavailable
            ],
       do: %{category: :capacity, code: reason}

  defp failure_source(reason), do: %{category: :runtime, code: reason}

  defp execution_resolution({:ok, _events, %AttemptEventDelivery{}}, %InferenceEvent{}),
    do: :terminated

  defp execution_resolution(_result, _terminal), do: :not_started

  defp trusted_node_id(schedule) do
    case Map.get(schedule, :node_id) do
      node_id when is_binary(node_id) ->
        if match?({:ok, _uuid}, Ecto.UUID.cast(node_id)), do: node_id, else: nil

      _node_id ->
        nil
    end
  end

  defp dispatch_with_capacity_claim(%{schedule: schedule} = context) do
    if deadline_expired?(context) do
      {dispatch_timeout_result(context), :not_applicable}
    else
      dispatch_with_live_capacity_claim(context, schedule)
    end
  end

  defp dispatch_with_live_capacity_claim(context, schedule) do
    case acquire_capacity_claim(schedule) do
      {:ok, nil} ->
        result = dispatch_after_preensure_gate(context)
        {result, effective_release_from_result(result, :not_applicable)}

      {:ok, claim} ->
        try do
          result = dispatch_after_preensure_gate(Map.put(context, :capacity_claim, claim))

          release_outcome =
            effective_release_from_result(result, release_capacity_claim(schedule, claim))

          {result, release_outcome}
        after
          _defensive_release = release_capacity_claim(schedule, claim)
        end

      {:error, reason} ->
        result =
          handle_dispatch_result(
            {:error, {:dispatch_failed, reason}},
            context.metrics,
            context.target
          )

        {result, :not_applicable}
    end
  end

  defp effective_release_from_result(
         {:attempt_evidence, _result, execution_resolution, safety_state},
         release_outcome
       ),
       do: effective_release_outcome(release_outcome, execution_resolution, safety_state)

  defp effective_release_from_result(_result, release_outcome), do: release_outcome

  defp acquire_capacity_claim(
         %{
           dispatch_capacity_input:
             %Orchard.DispatchCapacity.Evaluator.Input{
               management_classification: {:ok, management_class}
             } = input,
           dispatch_capacity_evaluation: %Orchard.DispatchCapacity.Evaluator.Result{} = result,
           request_id: request_id
         } = schedule
       )
       when is_binary(request_id) and
              management_class in [
                :unmanaged_source_development,
                :unmanaged_compatibility
              ] do
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

  defp acquire_capacity_claim(
         %{
           node_id: node_id,
           request_id: request_id
         } = schedule
       )
       when is_binary(node_id) and is_binary(request_id) do
    case dispatch_capacity_acquisition_input(schedule) do
      %Orchard.DispatchCapacity.Evaluator.Input{} = input ->
        acquire_production_capacity_claim(schedule, node_id, request_id, input)

      _missing_input ->
        {:error, :dispatch_capacity_facts_unavailable}
    end
  end

  defp acquire_capacity_claim(_schedule), do: {:error, :dispatch_capacity_facts_unavailable}

  defp acquire_production_capacity_claim(schedule, node_id, request_id, input) do
    opts = capacity_authority_opts(schedule)

    case QueueManager.acquire_dispatch_capacity(node_id, request_id, input, opts) do
      {:ok, claim, _result} -> {:ok, claim}
      {:error, reason, _result} -> {:error, reason}
    end
  end

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
    if deadline_expired?(context) do
      dispatch_timeout_result(context)
    else
      case authorize_dispatch_target(target) do
        :ok ->
          connect_for_dispatch(client, target, context)

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
  end

  defp connect_for_dispatch(client, target, context) do
    case client.connect(target) do
      {:ok, channel} ->
        dispatch_with_channel(Map.put(context, :channel, channel))

      {:error, reason} ->
        handle_dispatch_connect_failure(target, reason, context.metrics)
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
    dispatch_result =
      try do
        {:ok, do_dispatch_with_channel(context)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    disconnect_result = disconnect_best_effort(client, channel)

    case dispatch_result do
      {:ok, result} ->
        resolve_cancel_reconciliation(result, disconnect_result)

      {:raised, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp resolve_cancel_reconciliation(
         {:cancel_reconciliation, result, authority, node_id, failure_result},
         disconnect_result
       ) do
    if disconnect_result == :ok or durable_reconciliation_confirmed?(failure_result, node_id) do
      {:attempt_evidence, result, :terminated, :available}
    else
      {:attempt_evidence, result, :unresolved, quarantine_safety_state(authority, node_id)}
    end
  end

  defp resolve_cancel_reconciliation(result, _disconnect_result), do: result

  defp quarantine_safety_state(authority, node_id) do
    case AllocationAuthority.quarantine_node(authority, node_id) do
      :ok -> :available
      {:error, _reason} -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
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
    if deadline_expired?(context) do
      dispatch_timeout_result(context)
    else
      dispatch_after_live_channel(context)
    end
  end

  defp dispatch_after_live_channel(context) do
    case prepare_dispatch_identity(context) do
      {:ok, model_load_request, metrics} ->
        context = %{context | model_load_request: model_load_request, metrics: metrics}
        ensure_loaded_before_deadline(context, model_load_request, metrics)

      {:error, reason, metrics} ->
        handle_dispatch_result({:error, {:dispatch_failed, reason}}, metrics, context.target)
    end
  end

  defp ensure_loaded_before_deadline(context, model_load_request, metrics) do
    model_load_timeout =
      min(
        context.model_load_timeout_cap_ms,
        remaining_request_timeout_ms(context.deadline_ms)
      )

    if model_load_timeout <= 0 do
      dispatch_timeout_result(%{context | metrics: metrics})
    else
      ensure_start = System.monotonic_time(:millisecond)
      put_ensure_model_load_started_context(metrics)

      context.client
      |> ensure_loaded_for_dispatch(
        context.channel,
        context.target,
        model_load_request,
        model_load_timeout
      )
      |> handle_ensure_result(context, ensure_start)
    end
  end

  defp prepare_dispatch_identity(
         %{
           schedule: %{dispatch_identity_source: :trusted_monitor_snapshot}
         } = context
       ) do
    trusted_snapshot_identity(context)
  end

  defp prepare_dispatch_identity(
         %{
           schedule: %{
             dispatch_identity_source: {:bounded_compatibility_probe, %Observation{}}
           }
         } = context
       ) do
    captured_compatibility_identity(context)
  end

  defp prepare_dispatch_identity(context) do
    probe_and_resolve_node(
      context.client,
      context.channel,
      context.target,
      context.model_load_request,
      claimed_node_id(context),
      context.on_node_resolved,
      context.metrics
    )
  end

  defp trusted_snapshot_identity(%{
         capacity_claim: %AllocationAuthority.Claim{node_id: claim_node_id},
         schedule: %{node_id: schedule_node_id},
         target: %Target{node_id: target_node_id} = target,
         model_load_request: model_load_request,
         on_node_resolved: on_node_resolved,
         metrics: metrics
       })
       when is_binary(claim_node_id) and claim_node_id == schedule_node_id and
              schedule_node_id == target_node_id do
    {node_id, model_load_request, metrics} =
      resolved_probe_identity(
        {:ok, claim_node_id},
        target,
        model_load_request,
        metrics
      )

    invoke_callback_safe(on_node_resolved, node_id)
    {:ok, model_load_request, metrics}
  end

  defp trusted_snapshot_identity(%{metrics: metrics}) do
    {:error, :dispatch_capacity_node_identity_mismatch, metrics}
  end

  defp captured_compatibility_identity(%{
         schedule: %{
           dispatch_identity_source: {:bounded_compatibility_probe, %Observation{} = observation},
           dispatch_capacity_input: %Orchard.DispatchCapacity.Evaluator.Input{
             management_classification: {:ok, management_class}
           },
           node_id: schedule_node_id
         },
         target: %Target{node_id: target_node_id} = target,
         model_load_request: model_load_request,
         on_node_resolved: on_node_resolved,
         metrics: metrics
       })
       when management_class in [
              :unmanaged_compatibility,
              :unmanaged_source_development
            ] and is_binary(schedule_node_id) and
              (is_nil(target_node_id) or schedule_node_id == target_node_id) do
    case BeamIdentity.resolve_candidate_node_id(target, observation) do
      {:ok, ^schedule_node_id} ->
        {node_id, model_load_request, metrics} =
          resolved_probe_identity(
            {:ok, schedule_node_id},
            target,
            model_load_request,
            metrics
          )

        invoke_callback_safe(on_node_resolved, node_id)
        {:ok, model_load_request, metrics}

      _identity_mismatch ->
        {:error, :dispatch_capacity_node_identity_mismatch, metrics}
    end
  end

  defp captured_compatibility_identity(%{metrics: metrics}) do
    {:error, :dispatch_capacity_node_identity_mismatch, metrics}
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

    unless ensure_load_meta.already_loaded do
      DomainMetrics.model_load(metrics.node_id, metrics.model_id, metrics.ensure_model_loaded_ms)
    end

    context = Map.put(context, :ensure_model_loaded_result, ensure_load_meta)

    if deadline_expired?(context) do
      dispatch_timeout_result(%{context | metrics: metrics})
    else
      context
      |> execute_loaded_request(ensure_load_meta, metrics)
      |> handle_dispatch_result(metrics, context.target)
    end
  end

  defp handle_ensure_result({:error, reason}, context, ensure_start) do
    ensure_end = System.monotonic_time(:millisecond)

    metrics = %{
      context.metrics
      | ensure_model_loaded_ms: ensure_end - ensure_start,
        model_already_loaded: false
    }

    if deadline_expired?(context) do
      dispatch_timeout_result(%{context | metrics: metrics})
    else
      error_metrics = finalize_metrics(metrics, {:error, {:model_load_failed, reason}})
      DomainMetrics.model_load(metrics.node_id, metrics.model_id, metrics.ensure_model_loaded_ms)
      put_dispatch_terminal_context(error_metrics, context.target)
      emit_timing_log(error_metrics, {:error, {:model_load_failed, reason}})
      {:error, {:model_load_failed, reason}}
    end
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
        timeout_ms = remaining_request_timeout_ms(context.deadline_ms)

        if timeout_ms <= 0 do
          {:error, {:dispatch_failed, :dispatch_timeout}}
        else
          stream_context = %{
            acceptance_gate: acceptance_gate,
            caller_ref: context.caller_ref,
            cancel_drain_timeout_ms: context.cancel_drain_timeout_ms,
            capacity_authority: capacity_authority(context.schedule),
            capacity_node_id: metrics.node_id,
            channel: context.channel,
            client: context.client,
            event_handler: context.event_handler,
            on_accepted: context.on_accepted,
            target: context.target,
            timeout_ms: timeout_ms
          }

          do_execute_and_stream(stream_context, gated_execute_request, metrics)
        end

      {:error, :dispatch_capacity_revalidation_failed, _result} ->
        {:error, {:dispatch_failed, :dispatch_capacity_revalidation_failed}}
    end
  after
    release_dispatch_acceptance_gate(acceptance_gate)
  end

  defp revalidate_capacity_claim(%{
         capacity_claim: claim,
         schedule: schedule,
         ensure_model_loaded_result: ensure_model_loaded_result
       }) do
    with %Orchard.DispatchCapacity.Evaluator.Input{} = input <-
           dispatch_capacity_revalidation_input(schedule, ensure_model_loaded_result),
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

  defp revalidate_capacity_claim(%{
         schedule: schedule,
         ensure_model_loaded_result: ensure_model_loaded_result
       }) do
    with %Orchard.DispatchCapacity.Evaluator.Input{} = input <-
           dispatch_capacity_revalidation_input(schedule, ensure_model_loaded_result),
         result <- evaluate_dispatch_capacity(capacity_authority(schedule), nil, input),
         true <- unmanaged_dispatch_authorized?(input, result) do
      :ok
    else
      _unavailable -> {:error, :dispatch_capacity_revalidation_failed, nil}
    end
  end

  defp dispatch_capacity_revalidation_input(schedule, ensure_model_loaded_result) do
    case Map.get(schedule, :dispatch_capacity_input_provider) do
      provider when is_function(provider, 1) -> provider.(ensure_model_loaded_result)
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

  defp acquire_dispatch_acceptance_gate(context) do
    if remaining_request_timeout_ms(context.deadline_ms) <= 0,
      do: {:error, :dispatch_timeout},
      else: {:ok, nil}
  end

  defp remaining_request_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp deadline_expired?(context), do: remaining_request_timeout_ms(context.deadline_ms) <= 0

  defp dispatch_timeout_result(context) do
    handle_dispatch_result(
      {:error, {:dispatch_failed, :dispatch_timeout}},
      context.metrics,
      context.target
    )
  end

  defp release_dispatch_acceptance_gate(nil), do: :ok

  defp release_dispatch_acceptance_gate({lease, opts}) do
    QueueManager.release_acceptance_gate(lease, opts)
  end

  defp handle_dispatch_result(
         {:attempt_evidence, result, execution_resolution, safety_state},
         metrics,
         target
       ) do
    normalized_result = handle_dispatch_result(result, metrics, target)
    {:attempt_evidence, normalized_result, execution_resolution, safety_state}
  end

  defp handle_dispatch_result(
         {:cancel_reconciliation, result, authority, node_id, failure_result},
         metrics,
         target
       ) do
    normalized_result = handle_dispatch_result(result, metrics, target)
    {:cancel_reconciliation, normalized_result, authority, node_id, failure_result}
  end

  defp handle_dispatch_result(
         {:ok, events, final_metrics, %AttemptEventDelivery{} = delivery},
         _metrics,
         target
       ) do
    final_metrics = finalize_metrics(final_metrics, :ok)
    put_dispatch_terminal_context(final_metrics, target)
    emit_timing_log(final_metrics, :ok)
    {:attempt_timing, {:ok, events, delivery}, final_metrics.first_token_at}
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
            {:ok, response}

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
            result =
              receive_loop(
                %{
                  caller_ref: caller_ref,
                  channel: channel,
                  client: client,
                  controller_session_id: execute_request.controller_session_id,
                  delivery: AttemptEventDelivery.new(metrics.request_id, event_handler),
                  on_accepted: Map.get(stream_context, :on_accepted),
                  accepted?: false,
                  acceptance_gate: acceptance_gate,
                  cancel_drain_timeout_ms: cancel_drain_timeout_ms,
                  capacity_authority: capacity_authority,
                  capacity_node_id: capacity_node_id,
                  cancellation_started_before_acceptance?: false,
                  conformance_defect: :none,
                  metrics: metrics,
                  target: target,
                  task_ref: task_ref,
                  terminal_event: nil,
                  timer_ref: timer_ref
                },
                []
              )

            case result do
              {:cancel_reconciliation, _result, _authority, _node_id, _failure_result} -> result
              _resolved -> {:attempt_evidence, result, :terminated, :available}
            end

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
      caller_ref: caller_ref
    } = loop_ctx

    request_id = metrics.request_id

    receive do
      {:runtime_endpoint_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        handle_stream_event(loop_ctx, events, event)

      {:runtime_endpoint_done, ^task_ref, :ok} ->
        stream_done_result(loop_ctx, events, metrics)

      {:runtime_endpoint_done, ^task_ref, {:error, reason}} ->
        mark_transport_failure(target, reason)
        stream_error_result(loop_ctx, events, metrics, reason)

      {:dispatch_timeout, ^timer_ref} ->
        cancel_and_drain(%{loop_ctx | metrics: metrics}, events, :timeout)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        cancel_and_drain(%{loop_ctx | metrics: metrics}, events, :caller_disconnect)
    end
  end

  defp handle_stream_event(%{terminal_event: nil} = loop_ctx, events, event) do
    cond do
      isolated_nonterminal_event?(loop_ctx, event) ->
        metrics = increment_event_count(loop_ctx.metrics)
        receive_loop(%{loop_ctx | metrics: metrics}, events)

      InferenceEvent.terminal?(event) ->
        metrics = update_metrics_for_event(loop_ctx.metrics, event)
        receive_loop(%{loop_ctx | metrics: metrics, terminal_event: event}, events)

      true ->
        metrics = update_metrics_for_event(loop_ctx.metrics, event)
        loop_ctx = maybe_record_acceptance(loop_ctx, event)
        delivery = AttemptEventDelivery.record(loop_ctx.delivery, event)
        loop_ctx = %{loop_ctx | delivery: delivery, metrics: metrics}
        events = [event | events]

        case AttemptEventDelivery.failure_reason(delivery) do
          reason when reason in [:event_handler_failed, :serializer_failed] ->
            cancel_and_drain(loop_ctx, events, :event_handler_failed)

          :cancel ->
            cancel_and_drain(loop_ctx, events, :client_disconnect)

          nil ->
            receive_loop(loop_ctx, events)
        end
    end
  end

  defp handle_stream_event(%{terminal_event: %InferenceEvent{}} = loop_ctx, events, event) do
    defect = if InferenceEvent.terminal?(event), do: :duplicate_terminal, else: :post_terminal

    loop_ctx = %{
      loop_ctx
      | conformance_defect: first_conformance_defect(loop_ctx.conformance_defect, defect),
        metrics: increment_event_count(loop_ctx.metrics)
    }

    receive_loop(loop_ctx, events)
  end

  defp isolated_nonterminal_event?(loop_ctx, event) do
    isolated_attempt?(loop_ctx) and not InferenceEvent.terminal?(event) and
      InferenceEvent.kind(event) != :accepted
  end

  defp isolated_attempt?(%{
         accepted?: accepted?,
         cancellation_started_before_acceptance?: cancellation_started_before_acceptance?
       }),
       do: not accepted? or cancellation_started_before_acceptance?

  defp first_conformance_defect(:none, defect), do: defect
  defp first_conformance_defect(defect, _later_defect), do: defect

  defp maybe_record_acceptance(
         %{acceptance_gate: acceptance_gate} = loop_ctx,
         %InferenceEvent{event: %InferenceEvent.Accepted{}} = event
       ) do
    release_dispatch_acceptance_gate(acceptance_gate)
    notify_accepted(loop_ctx.on_accepted, loop_ctx.metrics.request_id, event)
    %{loop_ctx | acceptance_gate: nil, accepted?: true}
  end

  defp maybe_record_acceptance(loop_ctx, _event), do: loop_ctx

  defp notify_accepted(nil, _request_id, _event), do: :ok

  defp notify_accepted(callback, request_id, event) when is_function(callback, 2) do
    _result = callback.(request_id, event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp record_delivery(loop_ctx, event) do
    %{loop_ctx | delivery: AttemptEventDelivery.record(loop_ctx.delivery, event)}
  end

  defp stream_error_result(
         %{
           accepted?: true,
           cancellation_started_before_acceptance?: false,
           conformance_defect: defect
         } = loop_ctx,
         events,
         metrics,
         _reason
       )
       when defect != :none do
    synthesize_terminal_contract_failure(loop_ctx, events, metrics, defect)
  end

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

    loop_ctx = record_delivery(loop_ctx, failed_event)
    metrics = update_metrics_for_terminal(metrics, failed_event, :stream)
    stream_terminal_result(loop_ctx, [failed_event | events], metrics)
  end

  defp stream_error_result(_loop_ctx, _events, _metrics, reason),
    do: {:error, {:dispatch_failed, reason}}

  defp stream_done_result(
         %{accepted?: true, cancellation_started_before_acceptance?: false} = loop_ctx,
         events,
         metrics
       ) do
    case {loop_ctx.terminal_event, loop_ctx.conformance_defect} do
      {nil, :none} ->
        synthesize_terminal_contract_failure(loop_ctx, events, metrics, :missing_terminal)

      {%InferenceEvent{} = terminal_event, :none} ->
        loop_ctx = record_delivery(loop_ctx, terminal_event)
        stream_terminal_result(loop_ctx, [terminal_event | events], metrics)

      {%InferenceEvent{}, defect} ->
        synthesize_terminal_contract_failure(loop_ctx, events, metrics, defect)
    end
  end

  defp stream_done_result(loop_ctx, events, metrics),
    do: stream_terminal_result(loop_ctx, events, metrics)

  defp synthesize_terminal_contract_failure(loop_ctx, events, metrics, defect) do
    {code, message} = terminal_contract_failure(defect)

    failed_event =
      InferenceEvent.failed(code, message, false)

    loop_ctx = record_delivery(loop_ctx, failed_event)

    metrics =
      metrics
      |> increment_event_count()
      |> update_metrics_for_terminal(failed_event, :synthesized)
      |> Map.put(:conformance_defect, defect)

    stream_terminal_result(loop_ctx, [failed_event | events], metrics)
  end

  defp terminal_contract_failure(:missing_terminal),
    do:
      {"runtime_endpoint_missing_terminal",
       "Runtime Endpoint stream ended without a terminal event"}

  defp terminal_contract_failure(:duplicate_terminal),
    do:
      {"runtime_endpoint_duplicate_terminal",
       "Runtime Endpoint stream emitted more than one terminal event"}

  defp terminal_contract_failure(:post_terminal),
    do:
      {"runtime_endpoint_post_terminal_event",
       "Runtime Endpoint stream emitted an event after its terminal event"}

  defp stream_terminal_result(loop_ctx, events, metrics),
    do: stream_terminal_result(loop_ctx, events, metrics, nil)

  defp stream_terminal_result(
         %{
           accepted?: true,
           cancellation_started_before_acceptance?: false,
           delivery: delivery
         },
         events,
         metrics,
         _cancel_reason
       ),
       do: {:ok, Enum.reverse(events), metrics, delivery}

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

    drain_until_terminal_or_done(loop_ctx, events, cancel_reason, cancel_deadline)
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
      metrics: metrics
    } = loop_ctx

    request_id = metrics.request_id
    remaining_ms = cancel_deadline - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      receive do
        {:runtime_endpoint_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
          handle_drain_event(loop_ctx, events, event, cancel_reason, cancel_deadline)

        {:runtime_endpoint_done, ^task_ref, _result} ->
          drain_done_result(loop_ctx, events, cancel_reason)
      after
        remaining_ms -> cancel_drain_timeout_result(loop_ctx, events, cancel_reason)
      end
    else
      cancel_drain_timeout_result(loop_ctx, events, cancel_reason)
    end
  end

  defp handle_drain_event(%{terminal_event: nil} = loop_ctx, events, event, reason, deadline) do
    cond do
      isolated_nonterminal_event?(loop_ctx, event) ->
        metrics = increment_event_count(loop_ctx.metrics)
        drain_until_terminal_or_done(%{loop_ctx | metrics: metrics}, events, reason, deadline)

      InferenceEvent.terminal?(event) ->
        metrics = update_metrics_for_event(loop_ctx.metrics, event)

        drain_until_terminal_or_done(
          %{loop_ctx | metrics: metrics, terminal_event: event},
          events,
          reason,
          deadline
        )

      true ->
        metrics = update_metrics_for_event(loop_ctx.metrics, event)
        loop_ctx = maybe_record_acceptance(loop_ctx, event)
        loop_ctx = loop_ctx |> record_delivery(event) |> Map.put(:metrics, metrics)

        drain_until_terminal_or_done(
          loop_ctx,
          [event | events],
          reason,
          deadline
        )
    end
  end

  defp handle_drain_event(
         %{terminal_event: %InferenceEvent{}} = loop_ctx,
         events,
         event,
         reason,
         deadline
       ) do
    defect = if InferenceEvent.terminal?(event), do: :duplicate_terminal, else: :post_terminal

    loop_ctx = %{
      loop_ctx
      | conformance_defect: first_conformance_defect(loop_ctx.conformance_defect, defect),
        metrics: increment_event_count(loop_ctx.metrics)
    }

    drain_until_terminal_or_done(loop_ctx, events, reason, deadline)
  end

  defp drain_done_result(%{conformance_defect: defect} = loop_ctx, events, _cancel_reason)
       when defect != :none do
    synthesize_terminal_contract_failure(loop_ctx, events, loop_ctx.metrics, defect)
  end

  defp drain_done_result(loop_ctx, events, cancel_reason)
       when cancel_reason in [:timeout, :caller_disconnect, :client_disconnect] do
    normalized_reason =
      if cancel_reason == :timeout, do: :timeout, else: :caller_disconnect

    synthesize_cancel_terminal(loop_ctx, events, normalized_reason, "")
  end

  defp drain_done_result(
         %{terminal_event: %InferenceEvent{} = terminal_event} = loop_ctx,
         events,
         cancel_reason
       ) do
    loop_ctx = record_delivery(loop_ctx, terminal_event)

    stream_terminal_result(
      loop_ctx,
      [terminal_event | events],
      loop_ctx.metrics,
      cancel_reason
    )
  end

  defp drain_done_result(loop_ctx, events, cancel_reason),
    do: synthesize_cancel_terminal(loop_ctx, events, cancel_reason, "")

  defp cancel_drain_timeout_result(loop_ctx, events, cancel_reason) do
    result =
      case loop_ctx.conformance_defect do
        :none ->
          synthesize_cancel_terminal(loop_ctx, events, cancel_reason, " after drain timeout")

        defect ->
          synthesize_terminal_contract_failure(loop_ctx, events, loop_ctx.metrics, defect)
      end

    reconcile_cancel_drain_timeout(loop_ctx, result)
  end

  defp synthesize_cancel_terminal(loop_ctx, events, cancel_reason, message_suffix) do
    %{metrics: metrics} = loop_ctx

    timeout_event =
      InferenceEvent.failed(
        "request_#{cancel_reason}",
        "request #{cancel_reason}#{message_suffix}",
        false
      )

    loop_ctx = record_delivery(loop_ctx, timeout_event)

    metrics =
      metrics
      |> increment_event_count()
      |> update_metrics_for_terminal(timeout_event, :synthesized)

    put_terminal_synthesized_context(metrics, cancel_reason)
    stream_terminal_result(loop_ctx, [timeout_event | events], metrics, cancel_reason)
  end

  defp reconcile_cancel_drain_timeout(
         %{
           capacity_authority: authority,
           capacity_node_id: node_id,
           target: target
         },
         result
       ) do
    failure_result = mark_transport_failure(target, :node_timeout)
    {:cancel_reconciliation, result, authority, node_id, failure_result}
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
    |> track_usage(event)
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
    first_token_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    metrics = %{metrics | first_delta_monotonic_ms: now_ms, first_token_at: first_token_at}

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

  defp track_usage(
         %Metrics{} = metrics,
         %InferenceEvent{event: %InferenceEvent.UsageUpdate{usage: usage}}
       ) do
    put_output_tokens(metrics, usage)
  end

  defp track_usage(
         %Metrics{} = metrics,
         %InferenceEvent{event: %InferenceEvent.Completed{usage: usage}}
       ) do
    put_output_tokens(metrics, usage)
  end

  defp track_usage(metrics, _event), do: metrics

  defp put_output_tokens(metrics, %{output_tokens: output_tokens})
       when is_integer(output_tokens) and output_tokens >= 0 do
    %{metrics | output_tokens: output_tokens}
  end

  defp put_output_tokens(metrics, _usage), do: metrics

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
    emit_decode_throughput(metrics)

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
        "anomaly=#{metrics.anomaly} " <>
        "conformance_defect=#{metrics.conformance_defect}"
    )
  end

  defp emit_decode_throughput(%Metrics{
         outcome: :ok,
         terminal_kind: :completed,
         node_id: node_id,
         model_id: model_id,
         output_tokens: output_tokens,
         first_delta_monotonic_ms: first_delta_ms,
         terminal_monotonic_ms: terminal_ms
       })
       when is_integer(first_delta_ms) and is_integer(terminal_ms) do
    DomainMetrics.decode_throughput(
      node_id,
      model_id,
      output_tokens,
      terminal_ms - first_delta_ms
    )
  end

  defp emit_decode_throughput(_metrics), do: :ok

  defp finalize_metrics(%Metrics{conformance_defect: defect} = metrics, :ok)
       when defect != :none do
    %{metrics | outcome: :conformance_failed}
  end

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
