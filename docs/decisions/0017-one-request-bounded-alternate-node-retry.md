# Automatic inference retry is one fail-closed alternate-node attempt within the original Request

## Status

Accepted for contract shaping.

This decision records the design required by issue #121 before its OpenSpec package and does not authorize implementation while `SPEC.md` remains unreconciled.

## Context

`SPEC.md` §§5.8-5.9 and §§12.1-12.3 require at most one automatic retry before first output on a different Node when one exists.
The current Controller performs one dispatch, records only attempt 1, creates attempt-local deadline windows, and has no scheduler exclusion input.
PR #160, which closed issue #120, made missing-terminal, duplicate-terminal, and post-terminal stream failures stable non-retryable terminal classifications and preserved exactly-once Controller capacity release.

A safe retry must distinguish the logical Request from its execution attempts.
It must also define output commitment for text, tool calls, and structured output without depending on the public transport mode.
The choice is hard to reverse because it fixes execution safety, accounting, persistence, and public failure semantics across both inference APIs.

## Decision

### Output commitment

Define **Output Commitment** as the moment the Controller validates and observes the first externally meaningful Runtime Endpoint output event for the logical Request, before invoking the public event handler or serializer.
The boundary is the first non-empty `OutputTextDelta`, including JSON text used for structured output, or any valid `ToolCallDelta` because its required non-empty `tool_call_id` is already meaningful even when `delta_json` is empty.
A future dedicated structured-output event commits on its first content-bearing delta.
`Accepted`, `Progress`, `UsageUpdate`, empty text deltas, model-load events, and terminal failures do not commit output.

The commitment state is monotonic and identical for streaming and non-streaming requests on Chat Completions and Responses.
Once output commits, Orchard never retries the attempt, even if the handler, serializer, or client connection fails before the client observes a byte.
This transport-independent rule avoids races and divergent regeneration while preserving the unconditional no-retry-after-output contract.

### Retryability

Retry is fail-closed by default and requires all of these gates:

- The failed execution was attempt 1.
- Output Commitment has not occurred.
- The original Request deadline has remaining time.
- The caller has not cancelled or disconnected.
- The first Node has a stable identity that can be excluded.
- The first execution and capacity ownership are resolved.
- A different eligible Node exists.

The Controller owns the final retry decision through a closed failure taxonomy rather than string matching or an unbounded trust in runtime-provided text.
A structured Runtime Endpoint `Failed` event must both assert `retryable: true` and carry an allowlisted transient code before it can qualify.
Unknown categories and unknown codes are non-retryable.

| Failure class | Automatic attempt retry | Required treatment |
|---|---:|---|
| Pre-acceptance Node or transport unavailability | Yes | Retry only after cleanup and capacity release are affirmatively resolved. |
| Trusted candidate identity mismatch before execution | Yes | Record the mismatch and exclude the selected durable Node identity. |
| Node-local model-load `acquisition_failed`, `runtime_unavailable`, `resource_exhausted`, or `timeout` | Yes | Retry only within the original absolute deadline. |
| Deterministic model-load `model_invalid` | No | Preserve the stable terminal failure. |
| Unknown or `internal` model-load failure | No | Fail closed. |
| Worker or Node loss before `Accepted` | Yes | Retry only after the first execution is resolved under the Runtime Endpoint contract. |
| Accepted execution fails before Output Commitment and drain proves termination | Yes | Retry only for an allowlisted transient failure. |
| Accepted execution loses transport before Output Commitment but drain cannot prove termination | No | Quarantine unresolved occupancy and terminalize. |
| Runtime `Failed` before Output Commitment with allowlisted transient code and `retryable: true` | Yes | Treat both the code and flag as necessary, not individually sufficient. |
| Runtime `Failed` with `retryable: false`, deterministic code, or unknown code | No | Preserve the terminal failure. |
| `runtime_endpoint_missing_terminal`, `runtime_endpoint_duplicate_terminal`, or `runtime_endpoint_post_terminal_event` | No | Preserve PR #160's terminal-conformance classification. |
| Caller cancellation or disconnect | No | Cancellation wins at every retry boundary. |
| Original Request deadline expiry | No | Never extend or replace the deadline. |
| Controller persistence, event-handler, or orchestration failure | No | Terminalize as the existing orchestration failure. |
| Unresolved release, held claim, or quarantined execution | No | Do not acquire alternate capacity. |
| Scheduler capacity or pre-acceptance revalidation rejection | Not attempt retry | Use the existing same-lane requeue-or-fail path under the original queue deadline. |
| Admission, quota, validation, queue timeout, `cluster_busy`, or `model_busy` before an execution attempt | Out of scope | Preserve existing admission and queue semantics. |

Capacity rejection is deliberately not reclassified as automatic attempt retry.
`SPEC.md` §5.9 already requires failed serialized capacity revalidation to release and requeue or fail under the existing queue deadline, and issue #121 explicitly excludes queue re-entry.

### Capacity ownership and sequencing

Each Inference Attempt owns one Node-scoped capacity claim inside the single-attempt dispatcher.
The dispatcher must not return an attempt as eligible for retry until the allocation authority has affirmatively observed the first claim as released and any started execution is resolved.
Attempt 2 scheduling and acquisition happen strictly after that acknowledgement.

Exactly-once release means one effective authority state transition, not that defensive callers may invoke release only once.
Release remains idempotent, and the same-Request held-claim rejection remains a fail-closed backstop against overlapping attempts.
An ambiguous release result, allocation-authority restart, unresolved cancellation drain, or other occupancy uncertainty prevents attempt 2 rather than weakening the invariant.
Opaque process-local claim tokens are not persisted or transferred between attempts.
Attempt 2 follows the same single-acquire and single-effective-release contract on every terminal path.

### Original Request invariants

Automatic Attempt Retry is an internal continuation of the same logical Request, not a new Request and not a fresh admission.
Both attempts share one Request ID, body hash, idempotency scope, canonical payload, caller-visible response, admission result, queue grant, quota reservation, capture snapshot, and coarse Request FSM.
A duplicate submission observes the existing Request as in progress throughout both attempts.

The Controller must persist one absolute `requests.timeout_at` at admission and use it for the entire Request.
Every model-load and inference deadline is capped by the remaining time to that absolute deadline.
Attempt 2 receives only the remainder after attempt 1, cleanup, release, evidence persistence, and alternate scheduling.
No attempt-local timeout, model-load exclusion, or retry may add wall-clock time beyond `timeout_at`.

Input-token accounting occurs once, the output reservation remains held across attempts, and quota reconciles exactly once when the logical Request becomes terminal.
Failed attempt 1 does not release or re-reserve quota when attempt 2 will run.
Final logical usage is charged once from the terminal attempt under the existing quota policy.

The effective Payload Capture Mode resolves before the first Request write and remains unchanged for every attempt.
Attempt evidence may persist stable codes, booleans, timestamps, approved identifiers, and hashes outside `full`, while raw runtime messages, content, targets, and arguments remain governed by the snapshot.

### Attempt evidence and metrics

Use the existing append-only Request Step Event contract rather than a second Request row or a new attempt table.
Attempt steps use `inference_turn:t1:a1` and `inference_turn:t1:a2` with `attempt = 1` and `attempt = 2`.
Attempt 1's terminal step must be durable before attempt 2's started step is appended.
The coarse Request becomes terminal exactly once after the final attempt or after the retry decision declines attempt 2.

Each attempt records its attempt number, stable Node identifier and capture-safe target reference, start and end timestamps, acceptance state, Output Commitment state and kind, stable failure class and code, runtime retryability flag when present, Controller retry decision and reason, capacity release outcome, exclusion reason, and attempt outcome.
The closed `retry_decision` vocabulary is `retried`, `not_retryable`, `output_committed`, `cancelled`, `budget_exhausted`, `occupancy_unresolved`, and `no_alternative_node`.
Attempt 2 additionally records the first Node as excluded.
Raw failure text remains capture-gated.

Logical metrics count admission, queue outcome, quota, tokens, public success or failure, and Request duration exactly once per Request.
Attempt metrics count each dispatch, duration, Node outcome, model-load outcome, failure class, commitment state, time to first output, and retry result per attempt.
Add `orchard_inference_attempts_total{attempt,outcome,failure_class}`, `orchard_inference_attempt_duration_seconds_bucket{attempt,outcome}`, and `orchard_inference_retries_total{reason,result}` where every label has a closed vocabulary and `result` is `success`, `failed`, or `no_alternative_node`.
The retry counter is finalized with the logical Request so its result is counted once rather than once at decision time and again at terminal time.
Metric labels must never contain Request IDs, claim tokens, target addresses, raw error codes outside the closed taxonomy, or other unbounded identifiers.
Traces and durable events carry high-cardinality correlation.
This follows the call-versus-attempt distinction in the OpenTelemetry gRPC semantic conventions.

### Different-Node exclusion and no alternative

Attempt 2 performs a fresh scheduler decision with `exclude_node_ids` containing attempt 1's stable Node identity.
Exclusion is a hard eligibility filter applied before tiering, ranking, and scoring, not a score penalty.
A different target address for the same Node does not satisfy the rule, and an unresolved identity cannot prove that a candidate is different.
The orchestrator checks the selected Node again before dispatch as defense in depth.
Newly eligible Nodes may participate in the fresh decision if they satisfy every current admission, lifecycle, health, placement, routing, and capacity rule.

If no different eligible Node exists, Orchard starts no second attempt, does not re-enter the queue, and does not extend any budget.
The logical Request terminalizes using attempt 1's original stable public failure mapping.
`no_alternative_node` is durable internal retry-decision evidence, not a new public error code.

## Rejected alternatives

Using the first public SSE byte or non-streaming response byte as commitment is rejected because it creates transport-specific behavior and races between validated model output and client delivery.
Treating only text as commitment is rejected because tool-call identity and structured-output deltas are externally meaningful output.
Retrying every runtime event marked `retryable: true` is rejected because unknown or compromised classifications must fail closed.
Retrying PR #160's terminal-conformance failures is rejected because those classifications deliberately report a defective stream contract rather than a safe transient execution outcome.
Holding or transferring the first claim while acquiring alternate capacity is rejected because it permits overlapping logical ownership and can double-count capacity.
Persisting opaque claim tokens is rejected because they are process-local synchronization details rather than durable domain identity.
Re-admitting or requeueing the Request is rejected because it can reorder work, double-charge quota, widen policy, and extend budgets.
Making prior-Node exclusion a score penalty is rejected because the scheduler could still select the same physical Node.
Returning a new public no-alternative error is rejected because the original failure remains the cause of the logical Request failure.

## Consequences

The dispatcher remains a single-target, single-attempt primitive, while the orchestrator owns the bounded retry loop and durable attempt ordering.
The scheduler needs a hard Node-exclusion input, and the capacity authority must expose an unambiguous release outcome before alternate acquisition.
The Request FSM, public APIs, idempotency contract, quota model, and capture policy remain logical-Request scoped.
Availability is intentionally sacrificed whenever output, execution termination, identity, or capacity release is ambiguous.

Implementation tests must cover every retryability row, both APIs in streaming and non-streaming modes, text/tool/structured commitment, deadline and cancellation races, release-before-acquire ordering, same-Node defense, no alternative, idempotency during attempt 2, one quota settlement, capture non-widening, Request Step Event ordering, and logical-versus-attempt metric counts.

## SPEC.md impact

The required OpenSpec package must reconcile `SPEC.md` before implementation.
It must replace ambiguous "first token" wording in §§5.8-5.9, §§12.1-12.3, §12.7, and M4 acceptance with the Output Commitment boundary while preserving the prohibition on retry after meaningful output.
It must bound §5.8's apparent candidate loop to two execution attempts and make attempt 2 a fresh schedule with hard prior-Node exclusion.
It must clarify that `timeout_at` is the absolute logical deadline and that model-load handling cannot extend it.
It must clarify that quota reservation release on pre-output failure occurs only when the logical Request terminalizes, not between attempts.
It must preserve §4.6.2 quarantine for unresolved accepted execution and PR #160's non-retryable terminal-conformance classes.

Until those deltas are approved and synchronized, `SPEC.md` remains authoritative and implementation is blocked on any conflict.

## External design grounding

The [gRPC retry guide](https://grpc.io/docs/guides/retry/) distinguishes a logical call from its individual attempts and stops retry after the RPC is committed.
The [gRPC deadline guide](https://grpc.io/docs/guides/deadlines/) defines one deadline point and describes propagation using the remaining budget.
The [Google Cloud retry strategy](https://docs.cloud.google.com/storage/docs/retry-strategy) requires both a transient condition and idempotent safety, bounds retries by total timeout, and warns against layered retries.
Envoy's [previous-hosts retry predicate](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_connection_management.html) provides precedent for excluding previously attempted hosts during a fresh selection.
The [OpenTelemetry gRPC compatibility guidance](https://opentelemetry.io/docs/specs/semconv/non-normative/compatibility/grpc/) distinguishes logical call metrics from attempt metrics.
The expired [IETF Idempotency-Key Internet-Draft](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header) remains useful non-normative background for binding one key to one request fingerprint, but it is not a current standard.
