# Automatic inference retry is one fail-closed alternate-node attempt within the original Request

## Status

Accepted.

Issue #164 reconciles this decision into `SPEC.md` and the Automatic Attempt Retry OpenSpec package.
Implementation remains scoped to the blocker-linked tickets under parent objective #121.

### Amendment 2026-09-11

Issue #403 adds one narrow attempt 2 exception to the retry contract. A
Controller-detected negotiated acceptance-proof failure under `SPEC.md` §7.5.3a
records `not_retryable` on an unsuccessful attempt 2 that terminalizes as a
failure with no committed output. Caller cancellation or disconnect still
records `cancelled`, and an already-proven deadline terminalization still
records `retry_exhausted`, so cancellation is no longer the sole attempt 2
exception.

`SPEC.md` §§3.7.1, 5.8, and 7.5.3a now own that rule and override the three
statements below that make `cancelled` the only attempt 2 exception: the
capacity-rejection discussion in "Retryability", the attempt 2 sentence in
"Attempt evidence and metrics", and the breaker-interaction sentence in
"Circuit breaker interaction". Those sections stay as authored to record the
state that motivated this decision. Every other part of this decision, including
the closed `retry_decision` vocabulary and the attempt 1 decline precedence,
stands unchanged.

## Context

`SPEC.md` §§5.8-5.9 and §§12.1-12.3 require at most one automatic retry before Output Commitment on a different Node when one exists.
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
When commitment occurs, Orchard delivers all earlier buffered validated events in original order before exposing the committing event downstream.
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
A structured inference Runtime Endpoint `Failed` event must both assert `retryable: true` and carry one of `node_unavailable`, `node_timeout`, `runtime_unavailable`, `resource_exhausted`, `timeout`, `worker_unavailable`, or `worker_down` before it can qualify.
A model-load failure qualifies only through its normalized category of `acquisition_failed`, `runtime_unavailable`, `resource_exhausted`, or `timeout`; its failure code or message cannot independently authorize retry.
Unknown categories and unknown codes are non-retryable.

| Failure class | Automatic attempt retry | Required treatment |
|---|---:|---|
| Pre-acceptance Node or transport unavailability | Yes | Retry only after cleanup and capacity release are affirmatively resolved. |
| Node-local model-load `acquisition_failed`, `runtime_unavailable`, `resource_exhausted`, or `timeout` | Yes | Retry only within the original absolute deadline. |
| Deterministic model-load `model_invalid` | No | Preserve the stable terminal failure. |
| Unknown or `internal` model-load failure | No | Fail closed. |
| Worker or Node loss before `Accepted` | Yes | Retry only after the first execution is resolved under the Runtime Endpoint contract. |
| Accepted execution fails before Output Commitment and drain proves termination | Yes | Retry only for an allowlisted transient failure. |
| Accepted execution loses transport before Output Commitment but drain cannot prove termination | No | Quarantine unresolved occupancy and terminalize. |
| Runtime `Failed` before Output Commitment with allowlisted transient code and `retryable: true` | Yes | Treat both the code and flag as necessary, not individually sufficient. |
| Runtime `Failed` with `retryable: false`, deterministic code, or unknown code | No | Preserve the terminal failure. |
| `runtime_endpoint_missing_terminal`, `runtime_endpoint_duplicate_terminal`, or `runtime_endpoint_post_terminal_event` | No | Preserve PR #160's terminal-conformance classification. |
| Caller cancellation or disconnect, including `dispatch_capacity_caller_down` | No | Cancellation wins at every retry boundary and records `cancelled`. |
| Original Request deadline expiry | No | Never extend or replace the deadline. |
| Controller persistence, event-handler, or orchestration failure | No | Terminalize as the existing orchestration failure. |
| Unresolved capacity release, quarantined execution, or `dispatch_capacity_quarantine_store_unavailable` | No | On attempt 1, do not acquire alternate capacity and record `occupancy_unresolved`; attempt 2 records `retry_exhausted` while preserving the failure class. |
| Held claim for the same Request reported as `dispatch_capacity_request_already_claimed` | No | On attempt 1, fail closed and record `occupancy_unresolved`; attempt 2 records `retry_exhausted` while preserving the failure class. |
| Candidate identity mismatch or unverified candidate identity reported as `dispatch_capacity_node_identity_mismatch` | No | On attempt 1, fail closed and record `identity_unresolved`; attempt 2 records `retry_exhausted` while preserving the failure class. |
| Scheduler capacity rejection before `request_step.started` | Not attempt retry | Use the existing same-lane requeue-or-fail path under the original queue deadline and record no attempt retry decision. |
| Every other dispatch-capacity acquisition, acceptance-gate, or revalidation rejection after `request_step.started`, including `dispatch_capacity_unavailable`, `dispatch_capacity_facts_unavailable`, `dispatch_capacity_acceptance_gate_busy`, `dispatch_capacity_authority_unavailable`, and `dispatch_capacity_revalidation_failed` | No | On attempt 1 record `not_retryable`; on attempt 2 record `retry_exhausted`; preserve the specific failure class, release capacity effectively, and terminalize without queue re-entry. |
| Admission, quota, validation, queue timeout, `cluster_busy`, or `model_busy` before `request_step.started` | Out of scope | Preserve existing admission and queue semantics with no attempt retry decision and no attempt or retry metric sample. |

Capacity rejection is deliberately not reclassified as Automatic Attempt Retry.
Scheduler capacity, admission, quota, validation, and queue-timeout outcomes resolve before `request_step.started` exists, so they stay outside attempt accounting entirely and produce no attempt retry decision and no attempt or retry metric sample.
Ordinary dispatch-capacity scarcity resolves after that step exists, so each of those rejections records `not_retryable` on a durable attempt 1 terminal step, releases its capacity claim effectively, and terminalizes through the Controller's existing failure path.
Issue #121 excludes queue re-entry and bounds a Request to two attempts, so a dispatch-capacity rejection after `request_step.started` does not requeue into the same lane and this decision makes no claim that it does.
Any future post-start capacity requeue is separate contract work that must first define a unique attempt identity, its durable step persistence, and its retry metric accounting, because the two-attempt vocabulary here has no identity for a third dispatch of the same logical Request.
`dispatch_capacity_caller_down`, `dispatch_capacity_request_already_claimed`, `dispatch_capacity_node_identity_mismatch`, and `dispatch_capacity_quarantine_store_unavailable` are excluded from that ordinary scarcity family and keep their own rows.
`dispatch_capacity_caller_down` is a caller disconnect that the dispatcher already maps to `caller_disconnect`, so it follows the cancellation row, records `cancelled`, and keeps cancellation ahead of every capacity classification.
On attempt 1, a held claim, a mismatched or unverified candidate identity, and an unresolved quarantine store fail their named retryability gate and record `occupancy_unresolved`, `identity_unresolved`, and `occupancy_unresolved` respectively.
On attempt 2, those same failure details remain in the failure class and code while the retry decision records `retry_exhausted`; caller cancellation remains the sole `cancelled` exception.
Issue #164 settles the caller-disconnect axes consistently across every dispatch phase: Request state `cancelled`, `request_step.cancelled` after attempt start, durable code `request_caller_disconnect`, retry decision `cancelled`, HTTP `499` when a response remains deliverable, and public code `request_cancelled`.
Controller or process failure without caller cancellation remains the sole owner of Request state `interrupted`.
This classification is normative for the retry contract; the blocker-linked implementation tickets own the product-code reconciliation.

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
The orchestrator owns exactly one started event per attempt, and the dispatcher consumes that existing attempt context without appending another.
After alternate scheduling and the final post-scheduling caller and deadline gate, attempt 1's terminal step with `retried` and attempt 2's started step must append atomically.
Caller liveness and the absolute deadline are checked again after that transaction and immediately before any attempt 2 dispatch side effect; failure terminalizes the already-started attempt 2 without dispatch or a third attempt.
The coarse Request becomes terminal exactly once after the final attempt or after the retry decision declines attempt 2.

Each attempt records its attempt number, stable Node identifier and capture-safe target reference, start and end timestamps, acceptance state, Output Commitment state and kind, stable failure class and code, runtime retryability flag when present, Controller retry decision and reason, execution resolution, capacity release outcome, exclusion reason, and attempt outcome.
The closed execution-resolution vocabulary is `not_started`, `terminated`, and `unresolved`, and durable failure codes bind to the existing stable `requests.error_code` vocabulary rather than runtime-provided free text.
The Controller retains allowlisted stable inference codes, maps model-load categories to Controller-owned defaults, maps cancellation and deadline outcomes to their stable Request codes, preserves the existing stable public capacity mapping for ordinary scarcity, and normalizes terminal-conformance, unresolved, unknown, or untrusted source codes to the existing Controller-owned internal or orchestration failure code.
A raw source code may persist separately only under `full` and never controls retry, public mapping, or metric labels.
The Controller evaluates a retry decision on every unsuccessful attempt terminal step that reaches a retry boundary, meaning `request_step.failed`, `request_step.cancelled`, `request_step.timed_out`, or `request_step.interrupted`.
A successful attempt terminalizes as `request_step.completed` and records no retry decision because no retry evaluation occurs.
The closed `retry_decision` vocabulary is `retried`, `not_retryable`, `output_committed`, `cancelled`, `budget_exhausted`, `identity_unresolved`, `occupancy_unresolved`, `no_alternative_node`, and `retry_exhausted`.
An unsuccessful attempt 1 records `retried` when attempt 2 starts and otherwise records exactly one of the seven decline values.
Each decline value covers one gate, where `output_committed`, `cancelled`, `budget_exhausted`, `identity_unresolved`, `occupancy_unresolved`, and `no_alternative_node` map to the retryability gates in their listed order and `not_retryable` covers the closed failure taxonomy check.
`identity_unresolved` records that attempt 1's durable Node identity could not be established for hard exclusion, and that state must never be recorded as `no_alternative_node` because an eligible alternative may well have existed.
Every dispatch-capacity acquisition, acceptance-gate, and revalidation rejection reaches an unsuccessful attempt terminal step rather than being treated as a Request that never made an attempt.
On attempt 1, ordinary scarcity records `not_retryable`, a held claim or an unresolved quarantine store records `occupancy_unresolved`, and a mismatched or unverified candidate identity records `identity_unresolved`.
On either attempt, `dispatch_capacity_caller_down` records `cancelled`; every other unsuccessful attempt 2 capacity outcome records `retry_exhausted` while preserving its specific failure class and code.
A `retry_decision` value fixes the retry outcome alone, so it never by itself determines which terminal step event type the attempt uses or which public error the caller sees.
When several gates fail together, the recorded decline value follows the gate order with the taxonomy check evaluated after budget exhaustion, giving `output_committed`, `cancelled`, `budget_exhausted`, `not_retryable`, `identity_unresolved`, `occupancy_unresolved`, then `no_alternative_node`.
That precedence selects only which evidence value is stored because every decline value is equally terminal for retry.
An unsuccessful attempt 2 records `retry_exhausted` because the two-attempt bound makes further retry structurally impossible, except that caller cancellation or disconnect records `cancelled` so cancellation remains consistent across every dispatch phase.
`retry_exhausted` is reserved to attempt 2 and never appears on an attempt 1 step, while `cancelled` may appear on either started attempt.
Attempt 2 additionally records the first Node as excluded.
Raw failure text remains capture-gated.

Logical metrics count admission, queue outcome, quota, tokens, public success or failure, and Request duration exactly once per Request.
Attempt metrics count every started attempt, including an attempt that terminalizes at a post-start gate before dispatch, and record duration, Node outcome, model-load outcome, failure class, commitment state, time to first output, and retry result per attempt.
Add `orchard_inference_attempts_total{attempt,outcome,failure_class}`, `orchard_inference_attempt_duration_seconds_bucket{attempt,outcome}`, and `orchard_inference_retries_total{reason,result}` where every label has a closed vocabulary.
The attempt counter uses metric-only `failure_class = "none"` for completed attempts and the closed durable failure-class vocabulary for non-completed attempts.
`orchard_inference_retries_total` emits exactly one sample for each logical Request whose attempt 1 recorded a `retry_decision`.
A Request that succeeded on attempt 1 or terminalized before `request_step.started` was appended records no attempt 1 retry decision and therefore emits no sample.
Scheduler-busy requeue outcomes such as `cluster_busy` and `model_busy` resolve before `request_step.started` exists, so they emit neither a retry decision nor a retry metric sample.
Each dispatch-capacity acquisition, acceptance-gate, and revalidation rejection resolves after that step exists, so it emits exactly one sample with `result` of `declined` and a `reason` of `not_retryable`, `cancelled`, `occupancy_unresolved`, or `identity_unresolved` matching its durable attempt 1 decision.
Its `reason` label is the durable attempt 1 `retry_decision` value, so the closed `reason` vocabulary is `retried`, `not_retryable`, `output_committed`, `cancelled`, `budget_exhausted`, `identity_unresolved`, `occupancy_unresolved`, and `no_alternative_node`.
`retry_exhausted` never labels this counter because the counter reports the single attempt 1 decision rather than attempt 2's terminal state.
Its closed `result` vocabulary is `succeeded`, `failed`, and `declined`, where `succeeded` and `failed` report attempt 2's terminal outcome for the logical Request and `declined` reports that no attempt 2 started.
`reason` is `retried` exactly when `result` is `succeeded` or `failed`, and each of the seven decline reasons pairs only with `declined`, which bounds the counter to nine valid label combinations.
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

### Circuit breaker interaction

Each attempt that actually ran and failed contributes independently to the existing §5.10 Node-level or placement-level breaker, but only when its stable failure class is already breaker-eligible under that section.
A Request that fails both attempts therefore contributes two breaker events rather than one, because each attempt is a real dispatch or a real model load against a real target.
Every event is attributed to the Node or the `(node, model)` placement that produced it, so attempt 1's failure never counts against attempt 2's target and attempt 2's failure never counts against attempt 1's.
The Automatic Attempt Retry decision itself is Controller-internal accounting and must not increment any breaker.
Attempt 2 records `retry_exhausted` for every unsuccessful non-cancellation outcome and `cancelled` for caller cancellation; neither retry decision adds a breaker event beyond the attempt failure that already qualified on its own.

Attempt 2 performs its fresh eligibility decision after attempt 1's stable failure classification and breaker effects are durable, so it must respect any Node or placement suppression that attempt 1 caused.
Caller liveness and the absolute deadline are rechecked after that decision and before persisting either `retried` or `no_alternative_node`, so cancellation and budget exhaustion retain precedence.
Attempt 1 terminal evidence is appended only after that gate passes and the decision determines `retried` versus `no_alternative_node`.
Breaker suppression is already part of the §5.5 eligibility filter, so a suppressed Node is not a different eligible Node for this decision.
Attempt 1's own breaker events land on attempt 1's Node and placement, which hard exclusion removes from attempt 2's candidate set anyway, so this ordering rule protects the correctness of shared breaker state and Operator-visible suppression rather than widening or narrowing attempt 2's candidates.

If breaker filtering leaves no different eligible Node and the post-scheduling caller and deadline gate passes, the Request takes the existing `no_alternative_node` outcome.
That outcome never weakens hard exclusion, re-enters the queue, or extends the deadline in order to wait out a suppression window.

This decision defines interaction only.
It does not redefine §5.10 thresholds, windows, or suppression durations, does not add a retry-specific breaker class, and does not change the Operator clear path.

## Rejected alternatives

Using the first public SSE byte or non-streaming response byte as commitment is rejected because it creates transport-specific behavior and races between validated model output and client delivery.
Treating only text as commitment is rejected because tool-call identity and structured-output deltas are externally meaningful output.
Retrying every runtime event marked `retryable: true` is rejected because unknown or compromised classifications must fail closed.
Retrying PR #160's terminal-conformance failures is rejected because those classifications deliberately report a defective stream contract rather than a safe transient execution outcome.
Holding or transferring the first claim while acquiring alternate capacity is rejected because it permits overlapping logical ownership and can double-count capacity.
Persisting opaque claim tokens is rejected because they are process-local synchronization details rather than durable domain identity.
Re-admitting or requeueing the Request after `request_step.started` is rejected because it can reorder work, double-charge quota, widen policy, extend budgets, and produce a dispatch with no defined attempt identity, while the existing pre-start scheduler-busy requeue stays untouched by this decision.
Making prior-Node exclusion a score penalty is rejected because the scheduler could still select the same physical Node.
Counting a retried Request as one breaker event across both attempts is rejected because it would hide half of the real failure evidence from §5.10 and let a failing Node stay eligible longer than its actual failure rate warrants.
Returning a new public no-alternative error is rejected because the original failure remains the cause of the logical Request failure.

## Consequences

The dispatcher remains a single-target, single-attempt primitive, while the orchestrator owns the bounded retry loop and durable attempt ordering.
The scheduler needs a hard Node-exclusion input, and the capacity authority must expose an unambiguous release outcome before alternate acquisition.
The Request FSM, public APIs, idempotency contract, quota model, and capture policy remain logical-Request scoped.
Availability is intentionally sacrificed whenever output, execution termination, identity, or capacity release is ambiguous.

Implementation tests must cover every retryability row, both APIs in streaming and non-streaming modes, text/tool/structured commitment, deadline and cancellation races, release-before-acquire ordering, same-Node defense, no alternative, idempotency during attempt 2, one quota settlement, capture non-widening, Request Step Event ordering, per-attempt breaker attribution, and logical-versus-attempt metric counts.

## SPEC.md impact

Issue #164 reconciles this decision through the Automatic Attempt Retry OpenSpec package and these `SPEC.md` changes:

- replace ambiguous first-output wording in §5.3, §§5.8-5.9, §§12.1-12.3, §12.7, and M4 acceptance with the Output Commitment boundary while preserving the prohibition on retry after meaningful output
- bound §5.8 to two execution attempts and make attempt 2 a fresh schedule with hard prior-Node exclusion
- define `timeout_at` as the absolute logical deadline that model loading cannot extend
- retain the quota reservation between attempts and release it only when the logical Request terminalizes
- prohibit queue re-entry for every capacity rejection after `request_step.started`
- settle caller disconnect as one cancelled terminal mapping across dispatch phases
- preserve §4.6.2 quarantine for unresolved accepted execution and PR #160's non-retryable terminal-conformance classes
- preserve §5.10 breaker policy while attributing each eligible failed attempt independently and excluding the retry decision itself

`SPEC.md` remains authoritative, and implementation proceeds only through the blocker-linked tickets under parent objective #121.

## External design grounding

The [gRPC retry guide](https://grpc.io/docs/guides/retry/) distinguishes a logical call from its individual attempts and stops retry after the RPC is committed.
The [gRPC deadline guide](https://grpc.io/docs/guides/deadlines/) defines one deadline point and describes propagation using the remaining budget.
The [Google Cloud retry strategy](https://docs.cloud.google.com/storage/docs/retry-strategy) requires both a transient condition and idempotent safety, bounds retries by total timeout, and warns against layered retries.
Envoy's [previous-hosts retry predicate](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_connection_management.html) provides precedent for excluding previously attempted hosts during a fresh selection.
The [OpenTelemetry gRPC compatibility guidance](https://opentelemetry.io/docs/specs/semconv/non-normative/compatibility/grpc/) distinguishes logical call metrics from attempt metrics.
The expired [IETF Idempotency-Key Internet-Draft](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header) remains useful non-normative background for binding one key to one request fingerprint, but it is not a current standard.
