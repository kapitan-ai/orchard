## ADDED Requirements

### Requirement: One logical Request with at most two Inference Attempts
Orchard SHALL perform Automatic Attempt Retry as an internal continuation of one logical Request with at most attempt 1 and attempt 2.
Both attempts MUST share the original Request ID, canonical payload, body hash, idempotency scope, admission result, queue grant, quota reservation, Payload Capture Mode, and caller-visible response.
Attempt 2 MUST NOT repeat admission or re-enter a queue.
One coarse Request FSM SHALL span both attempts without a new state.
A Request whose attempt 1 has not reached `running` SHALL remain in `dispatching` through attempt 1 resolution, the retry decision, alternate scheduling, and attempt 2 dispatch.
A Request whose attempt 1 reached `running` SHALL remain in `running` through attempt 1 resolution, the retry decision, and alternate scheduling, and SHALL take the bounded `running -> dispatching` edge exactly once at the atomic attempt 2 start boundary.
A declined retry SHALL take no backward edge and SHALL terminalize from the state attempt 1 already held.
Neither attempt SHALL re-enter `received`, `validated`, `admitted`, `queued`, or `scheduled`.
This requirement traces to `SPEC.md` §3.6, §3.7.1, §5.3, §5.4, §5.8, §5.9, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Retry succeeds under one Request
- **WHEN** attempt 1 fails with an explicitly retryable pre-commit failure and every retry gate passes
- **THEN** Orchard starts exactly one attempt 2 under the same Request
- **AND** admission, queue, quota, idempotency, and capture decisions are not repeated
- **AND** the Request terminalizes once from attempt 2

#### Scenario: Attempt 2 fails
- **WHEN** attempt 2 ends unsuccessfully without caller cancellation or disconnect
- **THEN** its terminal evidence records `retry_exhausted`
- **AND** Orchard starts no third attempt

#### Scenario: Caller cancels attempt 2
- **WHEN** caller cancellation or disconnect terminalizes attempt 2
- **THEN** its terminal evidence records `cancelled`
- **AND** Orchard starts no third attempt

#### Scenario: Coarse Request state crosses the attempt boundary
- **WHEN** attempt 1 reached `running` and every retry gate passes
- **THEN** the Request stays in `running` through attempt 1 resolution, the retry decision, and alternate scheduling
- **AND** it takes the bounded `running -> dispatching` edge exactly once at the atomic attempt 2 start boundary
- **AND** it does not re-enter `queued` or `scheduled`
- **AND** no retry-specific Request FSM state is introduced

#### Scenario: Declined retry takes no backward edge
- **WHEN** attempt 1 reached `running` and the retry decision declines with `no_alternative_node`, `cancelled`, or `budget_exhausted`
- **THEN** the Request never takes the `running -> dispatching` edge
- **AND** it terminalizes from the state attempt 1 already held

### Requirement: One absolute Request deadline
Orchard SHALL assign `requests.timeout_at` once when it creates the Request.
Queueing, scheduling, model loading, execution, cleanup, attempt evidence persistence, and alternate scheduling MUST consume that same absolute deadline.
No model-load or attempt-local timeout MAY extend it.
This requirement traces to `SPEC.md` §5.8, §5.9, §12.4, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Attempt 1 exhausts the budget
- **WHEN** attempt 1 cleanup leaves no positive time before `timeout_at`
- **THEN** Orchard starts no alternate schedule or dispatch side effect
- **AND** attempt 1 records `budget_exhausted`

#### Scenario: Attempt 2 receives only remaining time
- **WHEN** attempt 2 is permitted
- **THEN** every model-load and execute deadline is capped by the time remaining before the original `timeout_at`

### Requirement: Transport-independent Output Commitment
Orchard SHALL mark Output Commitment when the Controller validates and observes the first non-empty text delta, any valid tool-call delta with a stable non-empty tool-call identity, or a future content-bearing structured-output delta.
The Controller MUST record commitment before invoking a public event handler or serializer.
Accepted, progress, usage, model-load, empty text, and terminal events MUST NOT commit output.
Commitment SHALL be monotonic and identical for streaming and non-streaming Chat Completions and Responses.
This requirement traces to `SPEC.md` §3.6, §5.8, §5.9, §12.7, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Tool-call identity prevents retry
- **WHEN** attempt 1 emits a valid tool-call delta with a stable identity and empty arguments
- **THEN** Output Commitment occurs before downstream delivery
- **AND** a later attempt failure does not retry

#### Scenario: Empty text does not commit
- **WHEN** attempt 1 emits only empty text and control events before an eligible transient failure
- **THEN** Output Commitment remains false
- **AND** the retry decision continues through the remaining gates

#### Scenario: Handler fails after commitment
- **WHEN** a public event handler fails after the committing event is observed
- **THEN** the failure is non-retryable
- **AND** Orchard does not regenerate output on another Node

### Requirement: Closed fail-closed retry decision
Orchard SHALL permit attempt 2 only when attempt 1 failed before Output Commitment, time remains, the caller is live, first-Node identity is resolved, execution is resolved, capacity release is affirmative, the failure is explicitly retryable, and a different eligible Node exists.
An inference Runtime Endpoint `Failed` event MUST carry both `retryable: true` and one of the stable transient codes `node_unavailable`, `node_timeout`, `runtime_unavailable`, `resource_exhausted`, `timeout`, `worker_unavailable`, or `worker_down`.
A model-load failure MUST qualify only through a normalized category of `acquisition_failed`, `runtime_unavailable`, `resource_exhausted`, or `timeout`; its failure code or message MUST NOT independently authorize retry.
Unknown, deterministic, terminal-conformance, persistence, handler, serializer, orchestration, occupancy-ambiguous, and identity-ambiguous failures SHALL NOT retry.
Attempt 1 decline precedence SHALL be `output_committed`, `cancelled`, `budget_exhausted`, `not_retryable`, `identity_unresolved`, `occupancy_unresolved`, then `no_alternative_node`.
This requirement traces to `SPEC.md` §5.8, §5.9, §§12.1-12.4, §12.7, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Runtime assertion is insufficient by itself
- **WHEN** a Runtime Endpoint reports `retryable: true` with an unknown or non-allowlisted code
- **THEN** Orchard records `not_retryable`
- **AND** no attempt 2 starts

#### Scenario: Several gates fail together
- **WHEN** more than one retry gate fails at the same boundary
- **THEN** Orchard persists the first applicable decline reason in the normative precedence
- **AND** the Request remains terminal regardless of which decline reason is selected

### Requirement: Hard different-Node scheduling
Attempt 2 SHALL run a fresh scheduler decision with attempt 1's durable Node identity in `exclude_node_ids`.
The scheduler MUST apply exclusion before eligibility, tiering, ranking, scoring, and prefix-cache scoring.
The orchestrator MUST reject an excluded, missing, or mismatched selected identity before dispatch.
A candidate removed by that hard filter SHALL be reported in the scheduler explanation as a rejected candidate with the stable reason code `previous_attempt_node_excluded`.
Alternate scheduling MUST NOT reallocate the per-logical-Request `ScorePrefixCache` budgets in `SPEC.md` §7.5.3; attempt 2 MAY score only within their unconsumed remainder and MUST otherwise rank fail-open on deterministic base order.
Alternate scheduling MUST NOT initiate a second explicitly unmanaged compatibility status-probe wave, so an attempt 1 dispatched to a compatibility candidate SHALL start no attempt 2 and SHALL record `no_alternative_node` unless an earlier decline reason applies.
No alternative SHALL preserve attempt 1's original public failure without queue re-entry or deadline extension.
This requirement traces to `SPEC.md` §5.5, §5.6, §5.7, §5.8, §7.3.5, §7.5.3, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Another address resolves to the same Node
- **WHEN** an alternate target address resolves to attempt 1's durable Node identity
- **THEN** the candidate remains excluded
- **AND** the scheduler explanation rejects it with `previous_attempt_node_excluded`
- **AND** Orchard does not dispatch it as attempt 2

#### Scenario: Prefix-cache budget is already consumed
- **WHEN** attempt 1 consumed the per-logical-Request `ScorePrefixCache` budget
- **THEN** alternate scheduling issues no further `ScorePrefixCache` RPC
- **AND** attempt 2 ranks fail-open on deterministic base order

#### Scenario: Attempt 1 used the unmanaged compatibility branch
- **WHEN** attempt 1 was dispatched to an explicitly unmanaged static compatibility candidate and fails with an otherwise retryable pre-commit failure
- **THEN** Orchard runs no second compatibility status-probe wave
- **AND** attempt 1 records `no_alternative_node`
- **AND** the logical Request returns attempt 1's stable public failure

#### Scenario: No alternative exists
- **WHEN** hard exclusion leaves no different eligible Node
- **AND** the post-scheduling caller and deadline gate passes
- **THEN** attempt 1 records `no_alternative_node`
- **AND** the logical Request returns attempt 1's stable public failure

#### Scenario: Caller or deadline wins after alternate scheduling
- **WHEN** caller liveness or the absolute deadline fails after alternate scheduling and before either scheduler result is persisted
- **THEN** attempt 1 records `cancelled` or `budget_exhausted` according to the normative precedence
- **AND** Orchard records neither `no_alternative_node` nor attempt 2 started evidence

### Requirement: Ordered append-only attempt evidence
Orchard SHALL persist Inference Attempt evidence as append-only `request_step.*` Request Events rather than a separate attempt table.
The orchestrator SHALL own exactly one started event for each attempt, and the dispatcher MUST NOT append another.
After the final pre-start caller and deadline gate, attempt 1 terminal evidence with `retried` and the sole attempt 2 started event MUST append atomically before attempt 2 dispatch.
Every terminal attempt SHALL record the closed evidence required by `SPEC.md` §3.7.1 subject to Payload Capture Mode.
`attempt_outcome` SHALL be `completed`, `failed`, `cancelled`, `timed_out`, or `interrupted`.
`output_commitment_kind` SHALL be absent without commitment and otherwise SHALL be `text`, `tool_call`, or `structured_output`.
`execution_resolution` SHALL be `not_started`, `terminated`, or `unresolved`.
`capacity_release_outcome` SHALL be `released`, `already_released`, `not_applicable`, or `unresolved`.
`failure_class` SHALL use the closed §3.7.1 vocabulary, and `failure_code` SHALL use a Controller-normalized stable value from the `SPEC.md` §8.2 `requests.error_code` vocabulary.
Runtime, model-load, capacity, cancellation, deadline, terminal-conformance, and unknown source failures SHALL follow the normalization boundary in `SPEC.md` §3.7.1; a raw source code MAY persist separately only under `full` and SHALL NOT control retry, public mapping, or metrics.
Closed attempt evidence SHALL remain durable under `none` and `metadata`, while unknown raw runtime text SHALL NOT become durable evidence or a metric label.
Attempt 1 SHALL have no excluded Node, while attempt 2 SHALL record exactly attempt 1's durable Node UUID as excluded.
A target reference SHALL be an approved stable identifier under `full` or a deterministic hash outside `full`, never a raw target address.
The coarse Request SHALL terminalize exactly once.
This requirement traces to `SPEC.md` §3.7.1 and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Attempt 2 boundary is atomic
- **WHEN** every retry gate passes for a valid different candidate
- **THEN** Orchard atomically appends attempt 1 terminal evidence with `retried` and the sole attempt 2 started event
- **AND** the dispatcher consumes that started context without appending another

#### Scenario: Attempt 2 start persistence fails
- **WHEN** Orchard cannot durably append attempt 2 started evidence
- **THEN** attempt 2 dispatch does not begin
- **AND** the Request terminalizes through the existing orchestration persistence failure

#### Scenario: Existing request events remain readable
- **WHEN** Orchard reads an older inference-turn result without enriched attempt fields
- **THEN** the row remains readable
- **AND** closed validation applies only when constructing the enriched terminal shape

### Requirement: Logical accounting remains once per Request
Input-token accounting SHALL occur once and the output reservation SHALL remain held between attempts.
Quota SHALL reconcile once when the logical Request terminalizes.
The effective Payload Capture Mode SHALL apply unchanged to both attempts.
Discarded pre-commit attempt output SHALL NOT contribute logical usage or public output.
This requirement traces to `SPEC.md` §5.3, §5.8, §9.1, §10.10, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Attempt 1 is discarded
- **WHEN** attempt 1 fails before commitment and attempt 2 starts
- **THEN** attempt 1 does not release or reacquire quota
- **AND** its buffered events and usage do not become logical public output
- **AND** capture policy does not widen

### Requirement: Caller disconnect is cancellation
Caller disconnect SHALL prevent further dispatch and map consistently to Request state `cancelled` across pre-dispatch, capacity-gate, and runtime-drain phases.
A disconnect before the atomic attempt 2 boundary SHALL terminalize attempt 1 with `cancelled` and append no attempt 2 evidence.
After either attempt starts, a disconnect SHALL persist `request_step.cancelled`, durable code `request_caller_disconnect`, and retry decision `cancelled` on that started attempt.
When a response remains deliverable it SHALL use HTTP `499` and public code `request_cancelled`.
This requirement traces to `SPEC.md` §5.9, §12.7, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Caller disconnects before attempt 2 starts
- **WHEN** the caller disconnects after attempt 1 fails but before the atomic attempt 2 boundary
- **THEN** Orchard records cancellation on attempt 1
- **AND** no attempt 2 evidence, scheduling, or acquisition follows

#### Scenario: Caller disconnects after attempt 2 starts
- **WHEN** the caller disconnects after the atomic attempt 2 boundary but before its dispatch side effect
- **THEN** Orchard terminalizes attempt 2 as `cancelled`
- **AND** no dispatch or third attempt follows

### Requirement: Per-attempt breakers and bounded metrics
Each actual breaker-eligible failed attempt SHALL contribute independently to the existing breaker for the Node or placement that produced it.
The Node-level breaker SHALL count an attempt failure only when its `failure_class` is `pre_acceptance_unavailable` or `worker_or_node_loss`, and the placement-level breaker only when it is `model_load_failure`.
`capacity_rejection`, `runtime_failure`, `terminal_conformance`, `cancellation`, `deadline`, `controller_failure`, `occupancy_unresolved`, and `identity_unresolved` MUST NOT contribute to either breaker, and an unsuccessful attempt MUST contribute to at most one breaker.
Attempt 1 breaker effects MUST be durable and visible before the fresh alternate scheduler decision.
The retry decision itself MUST NOT increment a breaker.
Logical Request metrics SHALL emit once per Request and attempt metrics SHALL emit once per started attempt.
For the attempt counter, `attempt` SHALL be `1` or `2`, `outcome` SHALL use the closed attempt outcome vocabulary, and `failure_class` SHALL use the closed failure vocabulary or the metric-only value `none` for a completed attempt.
`orchard_inference_retries_total` SHALL emit once per Request whose attempt 1 has a retry decision.
Its `reason` SHALL be `retried`, `not_retryable`, `output_committed`, `cancelled`, `budget_exhausted`, `identity_unresolved`, `occupancy_unresolved`, or `no_alternative_node`, and `result` SHALL be `succeeded`, `failed`, or `declined` in the combinations defined by `SPEC.md` §9.1.
Metric labels MUST use closed vocabularies and MUST NOT contain high-cardinality identifiers.
This requirement traces to `SPEC.md` §5.10, §9.1, and `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Post-start capacity scarcity does not suppress a Node
- **WHEN** three attempts on a healthy Node fail after `request_step.started` with `capacity_rejection`
- **THEN** neither the Node-level nor the placement-level breaker counts those failures
- **AND** the Node remains eligible for later scheduling decisions

#### Scenario: Attempt 1 breaker effect precedes alternate selection
- **WHEN** attempt 1 produces a breaker-eligible failure and qualifies for retry
- **THEN** its breaker effect is durable before the fresh alternate scheduler decision
- **AND** that scheduler decision observes the updated suppression state

#### Scenario: Retried Request fails twice
- **WHEN** both attempts fail with breaker-eligible failures on different Nodes
- **THEN** each failure is attributed once to its producing Node or placement
- **AND** the retry decision adds no breaker event
- **AND** the logical Request outcome metric emits once

#### Scenario: Retry metric combinations are bounded
- **WHEN** attempt 1 records `retried`
- **THEN** retry result is `succeeded` or `failed` from attempt 2
- **AND WHEN** attempt 1 records a decline reason
- **THEN** retry result is `declined`
- **AND WHEN** attempt 2 is cancelled or times out after attempt 1 records `retried`
- **THEN** retry result is `failed`
- **AND** `retry_exhausted` never appears as the retry counter reason
