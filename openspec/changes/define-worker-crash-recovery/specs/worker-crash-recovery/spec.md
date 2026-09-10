## ADDED Requirements

### Requirement: Exact Recovery Placement And Worker Generation Identity

Orchard SHALL identify one worker crash recovery placement by the stable Node identity and exact runtime `ModelRef` of `model_id` plus `version`.
After artifact acquisition, validation, and launch preflight succeed and immediately before the first worker-creation side effect, the Node Agent SHALL durably allocate a worker generation within the current recovery generation and bind the BEAM owner, provider subprocess, service incarnation, channel, load operation, expected-stop intent, and cleanup to that generation.
The first accepted qualifying terminal incident for that worker generation SHALL contribute exactly one crash.
Duplicate notifications and events whose placement, recovery generation, worker generation, operation identity, or live process identity is stale or mismatched MUST NOT change recovery state.
This requirement clarifies `SPEC.md` §12.2.

#### Scenario: Owner and provider exits report one incident

- **WHEN** the exact current provider exits unexpectedly and its BEAM worker owner later reports its own exit
- **THEN** the Node Agent records one crash for the current worker generation
- **AND** the second notification does not increment the crash window or restart streak

#### Scenario: Replaced worker reports a late exit

- **WHEN** a delayed event names a worker generation that has already been replaced
- **THEN** the Node Agent ignores the event for recovery policy
- **AND** the event cannot remove, fail, or count against the current worker

#### Scenario: Same model identifier has two versions

- **WHEN** one version reaches the crash threshold
- **THEN** only that exact Node, model identifier, and version placement opens
- **AND** another version or Node retains its independent recovery state

### Requirement: Closed Worker Crash Eligibility

A worker generation SHALL contribute one crash when its accepted launch terminates because the current BEAM owner or exact provider subprocess unexpectedly dies or is replaced, because BEAM owner start, executable resolution, provider spawn, or readiness fails to establish a valid live current worker, or because the exact current owner or provider process dies or is replaced during startup model loading.
Exit status zero MUST NOT establish intentionality without matching expected-stop intent.
Artifact acquisition or validation before the accepted launch boundary, an ordinary model-load failure that leaves the current worker live, transport or RPC unavailability without process-loss proof, load-task failure without worker terminalization, intentional unload, eviction, reset, supervised shutdown, managed lifecycle stop, request cancellation, subscriber exit, and request-generation failure MUST NOT contribute.
Expected-stop intent SHALL be durable before termination begins and SHALL name the exact placement, recovery generation, worker generation, operation identity, and reason.
The Node Agent SHALL classify the originating event before cleanup, with stale identity rejected first, matching expected-stop intent excluded second, proven pre-cleanup process death or replacement counted third, launch-boundary start or readiness failure counted fourth, deliberate cleanup of a still-live process excluded fifth, and causally uncertain absence blocked without a crash contribution.
This requirement clarifies `SPEC.md` §12.2 without changing §5.10 failure eligibility.

#### Scenario: Provider fails during startup

- **WHEN** a worker-generation launch has been accepted and provider spawn or readiness terminates without a valid live current worker
- **THEN** the generation contributes one crash
- **AND** repeated cleanup or load-failure notifications for that generation contribute none

#### Scenario: Acquisition fails before launch

- **WHEN** artifact lookup, transfer, verification, or cache preparation fails before a worker-generation launch is accepted
- **THEN** the failure contributes no worker crash
- **AND** existing model-load failure handling remains responsible for the load result

#### Scenario: Readiness timeout cleans up a live provider

- **WHEN** readiness times out while the exact current provider remains live and cleanup records expected-stop intent before termination
- **THEN** the timeout contributes no worker crash
- **AND** existing startup or load failure handling owns the result

#### Scenario: Load RPC failure deliberately stops a live provider

- **WHEN** a load RPC fails while the exact provider is live and the Node Agent records expected-stop intent before cleanup
- **THEN** the deliberate cleanup contributes no worker crash
- **AND** the model-load result remains separate from worker crash policy

#### Scenario: Provider dies before deadline cleanup

- **WHEN** the exact current provider is proven dead before caller, load-deadline, or cleanup intent is established
- **THEN** the worker generation contributes one crash
- **AND** later cleanup notifications do not contribute again

#### Scenario: Current custody proves replacement

- **WHEN** a current-generation custody check proves that the bound process identity was replaced
- **THEN** the replacement contributes one crash
- **AND** only a notification explicitly naming an obsolete generation is ignored as stale

#### Scenario: Intentional unload terminates the worker

- **WHEN** exact expected-stop intent is durable before an authorized unload terminates the current worker
- **THEN** the exit contributes no worker crash
- **AND** late exit notifications remain deduplicated against that intent and generation

### Requirement: Exact Backoff And Crash-Loop Threshold

The Node Agent SHALL maintain a restart streak separately from the rolling crash window.
After qualifying streak incidents, the earliest automatic replacement delays SHALL be 1, 2, 4, 8, 16, 30, 30 seconds and remain capped at 30 seconds without jitter.
At incident acceptance time `t`, the rolling window SHALL contain distinct current-recovery-generation incidents in `(t - 600 seconds, t]`.
The fifth incident in that window SHALL atomically mark the placement failed and open a latched crash-loop breaker before another automatic replacement can be authorized.
Cleanup proof, current generation, desired residency, and breaker state SHALL remain independent replacement gates.
This requirement makes the timing in `SPEC.md` §12.2 executable.

#### Scenario: Delay progression reaches the cap

- **WHEN** qualifying incidents advance the restart streak beyond its fifth step without five incidents remaining in one rolling window
- **THEN** the earliest delays are 1, 2, 4, 8, 16, then 30 seconds
- **AND** every later delay remains 30 seconds

#### Scenario: Incident lies exactly on the lower boundary

- **WHEN** an earlier distinct incident occurred exactly 600 seconds before the current incident
- **THEN** the earlier incident is outside the rolling window
- **AND** an incident later than that boundary remains inside

#### Scenario: Fifth incident opens the breaker

- **WHEN** the fifth distinct qualifying incident is accepted inside the ten-minute window
- **THEN** the placement becomes failed and its crash-loop breaker opens atomically
- **AND** the computed backoff step is retained as evidence but no automatic restart timer is armed

### Requirement: Stable Operation Resets Only The Restart Streak

Stable operation SHALL mean ten continuous minutes in `loaded` for the exact current worker generation without a qualifying crash, proven process loss, or transition out of loaded state.
Completing that interval while the breaker is closed SHALL reset the restart streak to zero.
Rolling evidence SHALL expire only through its rolling-window boundary, and cumulative metrics SHALL retain their existing semantics.
Stable operation, healthy status, heartbeat resumption, and window expiry MUST NOT clear an open crash-loop breaker.
The crash-loop breaker SHALL have no automatic expiry.
This requirement clarifies recovery reset in `SPEC.md` §12.2.

#### Scenario: Loaded operation remains stable

- **WHEN** the exact current worker remains loaded continuously for ten minutes without a qualifying incident
- **THEN** the next qualifying crash uses the 1-second restart step
- **AND** cumulative crash metrics do not reset

#### Scenario: Open breaker outlives its window

- **WHEN** more than ten minutes elapse after a crash-loop breaker opens
- **THEN** the breaker remains open
- **AND** ordinary health or loadedness evidence cannot close it

### Requirement: Durable Node-Local Recovery Authority

The Node Agent SHALL persist a versioned protected recovery record for each established recovery placement outside worker processes.
For a capability-proven exact placement that has never had a Node-local record or Controller projection, an evidence-producing bootstrap load SHALL initialize and commit the record before the first worker-creation side effect and SHALL return exact recovery generation, state sequence, worker generation, and current recovery evidence.
The record SHALL contain placement identity, recovery generation, desired residency, exact last successfully loaded artifact and canonical cache binding when required, worker-generation identity, recovery phase of `idle`, `loading`, `loaded`, `reconciling`, `backoff`, `failed`, `blocked`, `recovery_uncertain`, or `unloaded`, monotonically increasing state sequence, breaker state, restart streak, bounded crash evidence, restart deadline, stable-operation boundary, a bounded recovery operation journal, boot and elapsed-time evidence, and a wall-clock high-water mark.
Crash, open, and effective recovery transitions MUST be durable before they authorize a replacement or report success.
PIDs, monitor references, timer references, ports, sockets, and live connections MUST NOT be restored as custody.
Missing, corrupt, unwritable, or unknown-newer established state SHALL fail new worker starts closed for that placement while safe cleanup and existing Request terminalization continue.
After restart, only trusted non-decreasing elapsed-time evidence MAY shorten a retained delay or prune rolling evidence; otherwise Orchard SHALL rearm the full applicable delay and retain the evidence.
An interrupted launch or previously loaded generation found absent without provable expected-stop intent or qualifying process-loss ordering SHALL enter `recovery_uncertain` and MUST NOT restart automatically.
This requirement clarifies Node Agent ownership in `SPEC.md` §§4.6.1 and 12.2.

#### Scenario: Recovery owner restarts during backoff

- **WHEN** the recovery owner or Node Agent restarts with a retained future restart deadline
- **THEN** Orchard reconstructs policy state without trusting old process handles
- **AND** it does not launch before the retained deadline and exact old-process reconciliation

#### Scenario: First load creates recovery authority

- **WHEN** a capability-proven exact placement has no prior Node-local record or Controller projection
- **THEN** the Node Agent commits an initial closed record and worker generation before creating a worker
- **AND** failure to commit that record prevents the first worker side effect

#### Scenario: Established recovery state cannot be decoded

- **WHEN** a placement's retained state is corrupt or uses an unsupported newer schema
- **THEN** Orchard blocks new starts for that placement
- **AND** it does not interpret the state as a closed empty history

#### Scenario: Wall clock moves backwards

- **WHEN** wall-clock time is earlier than the retained high-water mark after restart
- **THEN** Orchard does not prune crash evidence or shorten the restart wait
- **AND** explicit recovery remains available through the generation-fenced path

#### Scenario: Wall clock jumps forward after restart

- **WHEN** wall time advances but trusted boot-continuous elapsed evidence is unavailable
- **THEN** Orchard rearms the full applicable delay from recovery-owner startup
- **AND** the wall-clock jump cannot authorize an early replacement or prune crash evidence

#### Scenario: Loaded generation is absent after owner restart

- **WHEN** restart reconciliation finds a previously loaded generation absent and cannot prove expected stop or qualifying process-loss ordering
- **THEN** the placement becomes `recovery_uncertain`
- **AND** no automatic replacement starts until explicit recovery or stronger custody reconciliation resolves it

### Requirement: Automatic Residency Restoration Is Guarded

A placement that successfully reaches `loaded` SHALL retain desired residency until an intentional unload or eviction changes it.
After an eligible crash, Orchard SHALL start exactly one automatic Node-local residency restoration pipeline only after the persisted deadline passes and current generation, desired residency, closed breaker, exact old-process cleanup, durable artifact binding, and Node-owned resource gates all pass.
That restoration SHALL provide no Controller scheduling, trust, lifecycle, quarantine, allocation, dispatch-ceiling, §5.10, or serving authority.
Every later load or execution request SHALL remain subject to current Controller-owned gates and final crash-loop projection revalidation.
A startup crash for a load that never established desired residency SHALL fail its existing load operation and MUST NOT invent autonomous residency.
A first-ever preload or recovery load SHALL remain desired unloaded until exact load success and therefore MUST NOT create automatic restoration authority when its startup generation crashes.
A non-crash local restoration failure SHALL stop that restoration attempt, MUST NOT create an undocumented retry loop, and MUST NOT create a §5.10 contribution without an actual eligible Request attempt.
This requirement clarifies worker restart behavior in `SPEC.md` §§6.8 and 12.2.

#### Scenario: Loaded worker crashes

- **WHEN** the exact current worker for a desired-loaded placement crashes and the breaker remains closed
- **THEN** Orchard schedules one automatic restoration no earlier than the applicable delay
- **AND** the restoration remains subject to cleanup, durable artifact binding, and Node-owned resource gates without granting serving authority

#### Scenario: Intentional unload wins over a pending timer

- **WHEN** an unload changes desired residency to unloaded while a restart timer is pending or queued
- **THEN** the timer cannot launch a replacement
- **AND** the placement remains unloaded

#### Scenario: Restoration load fails without another crash

- **WHEN** automatic restoration encounters a model-load failure while the current worker remains live or no new worker generation terminalizes
- **THEN** that restoration attempt ends under existing load-failure behavior
- **AND** no new automatic retry loop starts from the load failure alone

### Requirement: Asynchronous Recovery Is Generation-Fenced

Every recovery timer and asynchronous cleanup, load, or process completion SHALL carry the exact placement, recovery generation, worker generation or load-operation identity, and expected phase.
The recovery owner SHALL revalidate those identities, desired residency, breaker state, deadline, load ownership, and old-process absence before any side effect.
Timer cancellation alone MUST NOT be treated as a fence.
At most one current replacement or load pipeline SHALL exist for one recovery placement.
A loaded transition SHALL require the exact current live worker and every matching identity.
This requirement clarifies concurrent recovery behavior in `SPEC.md` §§6.8 and 12.2.

#### Scenario: Cancelled timer message was already queued

- **WHEN** a timer message arrives after unload or recovery advanced the generation
- **THEN** identity revalidation rejects it without a worker start
- **AND** it cannot change history, phase, or breaker state

#### Scenario: Late load succeeds after replacement

- **WHEN** a load completion names an obsolete operation or worker generation
- **THEN** Orchard cleans up the stale worker if needed
- **AND** it does not publish the current placement as loaded

#### Scenario: Previous process absence is unresolved

- **WHEN** cleanup cannot prove the exact old owner, provider process, and local channel absent
- **THEN** the placement remains blocked
- **AND** Orchard does not spend another backoff step or start a replacement

### Requirement: Explicit Recovery Advances One Fenced Generation

Crash-loop clear, forced reload, and unload/reload SHALL be Controller-authorized operations carrying an opaque operation ID, exact target, expected recovery generation, action, actor reference, and bounded reason.
Each operation SHALL also carry Controller-authenticated `issued_at` and `expires_at` values with at most 24 hours between them.
The Node Agent SHALL serialize operations per placement and persist a payload-bound operation journal before every side effect, with applicable `accepted`, `stopping`, `stopped`, `loading`, and resumable `blocked` progress followed by a bounded `applied` or `failed` terminal result containing the resulting recovery generation and state sequence.
It SHALL check operation-ID and payload binding before expected generation, return retained progress or result for an identical retry, reject conflicting operation-ID reuse, and reject a stale expected generation for a new operation without mutation.
First delivery after expiry and commands whose durable clock evidence cannot prove current validity MUST fail before mutation.
For a previously recorded operation, expiry MUST prevent every next discretionary stop or load side effect but SHALL allow read-only result retrieval and mandatory safety reconciliation of a side effect already started while valid.
For unload/reload, recovery-generation advance and exact expected-stop intent SHALL commit atomically after active-Request rejection and SHALL authorize mandatory custody-checked termination and cleanup after expiry even when no termination signal was sent before restart or expiry; the expired reload MUST NOT start.
Only the first effective operation for a generation SHALL advance it and reset the restart streak and rolling crash evidence.
Unknown delivery outcome SHALL retain suppression until retry or later reconciliation proves the matching result.
No recovery action SHALL change §5.10 breaker state, Node lifecycle or health, Controller quarantine, capacity authority, or managed-profile exclusion.
This requirement makes the recovery paths in `SPEC.md` §12.2 executable.

Clear SHALL advance and reset only from `open` or `backoff` when no live worker, load pipeline, or unresolved custody exists; on a closed idle or unloaded placement it SHALL be a no-op that preserves generation and history, and on loading, loaded, reconciling, live-worker, or unresolved-custody state it SHALL fail with conflict.
Forced reload SHALL accept only an absent, exactly reconciled `open`, `backoff`, `failed`, `unloaded`, `recovery_uncertain`, or non-operation `blocked` placement; it SHALL keep desired residency unloaded during its one immediate load and set it loaded only after exact success.
Unload/reload SHALL own recovery of a loading or loaded placement or another exact live worker; it SHALL durably set desired residency unloaded and expected-stop intent before termination, then set desired residency loaded only after exact reload success.
A forced reload or unload/reload that advances recovery but does not complete its load SHALL leave the placement closed and unloaded with no automatic restoration.
That partial outcome SHALL be `applied` with a bounded failed load outcome; unresolved custody or side-effect completion SHALL remain resumable `blocked` progress and suppressed rather than claiming the closed partial outcome.
Forced reload from `recovery_uncertain` or non-operation `blocked` MUST NOT advance until exact old-process absence and absence of any in-flight side effect are proven.
An identical retry SHALL resume blocked progress only from the recorded next stage when exact reconciliation proves it safe, SHALL otherwise return the current blocked progress, and a different operation MUST conflict while that progress remains active.
After expiry, an operation that never advanced generation SHALL terminate failed with its prior recovery state unchanged; one that advanced generation SHALL start no reload, remain blocked until already-started cleanup or load custody is exact, then terminate applied as proven loaded or otherwise closed and unloaded.
A new valid operation SHALL be accepted against the resulting generation only after that terminal result is durable.
Unload/reload SHALL provide no force-cancellation option, SHALL serialize with new execution acceptance for the placement, and SHALL reject any active Request before generation advance or expected-stop intent.

#### Scenario: Operator clears an open breaker

- **WHEN** an authorized clear for the expected generation succeeds
- **THEN** Orchard advances the recovery generation, closes the crash-loop breaker, resets crash state, and sets desired residency to unloaded
- **AND** it does not launch a worker

#### Scenario: Operator forces a reload

- **WHEN** an authorized forced reload succeeds for the expected generation
- **THEN** Orchard advances the generation, fences pending work, proves exact cleanup, resets crash state, and authorizes one immediate exact-placement load
- **AND** that load bypasses only the old crash-loop latch and no other gate

#### Scenario: Unload completes but reload does not

- **WHEN** an authorized unload/reload operation proves unload but cannot complete the new load
- **THEN** the placement remains unloaded in the new generation
- **AND** a stale timer cannot resurrect it

#### Scenario: Recovery acknowledgement is lost

- **WHEN** the Node applies a recovery operation but the Controller does not receive its acknowledgement
- **THEN** the Controller reports an unknown outcome and retains suppression
- **AND** retry with the same operation ID returns the Node's durable prior result

#### Scenario: Clear targets a loaded placement

- **WHEN** an authorized clear targets a loading or loaded placement or any state with a live worker
- **THEN** Orchard returns conflict without changing recovery generation or history
- **AND** the Operator must use unload/reload for an intentional live-worker replacement

#### Scenario: Forced reload cannot complete its load

- **WHEN** forced reload advances recovery and its immediate load returns a definite failure after exact absence was proven
- **THEN** the terminal result is `applied` with the bounded failed load outcome and the placement remains closed and unloaded
- **AND** no automatic restoration starts from that partial outcome

#### Scenario: Explicit recovery targets uncertain absent custody

- **WHEN** forced reload targets an absent `recovery_uncertain` or non-operation `blocked` placement
- **THEN** it remains blocked without generation advance while exact old-process absence or in-flight side-effect completion is unresolved
- **AND** an identical retry resumes only after exact evidence proves the safe next stage

#### Scenario: Blocked cleanup resolves after command expiry

- **WHEN** an operation advanced recovery generation, began cleanup while valid, remained blocked past expiry, and later proves exact old-process absence
- **THEN** safety reconciliation records an applied closed and unloaded partial outcome without starting the expired reload
- **AND** operation-pending suppression clears so a new valid recovery operation may target the resulting generation

#### Scenario: Expiry follows stop-intent commit but precedes termination

- **WHEN** unload/reload atomically commits its new generation and exact expected-stop intent, the Node restarts before sending the first termination signal, and the command expires while the old worker remains live
- **THEN** the committed intent authorizes mandatory custody-checked termination and cleanup but no reload
- **AND** exact absence terminalizes the operation as applied, closed, and unloaded so a later valid command may proceed

#### Scenario: First preload crashes before loaded

- **WHEN** a never-before-loaded placement begins an explicit preload and its accepted startup worker generation crashes before exact load success
- **THEN** the load fails and desired residency remains unloaded
- **AND** no automatic restoration timer is authorized from the preload intent

#### Scenario: Unload/reload finds an active Request

- **WHEN** unload/reload closes new execution acceptance and finds one or more active Requests on the exact placement
- **THEN** it fails and reopens acceptance without advancing recovery generation, recording expected-stop intent, terminating the worker, or cancelling a Request
- **AND** the Operator may retry with a new valid operation only after active Requests reach zero

### Requirement: Bounded Recovery Evidence Retention

The Node Agent SHALL retain current-generation incidents inside the rolling window and SHALL retain at least the five incidents that opened a breaker until explicit recovery advances the generation.
It SHALL retain terminal recovery operation results for at least 30 days and through authenticated command expiry plus 24 hours, capped at 128 per placement without evicting an unexpired result to admit a new operation, and a bounded prior-generation watermark until the Controller acknowledges the new generation.
The Controller SHALL retain accepted worker recovery transitions and bounded opening proof for at least 30 days and cluster-scoped recovery audit events for at least 365 days.
Heartbeat rows SHALL retain their existing seven-day default and MUST NOT become the authoritative incident ledger.
This contract does not promise a complete Controller ledger of every non-opening incident after Node-local rolling evidence ages out during a partition.
This requirement adds the worker-recovery evidence classes missing from `SPEC.md` §8.5.

#### Scenario: Breaker remains open after rolling evidence ages

- **WHEN** the five opening incidents become older than ten minutes before explicit recovery
- **THEN** the Node Agent retains bounded opening evidence and the open latch
- **AND** heartbeat retention or pruning cannot clear the breaker

#### Scenario: Controller acknowledges a new generation

- **WHEN** the Controller durably acknowledges the effective recovery generation
- **THEN** the Node Agent may discard prior detailed incidents after retaining its bounded reconciliation watermark
- **AND** Controller incident and audit retention remain independently governed
