# Design: automatic attempt retry

## Context

The current Controller owns one logical Request but dispatches only one execution attempt.
`docs/decisions/0019-one-request-bounded-alternate-node-retry.md` fixes the contract for a single second attempt before Output Commitment.
The implementation must add that behavior without repeating admission or weakening capacity, deadline, quota, idempotency, capture, and public API invariants.

## Goals

- Represent attempt-local state explicitly while keeping Request state coarse and free of a retry-specific FSM state.
- Preserve the dispatcher as the single-attempt execution and cleanup boundary.
- Make retry decisions deterministic, closed, durable, and testable.
- Prevent discarded attempt output from contaminating either public API.
- Make alternate scheduling impossible while execution, identity, or capacity ownership is ambiguous.

## Decisions

### The orchestrator owns a fixed two-attempt flow

`Orchard.Inference.RequestOrchestrator` owns attempt numbering, retry gates, alternate scheduling, durable attempt ordering, and logical Request terminalization.
It may run attempt 1 and, only after every gate passes, attempt 2.
Admission, queue admission, quota reservation, idempotency resolution, Payload Capture Mode, and Request creation occur once.
The dispatcher remains single-target and single-attempt.

### One absolute deadline owns all work

`requests.timeout_at` is assigned once when the Request row is created.
Queueing, scheduling, model loading, execution, cleanup, evidence persistence, and alternate scheduling consume the remaining time.
The dispatcher never adds model-load duration back to the budget.
A non-positive remaining budget prevents a new scheduler or dispatch side effect.

### Output Commitment is transport-independent

Output Commitment occurs when the Controller validates and observes the first non-empty text delta, any valid tool-call delta with a stable non-empty tool-call identity, or a future content-bearing structured-output delta.
Commitment is recorded before the public event handler or serializer is called.
Accepted, progress, usage, model-load, empty text, and terminal events do not commit output.
Commitment is monotonic and identical for streaming and non-streaming Chat Completions and Responses.
`first_token_at` remains text-specific.

Validated events from a pre-commit attempt remain attempt-local until the retry decision is known.
When output commits, buffered events are delivered in original order before the committing event is exposed downstream.
When retry starts, attempt 1 buffered events are discarded.
When retry is declined or an attempt completes without meaningful output, the final attempt's buffered events are delivered in original order.
A handler or serializer failure after commitment is non-retryable.

### Dispatcher outcomes are typed

The dispatcher returns attempt-local evidence rather than a bare event list or opaque error.
The result carries Node identity, acceptance, Output Commitment, stable failure classification, execution resolution, capacity release outcome, buffered events, and timing.
This result is internal and capture-safe data is selected separately for persistence.

A representative attempt context is:

```text
attempt
started_at
excluded_node_ids
schedule
node_id
accepted
output_commitment
failure
execution_resolution
capacity_release_outcome
```

### Retry classification is closed and fail-closed

A pure attempt-failure classifier composes the existing model-load and public error mappings.
It does not duplicate public messages.
A runtime failure is retry-capable only when both its `retryable` flag is true and its stable code is allowlisted.
Unknown or deterministic failures are non-retryable.
Terminal-conformance, persistence, handler, serializer, and orchestration failures are non-retryable.

Attempt 1 decline precedence is:

1. `output_committed`
2. `budget_exhausted`
3. `cancelled`
4. `not_retryable`
5. `identity_unresolved`
6. `occupancy_unresolved`
7. `no_alternative_node`

Attempt 2 cannot retry and records `retry_exhausted` when unsuccessful, except that caller cancellation or disconnect records `cancelled`.
Cancellation and the absolute deadline are rechecked after attempt failure, before alternate scheduling, immediately before durable attempt-2 start, and again before attempt-2 dispatch.

### Capacity release is observable

Allocation release remains idempotent but reports `released`, `already_released`, `not_applicable`, or `unresolved`.
An authority exit or ambiguous cleanup never becomes synthetic success.
Alternate scheduling and acquisition require resolved execution plus an affirmative release result.
The existing same-Request held-claim rejection and quarantine behavior remain fail-closed defenses.
Opaque claim tokens remain process-local.

### Prior-Node exclusion is hard

Attempt 2 schedules fresh with `exclude_node_ids` containing attempt 1's durable Node identity.
The scheduler filters that identity before tiering, ranking, scoring, and prefix-cache scoring, and reports the removed candidate with the `SPEC.md` §7.3.5 rejection reason code `previous_attempt_node_excluded`.
A different address for the same Node does not satisfy the rule.
The orchestrator rechecks the returned Node identity before dispatch.
Unresolved or conflicting identity records `identity_unresolved`.
No alternative preserves attempt 1's original public failure and does not re-enter the queue.

Alternate scheduling reuses the existing per-logical-Request budgets rather than doubling them.
The §7.5.3 `ScorePrefixCache` caps stay per Request, so attempt 2 scores only within their unconsumed remainder and otherwise falls back to deterministic base order.
The §5.5 explicitly unmanaged compatibility branch keeps its single status-probe wave per logical Request, so an attempt 1 on that branch never produces an attempt 2 and records `no_alternative_node` instead.

### Attempt evidence remains append-only

Attempt evidence remains in `request_events` through `request_step.*` rows.
No attempt table is introduced.
Attempt 1 terminal evidence precedes attempt 2 started evidence.
The Request terminalizes once after the final attempt or a declined retry.
Existing rows without enriched attempt fields remain readable.
New enriched terminal attempt shapes use closed validation.

### Caller disconnect is cancellation

Caller disconnect maps to Request state `cancelled` across pre-dispatch, capacity-gate, and runtime-drain phases.
After an attempt starts it uses `request_step.cancelled`, durable code `request_caller_disconnect`, and retry decision `cancelled`.
When a response remains deliverable it uses HTTP `499`, public code `request_cancelled`, and the stable cancellation message.
Controller or process failure without caller cancellation remains `interrupted`.

### Breakers and metrics use separate boundaries

Each actual breaker-eligible failed attempt contributes to the existing breaker for the Node or placement that produced it.
`SPEC.md` §5.10 fixes eligibility over the closed failure-class vocabulary: `pre_acceptance_unavailable` and `worker_or_node_loss` for the Node-level breaker, `model_load_failure` for the placement-level breaker, and nothing else.
Ordinary post-start capacity scarcity is `capacity_rejection` and never suppresses a healthy but busy Node.
Attempt 1 breaker effects are durable before alternate scheduling.
The retry decision adds no breaker event.

Logical Request metrics emit once per Request.
Attempt metrics emit once per started attempt.
The retry counter emits once when the logical Request terminalizes and uses only the closed label combinations in the spec delta.
High-cardinality identifiers never appear in metric labels.

## Failure ordering

Before attempt 2 dispatch, Orchard must complete this sequence:

1. Normalize and freeze the stable attempt 1 failure classification in the typed dispatcher outcome.
2. Resolve execution or observe a valid terminal outcome.
3. Confirm an affirmative capacity release.
4. Durably apply any breaker-eligible effect to attempt 1's Node or placement.
5. Recheck caller liveness and the absolute deadline before alternate scheduling.
6. If that gate fails, terminalize attempt 1 with `cancelled` or `budget_exhausted` and perform no alternate scheduler side effect.
7. Run a side-effect-free fresh scheduler decision excluding attempt 1's Node and respecting the new breaker state.
8. Recheck caller liveness and the absolute deadline before persisting either scheduler result.
9. If that gate fails, terminalize attempt 1 with `cancelled` or `budget_exhausted` and append no attempt 2 evidence.
10. If no candidate exists, append attempt 1 terminal evidence with `no_alternative_node` and terminalize the Request.
11. If a valid different candidate exists, atomically append attempt 1 terminal evidence with `retried` and the sole attempt 2 started event, and take the bounded `running -> dispatching` edge here when attempt 1 had reached `running`.
12. Recheck caller liveness and the absolute deadline immediately before a dispatch side effect.
13. If the post-start gate fails, terminalize attempt 2 as `cancelled` for caller cancellation or as `timed_out` with `retry_exhausted` for deadline exhaustion, without dispatch or a third attempt.
14. Begin attempt 2 dispatch using the existing started attempt context.

Failure to atomically append attempt 1 terminal and attempt 2 started evidence prevents dispatch and terminalizes through the existing orchestration persistence failure.
The dispatcher never appends a second attempt 2 started event.

## Rejected alternatives

A retry loop inside the dispatcher is rejected because it would mix single-target capacity ownership with logical Request orchestration.
A new attempt table is rejected because append-only request-step evidence already owns the durable seam.
Public-byte delivery as the commitment boundary is rejected because it is transport-specific and race-prone.
Same-Node retry and score-penalty exclusion are rejected because neither proves a different physical Node.
Queue re-entry after attempt start is rejected because it widens ordering, admission, deadline, and attempt-identity semantics.
Persisted claim tokens are rejected because they are process-local synchronization details.
A retry-specific breaker is rejected because existing Node and placement breakers own actual execution failures.

## Migration and compatibility

No database migration is required because `requests.timeout_at` and JSON request-event results already exist.
Existing request-step rows remain readable.
Deployment and rollback should drain active Requests because older code does not orchestrate attempt 2.
Public API endpoint and response shapes remain unchanged.
