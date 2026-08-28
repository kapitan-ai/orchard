# Design: Node and placement circuit-breaker foundation

## Context

The scheduler already has stable reason codes and dispatch-capacity evaluation accepts breaker-related input, while Node transport handling already updates health.
Those adjacent seams do not establish durable breaker identity, counting, concurrency, recovery, or Operator control.
This design adds one Postgres authority without coupling breaker state to lifecycle or health.

## Goals

- Make one actual eligible failure contribute at most once to exactly one canonical breaker.
- Make threshold, expiry, and clear decisions deterministic under concurrency and Controller replacement.
- Keep scheduler behavior explainable and fail closed without inventing false breaker state.
- Preserve the exact `SPEC.md` §5.10 policy and the boundary with future retry attribution.

## Decisions

### Postgres owns identity, time, and serialization

Node breakers use canonical `node_id` identity.
Placement breakers use canonical `(node_id, model_id)` identity, where `model_id` is the durable catalog identity rather than a runtime alias or target address.
The Node identity retains a restrictive foreign key because Node removal is a lifecycle state rather than row deletion.
The stored model UUID is validated against the catalog when a placement breaker is first addressed but intentionally has no database foreign key to `models.id`.
Catalog retirement may delete a model row, and breaker history must survive that deletion.
Re-import creates a new model UUID and therefore cannot inherit suppression from the retired placement.
Unresolved or conflicting identity refuses recording and scheduling authority rather than guessing a target.

Breaker state and its contribution rows live in Postgres.
Recording or clearing locks the canonical breaker row in a transaction, assigns a database-authoritative `decision_time`, and persists the contribution, transition, and audit evidence atomically.
The state row retains breaker kind, canonical target identity, generation, state, suppression deadline, last transition time, and clear watermark.
Each contribution retains its globally idempotent failure identity, breaker identity, generation, closed failure class, source `occurred_at` evidence, database decision time, and resulting transition.
No request content, target credential, prompt, response, or raw diagnostic belongs in either record.

### Rolling windows use a half-open lower boundary

For a decision at database time `decision_time`, eligible contributions are those in `(decision_time - window, decision_time]` in the current generation.
The contribution decision time is assigned by the database when the failure is first accepted.
`occurred_at` remains evidence about the source failure and does not let a delayed or caller-clock timestamp move a contribution into the authoritative rolling window.

The Node breaker opens on the third accepted `pre_acceptance_unavailable` or `worker_or_node_loss` contribution in 60 seconds and sets `suppressed_until` to five minutes after the opening decision time.
The placement breaker opens on the third accepted `model_load_failure` contribution for one canonical placement in 10 minutes and sets `suppressed_until` to 15 minutes after the opening decision time.
An unsuccessful outcome contributes to at most one breaker.
Ineligible classes are durably rejected from contribution and cannot affect the state.

Duplicate delivery is identified by the failure identity before counting.
Re-recording it returns the already-recorded result and neither increments the window nor extends suppression.
Concurrent first deliveries serialize on the breaker row, so exactly one transaction observes and persists the threshold crossing.

### Expiry is evaluated at each authoritative decision

Suppression is active only while `decision_time < suppressed_until`.
At `decision_time >= suppressed_until`, the state deterministically evaluates as expired before the current read or recording decision.
Expiry does not bypass lifecycle, health, trust, policy, memory, placement, or capacity gates.
An expired breaker does not require process-local timers or cache hydration, so restart and Active/Standby changes read the same result from Postgres.

Accepted failures while a breaker is open may remain evidence, but they do not extend `suppressed_until` or create another opening transition.
The configured suppression duration always begins at the threshold-crossing transition.

### Clear starts a fenced generation

An explicit clear locks the breaker row, increments its generation, records the database clear decision time as the clear watermark, removes active suppression, and appends audit evidence in one transaction.
Repeated clear of the already-cleared generation is an idempotent no-op with a stable result and no lifecycle or health mutation.

Contributions are tagged with the current generation.
A delayed delivery whose durable source `occurred_at` is at or before the clear watermark is recorded as fenced evidence and cannot contribute in the new generation.
This generation and watermark fence prevents a failure produced before clear from reopening the breaker merely because delivery happened later.
A failure occurring after the watermark may contribute once in the new generation using its database acceptance time for the rolling window.

### Scheduler reads one durable breaker view

Candidate construction and final dispatch revalidation read breaker facts from the same request-scoped Postgres decision context used for authoritative scheduler inputs, or an equivalent transactionally coherent read.
No caller-supplied default can claim breaker eligibility.

An active Node breaker removes that Node before tiering, ranking, scoring, prefix-cache scoring, or dispatch and explains the rejection with `node_circuit_breaker_open`.
An active placement breaker does not suppress a separately valid already-loaded placement.
It suppresses only a candidate path that requires cold or warm loading and explains that decision with `model_load_suppressed`.
`placement_suppressed` remains the broader placement-lifecycle reason and is not reused for this breaker.

If required breaker identity, persistence, or read authority is unavailable, scheduling and final revalidation fail closed with the applicable existing identity or unavailable-facts code.
They do not emit `node_circuit_breaker_open` or `model_load_suppressed` unless durable state proves that breaker is active.

### Operator commands use Controller authority

Inspection and clear operations execute in the active Controller through the existing cluster-scoped Operator-or-admin service-account boundary.
Tenant-direct credentials and public inference credentials remain unauthorized.
The fixed routes are:

- `GET /ops/v1/circuit-breakers/nodes/:node_id`
- `POST /ops/v1/circuit-breakers/nodes/:node_id/clear`
- `GET /ops/v1/circuit-breakers/placements/:node_id/:model_id`
- `POST /ops/v1/circuit-breakers/placements/:node_id/:model_id/clear`

Inspection returns bounded canonical identity, state, generation, window evidence, suppression deadline, last transition, and expiry evaluation without exposing request content.
Successful inspection uses `Cache-Control: no-store` and a bounded `circuit_breaker` object containing kind, canonical identities, state, current contribution count, opening and suppression times, last clear time, and generation.
The absence of a breaker row for an existing canonical target is an authoritative closed breaker with zero contributions and generation zero, not an unavailable read.
Clear requires a JSON body with a non-empty `reason`.
It returns `cleared` or `already_cleared` plus the resulting bounded breaker object, and an already inactive breaker does not increment its generation again.
The authoritative mutation and audit event persist atomically with actor, action, target, time, reason, previous state, and resulting generation.
Malformed identity or reason, missing canonical targets, unavailable authority, and unauthorized credentials retain distinct validation, not-found, service-unavailable, and authentication or authorization failures.
An effective clear uses audit action `circuit_breaker.node.cleared` or `circuit_breaker.placement.cleared` at cluster scope.

### Transport health and breaker ownership remain separate

Runtime Endpoint liveness and status probes remain health-only observations and never create breaker contributions.
`Nodes.record_transport_failure/3` retains its health and queue-source behavior but is not an independent breaker counter.
The actual dispatch or execution failure outcome is the sole breaker contribution source, using its durable failure identity so health handling and repeated delivery cannot double-count it.
Health and breaker facts remain separate scheduler gates, and loss of either authority fails closed without translating one state into the other.

### Retry attribution remains downstream

This foundation exposes an idempotent public recording seam for a typed actual failure and a durable read seam for scheduling.
Issue #170 will connect individual attempt outcomes to that recording seam and must make attempt 1 effects durable before alternate scheduling.
This change does not introduce attempt identity policy, prior-Node exclusion, retry decisions, or attempt orchestration.

## Migration and compatibility

The expand migration creates empty breaker authority without synthesizing historical failures from Node health, request history, placement lifecycle, or transport observations.
Existing Nodes and placements therefore begin closed until new eligible failures are recorded.
All schema constraints, unique failure identity enforcement, the restrictive Node foreign key, and the validated non-FK model UUID contract are established before scheduler consumers require the new authority.
The implementation must not use a process-local fallback during rollout or restart.

## Rejected alternatives

- Process-local counters were rejected because they lose state across restart and split authority across Controllers.
- `occurred_at`-based rolling windows were rejected because delivery order and caller clocks could change threshold outcomes.
- Resetting rows in place without a generation and watermark was rejected because delayed pre-clear delivery could reopen a cleared breaker.
- Reusing Node health or placement lifecycle as breaker state was rejected because those gates have different causes, recovery, and Operator semantics.
- Suppressing already-loaded placements was rejected because `SPEC.md` limits the placement breaker effect to cold or warm load.
- Treating unavailable facts as an open breaker was rejected because fail-closed unavailability and a proven breaker transition require different stable explanations.
- Adding a foreign key from placement breaker history to `models.id` was rejected because restrict would block catalog deletion while cascade or nullification would destroy canonical history.
