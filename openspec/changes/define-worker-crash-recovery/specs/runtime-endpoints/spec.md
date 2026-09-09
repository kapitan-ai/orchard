## ADDED Requirements

### Requirement: Authenticated Worker Recovery Observations

Runtime Endpoint Observations SHALL carry a separate bounded additive `worker_recovery_placements` collection for `SPEC.md` §12.2 state.
Each entry SHALL contain the exact runtime model reference, recovery generation, recovery phase, desired residency, crash-loop breaker state, restart streak, bounded in-window crash count, up to five distinct current-window incident identities and Node-local occurrence times, current worker generation when present, earliest restart time when present, monotonic state sequence, and bounded recovery-operation reconciliation evidence.
While a breaker is open, the entry SHALL retain the exact five-incident opening proof until explicit recovery advances the generation even after the incidents age out of the rolling window.
It MUST NOT contain PIDs, monitor references, sockets, local paths, raw exit reasons, Request identities, content, secrets, or unbounded provider terms.
The existing `worker_crash_counters` SHALL remain cumulative metrics evidence and MUST NOT become recovery authority.
Ordinary placement state and Placement Capacity SHALL remain separate from recovery evidence.
This requirement clarifies `SPEC.md` §§4.6.1 and 12.2.

#### Scenario: Failed placement has no live worker

- **WHEN** a crash-loop breaker opens and the worker is absent
- **THEN** the Runtime Endpoint observation includes the exact failed recovery placement and open state
- **AND** no live PID or fabricated Placement Capacity is required

#### Scenario: Older endpoint omits recovery evidence

- **WHEN** an older Runtime Endpoint returns an otherwise decodable observation without `worker_recovery_placements`
- **THEN** Orchard treats recovery evidence as absent rather than closed
- **AND** enforcement begins only through an explicit mixed-version capability and cutover contract

#### Scenario: Existing crash metric counter is present

- **WHEN** one observation carries both recovery evidence and `worker_crash_counters`
- **THEN** the recovery state is evaluated only from the recovery entry
- **AND** the cumulative counter remains input only to its existing metrics deduplicator

#### Scenario: Opening incidents age out of the rolling window

- **WHEN** an open placement's five opening incidents become older than ten minutes
- **THEN** its observation retains their bounded identities and occurrence times as opening proof
- **AND** the current-window count may become zero without closing the breaker

### Requirement: Durable Controller Worker Recovery Projection

The active Controller SHALL persist accepted worker recovery state in Postgres only from an authenticated scheduler-fresh observation whose Node and target identity match durable admitted inventory and whose model reference resolves exactly.
Within one recovery generation, accepted state sequence SHALL advance monotonically.
The first closed baseline SHALL be accepted only from an evidence-producing bootstrap load result or scheduler-fresh observation after mixed-version enforcement proves support and no prior Controller projection exists; the Node Agent SHALL initialize a closed baseline only when no prior local record exists and SHALL never overwrite an existing record as empty.
After a projection exists, a closed newer generation SHALL reconcile to the matching Controller-issued recovery operation before it can remove suppression.
Duplicate, regressed, stale, malformed, unresolved, or identity-mismatched evidence MUST NOT clear or reattribute recovery state.
The Controller SHALL mirror the Node Agent transition and persist accepted transition evidence plus bounded opening proof, and MUST NOT recompute the five-in-ten window from heartbeat receipt time or reconstruct it from metrics, logs, Requests, §5.10 failures, or heartbeat deltas.
This requirement clarifies durable observation behavior in `SPEC.md` §§4.6.1, 8.5, and 12.2.

#### Scenario: Open evidence is delivered twice

- **WHEN** the same recovery generation and state sequence is observed more than once
- **THEN** the durable projection and incident evidence change at most once
- **AND** suppression remains open

#### Scenario: Closed evidence has no matching recovery operation

- **WHEN** a Node reports a newer closed recovery generation that the Controller cannot reconcile to its issued operation
- **THEN** the Controller retains fail-closed suppression
- **AND** it does not treat Node Agent restart as recovery

#### Scenario: Observation commit fails

- **WHEN** the Controller cannot commit the recovery projection with the accepted heartbeat transaction
- **THEN** no process-local scheduler view treats the uncommitted state as current
- **AND** loading and dispatch fail closed through the existing authority-unavailable behavior

#### Scenario: Never-seen placement performs its first load

- **WHEN** authenticated capability negotiation proves recovery support, the Controller has no projection for the exact placement, and every other candidate gate passes
- **THEN** the Controller may select it as a provisional cold candidate and request one evidence-producing bootstrap `EnsureModelLoaded` only after normal attempt start and allocation
- **AND** the Node Agent commits the initial closed record before worker creation and returns exact recovery evidence that the Controller commits before final authorization or execution

#### Scenario: Established placement omits recovery evidence

- **WHEN** a placement was previously established or projected but its current recovery evidence is missing or unavailable
- **THEN** Orchard fails loading and execution closed
- **AND** the first-load bootstrap exception cannot be reused to erase prior suppression

### Requirement: Generation-Fenced Worker Recovery Operations

The Runtime Endpoint Interface SHALL provide distinct clear, forced-reload, and unload-reload worker recovery operations.
Each operation SHALL carry an opaque operation ID, exact Node and runtime model reference, expected recovery generation, action, actor reference, and bounded reason.
It SHALL also carry Controller-authenticated `issued_at` and `expires_at` values whose interval is no longer than 24 hours.
Before each corresponding side effect, the Node Agent SHALL persist an operation journal entry bound to a canonical payload hash and progress it through applicable `accepted`, `stopping`, `stopped`, `loading`, and resumable `blocked` stages, then persist a bounded `applied` or `failed` terminal result with the resulting recovery generation and state sequence.
The Node Agent SHALL check operation-ID and payload binding before expected generation, return retained progress or result for an identical retry, reject conflicting operation-ID reuse, and reject a stale expected generation for a new operation without mutation.
Both authorities SHALL reject a first delivery after expiry, and the Node Agent SHALL reject when its durable clock evidence cannot prove that current time is within the authenticated interval.
For a recorded operation, expiry SHALL forbid every next discretionary stop or load side effect but SHALL permit read-only result retrieval and mandatory safety reconciliation of a side effect already started while valid.
An unload/reload generation advance and exact expected-stop intent SHALL commit atomically after active-Request rejection and SHALL authorize mandatory custody-checked stop and cleanup after expiry even if no termination signal was previously sent, but SHALL NOT authorize the expired reload.
An expired operation that never advanced generation SHALL terminate failed with prior recovery state unchanged; one that advanced generation SHALL start no reload and SHALL remain blocked and suppressed until already-started cleanup or load custody resolves to a durable applied loaded or closed-unloaded result.
Terminal results SHALL remain retryable for at least 30 days and through `expires_at` plus 24 hours and be capped at 128 per placement; a full cap SHALL reject a new operation before mutation rather than evict an unexpired result.
Timeout, disconnect, or missing acknowledgement SHALL be an unknown outcome rather than proof of success.
The `preload` flag, ordinary `EnsureModelLoaded`, ordinary `UnloadModel`, and request metadata MUST NOT be repurposed as recovery authorization.
This requirement clarifies `SPEC.md` §§6.8 and 12.2.

#### Scenario: Controller retries after a lost result

- **WHEN** the Controller retries the exact same operation ID and payload after losing the first acknowledgement
- **THEN** the Node Agent returns the retained effective result
- **AND** it does not advance recovery generation or repeat cleanup and load side effects

#### Scenario: Node restarts after recording command progress

- **WHEN** the Node Agent restarts after persisting `stopping`, `stopped`, or `loading` but before returning a terminal result
- **THEN** it resumes or reconciles the recorded stage under the same operation ID
- **AND** it does not repeat a side effect whose durable progress proves completion

#### Scenario: Blocked operation becomes reconcilable

- **WHEN** an identical retry finds resumable `blocked` progress and new exact evidence proves the unresolved custody or side effect
- **THEN** the Node Agent resumes the recorded next stage under the same operation ID
- **AND** a different operation remains conflicting until the blocked operation terminates

#### Scenario: Retained-result capacity is full

- **WHEN** 128 unexpired terminal operation results are retained for one placement
- **THEN** the Node Agent rejects a different new operation before mutation
- **AND** identical retries continue to return their retained results

#### Scenario: Completed no-op is delivered after expiry

- **WHEN** a delayed command whose earlier no-op or failure did not advance recovery generation arrives after its authenticated expiry
- **THEN** Orchard rejects it before mutation even when the old expected generation still matches
- **AND** result eviction cannot turn the completed operation into a newly authorized command

#### Scenario: Blocked cleanup becomes provable after expiry

- **WHEN** an operation advanced generation and started cleanup while valid but exact absence becomes provable only after expiry
- **THEN** mandatory safety reconciliation records an applied closed and unloaded result without starting the expired reload
- **AND** a new valid operation may proceed only after that terminal result becomes durable

#### Scenario: Node restarts before committed stop begins

- **WHEN** unload/reload commits its new generation and exact stop intent, the Node restarts before the first termination signal, and the command then expires with the old worker live
- **THEN** mandatory custody-checked cleanup stops the exact intended generation without starting the expired reload
- **AND** exact absence produces a durable applied closed-unloaded result before any new command proceeds

### Requirement: Typed Recovery Refusals Do Not Become Load Failures

A recovery-only refusal before worker launch or execution acceptance SHALL use a typed `WorkerRecoveryRefusal` rather than `ModelLoadFailure` or an ordinary retryable inference failure.
The closed refusal codes SHALL be `worker_crash_loop_open`, `worker_recovery_backoff`, `worker_recovery_operation_pending`, `worker_recovery_custody_unresolved`, and `worker_recovery_authority_unavailable`.
The first three SHALL map after attempt start to failure class `capacity_rejection`, request code `model_busy`, and retry decision `not_retryable`.
`worker_recovery_custody_unresolved` SHALL map to `occupancy_unresolved`, `internal_error`, and retry decision `occupancy_unresolved`.
`worker_recovery_authority_unavailable` SHALL map to `runtime_failure`, `internal_error`, and retry decision `not_retryable`.
Every mapping SHALL use `execution_resolution = not_started`, require effective-once Controller allocation release, and contribute to no §5.10 breaker.
A pre-attempt candidate refusal SHALL remain scheduler evidence and SHALL create no attempt outcome.
This requirement preserves `SPEC.md` §§3.7.1, 5.8 through 5.10, and 12.2.

#### Scenario: Stale Controller projection permits a load call

- **WHEN** the Controller calls `EnsureModelLoaded` after attempt start but the Node Agent's current recovery state is open, in backoff, or operation-pending
- **THEN** the Node returns the matching typed recovery refusal without starting a worker or populating `ModelLoadFailure`
- **AND** the Controller releases capacity once, records non-retryable `capacity_rejection` with public code `model_busy`, and creates no §5.10 contribution

#### Scenario: Recovery authority cannot be read

- **WHEN** the Node Agent cannot establish its protected recovery authority before worker launch
- **THEN** it returns `worker_recovery_authority_unavailable` without asserting runtime retryability
- **AND** the attempt maps to non-retryable `runtime_failure` with `internal_error` and no §5.10 contribution

#### Scenario: Ordinary load targets an open placement

- **WHEN** `EnsureModelLoaded` targets an open crash-loop placement without an accepted recovery operation
- **THEN** the Node Agent rejects it with crash-loop suppression
- **AND** load flags or metadata cannot bypass the breaker

#### Scenario: Concurrent operations use one expected generation

- **WHEN** two different recovery operations race with the same expected generation
- **THEN** they serialize per exact recovery placement
- **AND** only the first effective operation may advance the generation
