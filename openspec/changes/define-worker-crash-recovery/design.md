## Context

`Orchard.Node.ModelManager` currently owns loaded workers by `{model_id, version}`, monitors temporary `WorkerProcess` children, cleans up active requests when a worker exits, and increments one bounded cumulative counter by `model_id`.
It does not retain failed placements, schedule worker restarts, track crash timestamps, or fence recovery generations.
`WorkerSupervisor` deliberately uses temporary children, so OTP does not restart a worker outside Node Agent policy.
`WorkerProcess`, `WorkerRuntimeAdapter`, `WorkerProcessLifecycle`, and `RuntimeProcessReaper` collectively own the BEAM worker owner, provider subprocess, local channel, process identity, generation tasks, and cleanup.

The current `worker_crash_counters` projection is metrics evidence only.
It aggregates versions under a model identifier, retains at most four identifiers, changes counter version when `ModelManager` restarts, preserves no incident timestamps, and is consumed by a process-local Controller deduplicator after heartbeat persistence.
It cannot prove the §12.2 rolling window, placement identity, restart generation, durable suppression, or explicit recovery.

`Orchard.CircuitBreakers` implements a different `SPEC.md` §5.10 policy.
It persists Controller Node and catalog-model load breakers in Postgres, counts only eligible actual attempt outcomes, uses database decision time, expires suppressions after fixed durations, and generation-fences Operator clear.
The §12.2 crash-loop mechanism instead controls one exact Node-local runtime placement and has no specified automatic expiry.

Runtime Endpoint Observations are the existing authenticated path from Node-owned execution facts to durable Controller observations.
Postgres remains the Controller's durable cluster truth, while the Node Agent continues to own worker subprocesses and Node-local execution.
The design therefore uses local enforcement plus a durable Controller projection rather than transferring worker restart authority to the Controller or trusting a stale Controller snapshot at the Node.

## Goals And Non-Goals

Goals:

- Define an exact incident identity and closed eligibility table for worker crashes, including startup, replacement, intentional stop, duplicate notification, and stale-generation cases.
- Define deterministic restart delays, threshold boundary, stable reset, evidence retention, and explicit recovery reset.
- Preserve restart and breaker state across `ModelManager`, Node Agent, and host restart without restoring stale PIDs, monitor references, sockets, or timers as custody.
- Keep Node-local recovery safe during Controller partitions and keep the Controller's scheduler view safe during Node partitions.
- Serialize timer, cleanup, load, observation, and recovery-command races through one generation-fenced placement authority.
- Preserve all Request terminalization, bounded retry, §5.10 contribution, capacity, identity, and Output Commitment invariants.
- Give implementation a vertical TDD order through public seams.

Non-goals:

- Implementing the design in this PR.
- Changing §5.10 Controller breaker policy or reusing its rows as §12.2 state.
- Adding automatic Request replay, a third attempt, queue re-entry, or a new retryable failure class.
- Treating a worker RPC error, transport disconnect, request cancellation, or model acquisition error as proof of process death.
- Making ordinary heartbeat health, an elapsed suppression duration, or a successful status probe clear the crash-loop breaker.
- Defining a new managed-node host helper or importing proposed managed-profile guarantees into the portable Node Agent.

## Proposed Owner Decisions

The following choices are proposed for acceptance by this contract PR because current repository truth does not fix them.
Implementation must not begin while any row remains undecided.

| Decision | Proposed choice | Why this proposal needs owner acceptance |
| --- | --- | --- |
| Restart intent | A placement that reached `loaded` retains automatic desired residency after a crash. | §12.2 says "worker restart backoff" but does not say whether restart is automatic or demand-driven. |
| Startup eligibility | Once a worker-generation launch is durably accepted, terminal failure to spawn, become ready, or remain alive during startup counts once. | Current metrics observe only some owner exits, and §12.2 does not define startup failure. |
| Stable reset | Ten continuous minutes in `loaded` resets only the restart streak, and an open breaker has no automatic expiry. | §12.2 does not define stable operation, reset timing, or expiry behavior. |
| Durable authority | A protected Node-local store owns restart safety and a Postgres row owns the Controller projection; a capability-proven evidence-producing first load bootstraps a never-seen placement. | Existing process-lifetime counters and heartbeat rows are insufficient, and no reusable recovery store or first-load cutover is fixed by current code. |
| Recovery actions | Clear leaves the placement unloaded, forced reload repairs an exactly absent placement with one immediate load, unload/reload never force-cancels active Requests, blocked progress resumes only after exact reconciliation, and commands expire within 24 hours. | §12.2 names the actions without defining their state transitions, authorization lifetime, or partial outcomes. |
| Retention and reason | Controller-accepted transitions and bounded opening proof remain 30 days, recovery audits remain 365 days, and `worker_crash_loop_open` identifies the gate. | §8.5 has no worker-recovery evidence class, and the stable scheduler vocabulary has no crash-loop-specific reason. |

## Decisions

### D1. Recovery placement identity is the exact Node and runtime model reference

One recovery placement is keyed by `(stable node_id, model_id, version)`.
The Node Agent obtains `node_id` only from its durable Node identity and uses the exact Runtime Endpoint `ModelRef` for `model_id` and `version`.
Model name, model identifier without version, socket path, PID, target address, and Controller catalog UUID alone are insufficient.

The Node Agent must never guess a Controller catalog UUID from a runtime model string.
The Controller may link an observed recovery placement to a catalog row only through its existing exact model-resolution contract.
An unresolved or ambiguous link fails closed for Controller scheduling without reattributing evidence to another placement.

Rationale: worker residency and process custody are version-specific, while the existing metrics counter and §5.10 placement identity are not suitable recovery keys.

### D2. Worker generation is the exactly-once crash incident boundary

The recovery owner allocates a monotonic durable `worker_generation` inside the current `recovery_generation` after artifact acquisition, validation, and launch preflight succeed and immediately before the first side effect that may create the BEAM worker owner or provider process.
It also allocates an opaque non-secret incarnation and binds any BEAM owner PID, monitor reference, provider subprocess identity, service incarnation, local channel, load operation, and cleanup operation to that worker generation.
Live process identifiers remain verification evidence and are never the durable identity by themselves.

The first accepted qualifying terminal event for a worker generation records one crash incident.
Later owner exits, provider exits, socket closures, monitor messages, load-task results, cleanup completions, or duplicated transport notifications for that same worker generation do not add another incident.
Several in-flight Requests affected by one worker generation also do not add several crash incidents.

An event is stale and has no effect when its placement key, recovery generation, worker generation, operation identity, or bound live process identity does not match the current record.
Replacement always allocates a new worker generation, so a delayed exit from the replaced generation cannot count against or remove the replacement.

### D3. Crash eligibility is closed and intent-based

A qualifying crash is one of these originating terminal conditions after the recovery owner durably accepts the worker-generation launch:

- the current BEAM worker owner dies without a matching expected-stop intent;
- the exact launched provider subprocess is proven to have exited or been replaced without a matching expected-stop intent;
- BEAM owner start, executable resolution, provider spawn, or readiness fails to establish a valid live current worker, including a failure before an OS PID becomes available;
- the exact current owner or provider process dies or is replaced during startup model loading; or
- process custody becomes contradictory in a way that proves the current generation cannot remain the serving worker.

Exit status zero does not prove intent and therefore still counts when no expected-stop intent matches.
One failure that is visible through several conditions above still counts once by worker generation.

These conditions do not contribute:

- artifact lookup, acquisition, checksum, validation, or cache failure before a worker-generation launch is accepted;
- an ordinary model-load failure while the exact current worker remains live;
- Runtime Endpoint or worker RPC unavailability without proof of process loss;
- a load-task failure without proof that the current worker generation terminalized;
- intentional unload, eviction, reset, Node Agent shutdown, supervised application shutdown, or managed lifecycle stop after expected-stop intent is durably established;
- forced request cancellation, subscriber exit, request-owner loss, generation-task failure, or request cleanup that leaves the worker live;
- a duplicate notification for an already terminal worker generation; or
- an event from an older recovery generation, worker generation, process incarnation, connection, timer, or load operation.

The recovery owner classifies the originating event before any cleanup side effect with this precedence:

1. Reject an event whose explicit recovery, worker, load, timer, or connection identity is stale.
2. Exclude a current event that matches durable expected-stop intent established before termination or cleanup.
3. Count proven current owner or provider process death or replacement that preceded cleanup intent.
4. Count a launch-boundary start, spawn, or readiness failure that never established a valid live worker.
5. Exclude a readiness timeout, load RPC failure, caller or load deadline, transport-policy stop, or other failure that deliberately cleans up a still-live current process.
6. Treat absence whose cause and ordering cannot be proven as `recovery_uncertain`, block replacement, and require reconciliation or explicit recovery without adding a crash.

An expected-stop intent must name the exact placement, recovery generation, worker generation, operation identity, and reason before termination begins.
A generic `normal` exit reason, missing monitor record, or later inference about operator intent cannot retroactively suppress a crash.
A notification that explicitly names an obsolete generation is stale and ignored.
A current-generation custody check that proves the bound process was replaced is a qualifying incident rather than a stale event.

An eligible worker incident may also cause one or more actual Request attempt outcomes.
Each actual attempt remains solely responsible for its own §5.10 contribution under the existing stable failure taxonomy.
The worker incident, restart timer, recovery decision, and affected-request fan-out never manufacture §5.10 contributions.

### D4. Rolling threshold and restart streak are separate state

The crash-loop window contains distinct current-recovery-generation incidents whose Node-local accepted occurrence times are in `(t - 600 seconds, t]` for the incident accepted at time `t`.
An incident exactly 600 seconds before `t` is outside the window.
The fifth incident inside the window atomically marks the placement failed and opens its crash-loop breaker.
Fewer incidents, incidents outside the window, incidents for another model version, and incidents on another Node do not open it.

The restart streak counts qualifying incidents since the last stable-operation reset or effective explicit recovery.
After streak incident `n`, the earliest replacement delay is 1, 2, 4, 8, 16, 30, 30 seconds and remains capped at 30 seconds.
The delay is measured from the durable acceptance of the incident.
No jitter is added by this contract.

The fifth rapid incident opens the breaker and schedules no automatic replacement, so its computed 16-second step is retained as evidence but not armed.
The 16-second and 30-second steps remain observable when incidents are far enough apart that fewer than five remain inside the rolling window while the restart streak has not yet reset.

Cleanup completion, exact-process absence, desired residency, generation currency, and a closed breaker are additional start gates.
Passing the delay alone never authorizes a replacement.

### D5. Stable operation resets backoff without clearing an open breaker

Stable operation is ten continuous minutes in `loaded` for the exact current worker generation with no qualifying crash, proven process loss, or transition out of loaded state.
Loading, cached, failed, absent, or unknown time does not accumulate toward stability.
A new load, status response, heartbeat, or idle period does not reset the streak by itself.

When the stable interval completes in a closed recovery generation, the restart streak resets to zero.
Rolling crash incidents expire only through the half-open window rule.
Cumulative worker-crash metrics do not reset.

Stable operation never closes an open crash-loop breaker.
Window expiry never closes an open crash-loop breaker.
There is no automatic crash-loop breaker expiry.

### D6. The Node Agent owns a durable recovery record and live timer authority

The Node Agent keeps one versioned protected recovery record per recovery placement.
The record contains:

- placement identity;
- recovery generation;
- desired residency;
- exact last successfully loaded artifact digest and canonical cache binding when desired residency is loaded;
- current and last terminal worker generation;
- current recovery phase;
- monotonically increasing durable state sequence;
- closed or open crash-loop breaker state;
- restart streak;
- bounded qualifying crash occurrence identities and times;
- earliest restart deadline when one exists;
- stable-operation start when one exists;
- bounded recovery operation journal with payload binding, progress, and terminal results; and
- a wall-clock high-water mark used to prevent rollback from expiring evidence or shortening a wait.

The current recovery phase is one of `idle`, `loading`, `loaded`, `reconciling`, `backoff`, `failed`, `blocked`, `recovery_uncertain`, or `unloaded`.
PIDs, monitor references, timer references, ports, sockets, and live connection handles are process-local and are not restored as custody after restart.

The store is versioned, bounded, checksummed, written atomically, and protected with the same owner-only posture as other Node Agent state.
Its concrete encoding and path are implementation details, but it must live outside replaceable worker processes and must not enter Runtime Endpoint diagnostics, support bundles, or logs as a raw local path.

A crash transition is durable before a replacement is authorized.
An open transition is durable before any result can report it.
An effective recovery generation change is durable before a replacement or ordinary load is authorized in that generation.
If the record cannot be read, validated, or written after a placement record has been established, new worker starts for that placement fail closed while safe cleanup and existing Request terminalization continue.
An unknown newer store schema must never be treated as an empty healthy state.

Every durable transition increments the state sequence before observation.
The exact last successfully loaded artifact binding is retained when desired residency is loaded and cleared only by an effective unload or superseding verified load.

Live timers use an injected monotonic clock and timer implementation.
Persisted occurrence and deadline evidence uses bounded UTC values, a boot-session identifier, boot-continuous elapsed-time evidence when the platform can provide it, and the stored wall-clock high-water mark because VM monotonic values cannot be restored blindly.
After restart, only a trusted non-decreasing elapsed source may reduce a remaining delay or prune rolling evidence.
When elapsed time cannot be proven, Orchard rearms the full applicable delay from recovery-owner startup and conservatively retains rolling evidence.
Clock rollback, forward jump, or uncertainty therefore cannot make a restart earlier or clear suppression.

Before an orderly Node Agent or supervisor-driven worker stop, the recovery authority persists exact expected-stop intent for every affected current worker generation.
The recovery authority must survive long enough across a `ModelManager` failure to classify or pre-record the resulting `:rest_for_one` worker teardown, whether through supervisor ordering or an equivalent dedicated owner.
An interrupted launch or a previously loaded generation found absent after restart is reconciled from durable intent and custody evidence.
If neither expected stop nor qualifying process death can be proven, the placement enters `recovery_uncertain`, authorizes no replacement, and requires explicit recovery.
An incident whose process loss was proven but whose transition had not committed is committed once during reconciliation before any replacement.

### D7. Desired residency controls automatic restoration

A placement that successfully reaches `loaded` sets desired residency to `loaded`.
An eligible crash retains that intent and permits one automatic Node-local residency restoration after the current backoff and cleanup gates pass.
Automatic restoration uses the exact model reference and durable previously verified artifact binding retained by the recovery record.
It does not rerun artifact selection from untrusted crash evidence.

Automatic restoration is Node-owned residency maintenance, not a Controller scheduling decision, dispatch permit, §5.10 contribution, or authorization to serve new work.
The Node Agent evaluates only its local recovery generation, breaker, process custody, artifact validity, and Node-owned resource limits.
It does not claim to evaluate Controller lifecycle, trust, quarantine, allocation, dispatch ceiling, or §5.10 state while partitioned.
Every later Controller load or inference path must still pass current Controller-owned gates, and final execution authorization must observe a current closed crash-loop projection.

A startup crash during an explicit load fails the existing load operation and its valid waiters through the existing deadline and failure contract.
It does not create durable desired residency unless that placement had already reached `loaded` in the current or a retained prior generation.
A first-ever preload or recovery load remains desired `unloaded` until exact load success, so a startup crash before that boundary creates no automatic restoration authority.

A non-crash local restoration failure stops that restoration attempt and remains local recovery evidence.
It does not start an undocumented retry loop.
It creates no §5.10 contribution because no Request attempt produced it.
Later demand remains subject to the retained backoff and crash-loop state.

Intentional unload sets desired residency to `unloaded` and invalidates pending restart authority before termination begins.
Automatic eviction has the same no-restart effect but does not clear crash history or an open breaker.

### D8. Timer, cleanup, load, and restart messages are generation-fenced

Every timer and asynchronous completion carries the placement key, recovery generation, worker generation or load-operation identity, and expected phase.
Before acting, the recovery owner rechecks all identities, desired residency, breaker state, current phase, earliest deadline, load ownership, and exact old-process cleanup.
At most one replacement pipeline may exist for a placement in one recovery generation.

Cancelling a timer is best effort because its message may already be queued.
Changing the recovery generation or desired residency makes the queued message harmless.
A stale timer cannot create a worker, change placement state, or alter crash history.

No new worker starts until the exact previous BEAM owner, provider subprocess, and local socket or channel are absent or safely reconciled under existing custody rules.
Unresolved custody leaves the placement blocked and does not spend another backoff step.

An external load arriving during backoff or reconciliation may join the matching current single-flight operation or wait only within its existing deadline.
It cannot start a parallel worker, shorten backoff, clear suppression, or replace a conflicting artifact fingerprint.
A late load completion cannot publish loaded state unless the exact current recovery generation, load operation, worker generation, live process identity, and desired residency still match.
Otherwise the implementation cleans up the stale worker and leaves current state unchanged.

### D9. Runtime Endpoint recovery evidence is separate from metrics counters

The Runtime Endpoint Observation gains a bounded additive `worker_recovery_placements` collection.
Each entry contains the exact model reference, recovery generation, current phase, desired residency, breaker state, restart streak, bounded in-window crash count, current worker generation when present, earliest restart time when present, state sequence, and the last effective recovery operation identity or bounded hash needed for reconciliation.
It contains no PID, monitor reference, socket path, local filesystem path, raw exit reason, Request identity, prompt or response content, secret, or unbounded diagnostic term.

The existing `worker_crash_counters` remain process-lifetime cumulative metrics input.
They are not enriched, backfilled, or treated as recovery authority.
The existing ordinary placement state and capacity fields also remain distinct from recovery-generation evidence.

Each recovery entry carries up to five distinct current-window incident identities and Node-local occurrence times.
An open entry carries the exact five-incident proof that opened the breaker even after those incidents leave the rolling window, until explicit recovery advances the generation.
This bounded proof permits idempotent Controller persistence and operator explanation without turning observations into an unbounded incident ledger.

Both BEAM-first and gRPC compatibility mappings decode the additive evidence into the same provider-neutral representation.
An older endpoint that omits it proves no crash-loop state.
Once the Controller has established that a Node must support this contract, missing, malformed, duplicate, stale, regressed, or identity-mismatched evidence fails closed for loading and dispatch on the affected placement.
Mixed-version capability negotiation and enforcement cutover must be explicit in the implementing design rather than inferred from successful decoding.

For an exact placement with no Controller projection, the active Controller may treat the placement as a provisional cold candidate only after authenticated capability negotiation proves this contract for the Node and exact target and every ordinary identity, lifecycle, trust, policy, model, resource, queue, and capacity gate passes.
The missing recovery projection is the sole waived candidate fact.
The provisional candidate participates in normal tiering, ranking, and scoring, and a Request-selected bootstrap retains the ordinary request-step start, attempt identity, absolute deadline, Controller allocation, and release-before-retry ordering before the Controller requests an evidence-producing `EnsureModelLoaded`.
The Node Agent honors first-load initialization only when no prior local record exists; an existing record instead returns its authoritative current evidence or a fail-closed error and is never overwritten as empty.
Before the first worker-creation side effect for a never-seen placement, the Node Agent creates and commits the initial closed recovery record and worker generation.
The load result returns the exact recovery generation, state sequence, worker generation, and current recovery evidence.
The Controller must commit that evidence before it treats the load as complete for scheduling or calls `ExecuteInference`.
This exception applies only to a provably never-seen placement; missing evidence for an established, previously projected, open, or capability-unknown placement fails closed.
Bootstrap initialization refusal or persistence failure is a typed recovery-only refusal under D10, not an untracked model-load failure.

### D10. The Controller owns a durable projection and cluster enforcement

The active Controller persists current crash-loop state, accepted transition evidence, and bounded opening proof in Postgres under the canonical Node and exactly resolved runtime placement identity.
It accepts only authenticated, scheduler-fresh Runtime Endpoint observations whose Node and target identity match durable admitted inventory.
Observation state sequence must advance monotonically inside one recovery generation.
The first closed baseline may be accepted only from the evidence-producing bootstrap result or a scheduler-fresh observation after the mixed-version enforcement contract proves support and no prior projection exists.
After a projection exists, a closed state in a newer recovery generation is accepted only when it reconciles to the matching Controller-issued recovery operation.

The Controller does not recompute the Node-local five-in-ten window from heartbeat receipt time.
It mirrors the Node Agent's authoritative transition and persists state sequence plus bounded opening proof to reject duplicate or regressed delivery and explain an open transition.
It never reconstructs state from Prometheus counters, logs, Request outcomes, §5.10 failure rows, or heartbeat deltas.

An open crash-loop projection marks the placement failed and rejects it before tiering, ranking, scoring, load reconciliation, or `EnsureModelLoaded` with stable reason `worker_crash_loop_open`.
Missing or unavailable recovery authority also fails closed, except for the exact capability-proven evidence-producing first-load protocol above.
Final dispatch authorization rechecks the projection after any load and before `ExecuteInference`.
Unlike the §5.10 model-load breaker, a crash-loop-open placement cannot remain dispatchable merely because a stale observation says it was loaded.

Controller or leadership restart reads the Postgres projection and remains suppressed until new authoritative recovery evidence proves a matching effective recovery.
Database unavailability or unresolved placement identity fails closed without falsely claiming a breaker transition.
An observation write failure cannot update the scheduler view in memory as though it committed.

During a Controller-to-Node partition, the Node Agent keeps enforcing local backoff and its open latch.
The Controller excludes the Node through existing observation freshness once the heartbeat threshold passes.
Before that threshold, a Node-local rejection still prevents load or execution from bypassing local state.
Reconnection refreshes evidence and does not clear or reconstruct recovery authority.

A Node-local refusal caused solely by recovery state uses a distinct typed `WorkerRecoveryRefusal` outcome for `EnsureModelLoaded` and any pre-acceptance `ExecuteInference` rejection.
It never populates `ModelLoadFailure`, never asserts runtime retryability, and maps as follows after `request_step.started`:

| Recovery refusal | Attempt failure class | Stable request code | Retry decision on attempt 1 |
| --- | --- | --- | --- |
| `worker_crash_loop_open`, `worker_recovery_backoff`, `worker_recovery_operation_pending` | `capacity_rejection` | `model_busy` | `not_retryable` |
| `worker_recovery_custody_unresolved` | `occupancy_unresolved` | `internal_error` | `occupancy_unresolved` |
| `worker_recovery_authority_unavailable` | `runtime_failure` | `internal_error` | `not_retryable` |

Before `request_step.started`, the same state is only candidate rejection evidence and produces no attempt outcome.
After attempt start, the Controller records `execution_resolution = not_started`, releases its allocation effectively once, applies the table without queue re-entry, and preserves the existing attempt-2 `retry_exhausted` rule.
None of these recovery-only refusals contributes to a §5.10 breaker.
A genuine acquisition, worker launch, model load, or post-acceptance runtime failure remains governed by its existing typed outcome and is not reclassified merely because recovery state also exists.

### D11. Recovery operations use Controller authorization and two-sided reconciliation

The Controller exposes separate worker crash-loop operations under:

- `GET /ops/v1/worker-crash-recovery/placements/:node_id` with the exact `model_id` and `version` as encoded query parameters;
- `POST /ops/v1/worker-crash-recovery/placements/:node_id/clear`;
- `POST /ops/v1/worker-crash-recovery/placements/:node_id/force-reload`; and
- `POST /ops/v1/worker-crash-recovery/placements/:node_id/unload-reload`.

Each mutation body carries the exact `model_id` and `version` because Runtime Endpoint identifiers may contain path separators and cannot be safely split into route segments.

Each mutation requires cluster-scoped `operator` or `admin` authority, active-leader write authorization, a non-empty bounded reason, an opaque operation ID, the exact target, the expected recovery generation, and the action.
Inspection and mutation responses are bounded and use `Cache-Control: no-store`.
Tenant-direct and public inference credentials fail closed without revealing state.

The Controller durably records command intent before delivery.
The Node Agent serializes commands with local recovery transitions and stores a bounded operation journal keyed by operation ID.
Each entry binds a canonical payload hash, target, action, actor reference, reason, expected recovery generation, reserved next recovery generation when applicable, and every resulting recovery generation and state sequence.
The journal progresses through `accepted`, `stopping`, `stopped`, `loading`, and `blocked` as applicable before the corresponding side effect or reconciliation, then terminates as `applied` or `failed` with a bounded result.
Every progress change is durable before its side effect, so restart resumes or reconciles the recorded stage instead of repeating an unrecorded action.
`failed` before an effective generation advance preserves the prior recovery state.
After a generation advances, an unsuccessful reload is an `applied` reset with a bounded failed `load_outcome`, while unresolved custody or side-effect completion remains resumable `blocked` progress and keeps independent suppression in force.
The Controller commits the reconciled result and cluster-scoped audit evidence after it obtains the matching Node result.
There is no claimed atomic transaction across Postgres and Node-local storage.

A delivery timeout or lost acknowledgement leaves the Controller outcome `unknown` and keeps suppression in force.
The Controller retries only with the same operation ID.
The Node Agent checks an existing operation ID and its payload binding before evaluating expected generation, returns the retained progress or terminal result for an identical retry, rejects conflicting operation-ID reuse, and rejects a stale expected generation for a new operation without mutation.
Two different operations for the same expected generation serialize, and only the first effective operation may advance the generation.
The Controller treats non-terminal command intent as a separate suppression source.
A delayed result may update the Controller only when its operation ID, recovery generation, and state sequence match or advance the pending record; it cannot roll back a newer projection or clear a newer suppression.
An identical retry of `blocked` re-evaluates only the unresolved evidence and resumes the recorded next stage when that evidence becomes conclusive.
It does not repeat a side effect whose preceding or completed progress is durable.
A different operation conflicts while blocked progress remains active.

The action transition contract is:

| Action | Accepted breaker or phase state | Effective transition | Non-success behavior |
| --- | --- | --- | --- |
| Clear | `open` or `backoff`, with no live worker, load pipeline, or unresolved custody | Advance the recovery generation, close the latch, reset streak and rolling evidence, set desired residency to `unloaded`, cancel timers, and perform no load. | A closed `idle` or `unloaded` placement is an idempotent no-op that preserves generation and history; `loading`, `loaded`, `reconciling`, live-worker, or unresolved-custody state returns conflict without mutation. |
| Forced reload | `open`, `backoff`, `failed`, `unloaded`, `recovery_uncertain`, or non-operation `blocked`, with no live worker and exact absence proven before reset | Advance the recovery generation, reset crash state, keep desired residency `unloaded` while one immediate load runs, and set it to `loaded` only after exact load success. | A load failure after advance returns `applied` with a failed load outcome and leaves the placement closed and unloaded with no automatic restoration; unresolved custody records resumable `blocked` progress without advancing or clearing suppression; live or loading state directs the Operator to unload/reload. |
| Unload/reload | `loading`, `loaded`, or another state with a live current worker whose custody is exact | Advance the recovery generation, persist expected-stop intent, set desired residency to `unloaded`, cancel pending work, prove cleanup, then perform one load under normal gates and set desired residency to `loaded` only on success. | A load failure after proven unload returns `applied` with a failed load outcome and leaves the placement closed and unloaded with no automatic restoration; unresolved cleanup remains `blocked` and suppressed; failure before a durable generation advance leaves the prior state effective. |

An identical retry is governed by operation ID rather than re-evaluating this table.
No action reports `applied` until every state change and the bounded terminal result are durable.
For `recovery_uncertain` or non-operation `blocked`, forced reload is the explicit repair path, but it cannot advance until exact old-process absence and absence of any in-flight side effect are proven.

Every command carries Controller-authenticated `issued_at` and `expires_at` values with a maximum 24-hour validity interval.
Both authorities reject a first delivery after expiry, and the Node Agent also rejects when its durable wall-clock high-water evidence cannot prove that current time remains inside the interval.
Expiry forbids a recorded operation from starting any next discretionary stop or load side effect, but it does not forbid read-only result retrieval or mandatory safety reconciliation of a side effect already started before expiry.
For unload/reload, the effective recovery-generation advance and exact expected-stop intent commit atomically after the active-Request check and while new execution acceptance remains closed.
That durable intent is the authorization boundary for mandatory custody-checked termination and cleanup even if expiry or restart occurs before the first termination signal; it never authorizes the expired reload.
An expired operation that never advanced recovery generation terminates `failed` and releases operation-pending suppression while leaving its prior recovery state effective.
An expired operation that advanced generation continues only exact cleanup and custody reconciliation under its recorded stage, starts no reload, and terminates `applied` as loaded only if the already-started load is proven current and successful or otherwise as closed and unloaded after exact absence is proven.
Until that proof exists it remains `blocked`, and all suppression remains effective.
Once expiry reconciliation reaches a durable terminal result, a new authorized operation may proceed against the resulting generation.
Terminal results are retained for at least 30 days and through `expires_at` plus 24 hours.
An evicted operation ID is therefore already expired and can never become a new command, including after a no-op or failure that did not advance recovery generation.

Forced reload follows the absent-worker row above and authorizes exactly one immediate load for the exact placement.
The forced load bypasses only the old crash-loop latch.
It does not bypass artifact verification, Node lifecycle, health, trust, capacity, §5.10, quarantine, managed-profile exclusion, deadline, or identity gates.
A crash in the new forced-reload generation is its first crash and follows the 1-second step.

Unload/reload is one explicit recovery operation rather than an accidental consequence of ordinary eviction and follows the live-worker row above.
If the unload completes but reload does not, the placement remains unloaded in the new generation and no automatic timer resurrects it.
It provides no force-cancellation option.
The Node Agent serializes unload/reload with new execution acceptance for the exact placement, closes new acceptance, and checks active requests before atomically advancing generation with expected-stop intent.
If any Request remains active, the operation fails without generation or worker mutation and reopens acceptance; otherwise the operation proceeds under the same held gate through durable stop intent.

An ordinary load never clears an open crash-loop breaker.
An ordinary unload or eviction never clears crash evidence or an open breaker.
A §5.10 clear never changes §12.2 state, and a §12.2 recovery never changes §5.10 state.
No recovery operation changes Node lifecycle, health, Controller quarantine, capacity authority, or managed-profile exclusion.

### D12. Request handling and §5.10 attribution remain independent

Worker recovery may notify the current Runtime Endpoint request owner once that the exact worker generation failed.
It does not decide whether the logical Request retries and does not replay request bytes, generation parameters, stream events, or tool calls.

The Controller remains the sole retry owner.
Attempt 2 remains allowed only before Output Commitment and after caller liveness, absolute deadline, stable failure classification, first-Node identity, execution resolution, affirmative capacity release, and different-Node eligibility all pass.
It remains limited to one alternate attempt.

Each actually run unsuccessful attempt contributes at most once to one §5.10 breaker only through its durable stable attempt outcome.
Several request failures caused by one worker crash may each be real attempt outcomes, but the crash incident itself adds none.
Restart, stable reset, explicit recovery, timer expiry, observation, retry decision, declined retry, and missing recovery evidence add no §5.10 contribution.

## Persistence And Retention

The Node Agent retains all distinct current-generation crash incidents still inside the ten-minute window.
When the breaker is open, it retains at least the five incidents that proved the opening transition until an explicit recovery advances the generation.
It retains terminal recovery operation results for at least 30 days and through authenticated command expiry plus 24 hours, capped at 128 per placement, and a bounded prior-generation watermark until the Controller acknowledges the new generation.
It never evicts a result still inside that retry horizon to admit a new command; when the cap is full, it rejects the new operation before mutation until an eligible terminal result ages out.
It may then discard prior detailed local incidents because the Controller owns durable cluster evidence.

The Controller retains current crash-loop projection rows while their Node or retained model identity remains operationally addressable.
It retains accepted transition evidence and the bounded proof of each opening transition for at least 30 days, matching the current request-event default, and retains cluster-scoped recovery audit events for at least 365 days under `SPEC.md` §8.5.
Heartbeat payloads continue to follow their existing seven-day retention and are not the authoritative incident ledger.
Raw process diagnostics and provider exit terms are excluded from these stores.

Non-opening incident detail may age out at the Node during a long partition once it leaves the rolling window.
The durable current state, monotonic state sequence, in-window count, and retained opening proof remain sufficient enforcement authority; this contract does not promise a complete 30-day Controller ledger of every non-opening incident.

These retention values and the new evidence classes are genuine `SPEC.md` clarifications and must be added to §8.5 in the implementing change.

## SPEC.md Clarifications Required Before Implementation Completion

The implementing change must update `SPEC.md` without altering the accepted §5.10 policy.
The required clarifications are:

1. §12.2 must define the worker-generation crash incident boundary and the closed inclusion and exclusion table.
2. §12.2 must define `(t - 600 seconds, t]`, the independent restart streak, no jitter, the exact sequence, and the fifth-crash open behavior.
3. §12.2 must define automatic desired-residency restoration, ten-minute stable reset, explicit recovery reset, and no automatic breaker expiry.
4. §§4.6.1 and 12.2 must define separate bounded recovery evidence, capability-proven provisional first-load bootstrap, and preserve `worker_crash_counters` as metrics-only.
5. §§3.7.1, 5.5, 5.8 through 5.10, 6.8, and 12.2 must define `worker_crash_loop_open`, typed recovery-only refusal mappings, load and final-authorization enforcement, and the difference from `model_load_suppressed`.
6. §§5.8 through 5.10 and 12.7 must state that worker recovery does not replay Requests or create §5.10 contributions.
7. §§6.8, 7.3, and 12.2 must define the Controller-owned recovery operations, active-Request rejection, authorization lifetime, resumable blocked progress, idempotency, unknown outcomes, and audit.
8. §8.5 must define accepted transition, opening-proof, projection, command-result, and audit retention.

## Rejected Alternatives

### Reuse `Orchard.CircuitBreakers`

Rejected because §5.10 uses catalog-model identity, eligible actual attempt failures, database decision time, different thresholds, different effects, timed expiry, and a different clear path.
Sharing low-level serialization helpers is acceptable only if policy types, tables, APIs, reason codes, counters, generations, and mutations remain explicit and separate.

### Use `worker_crash_counters` as authority

Rejected because those counters aggregate model versions, retain no occurrence times, reset with the ModelManager process, and feed best-effort metrics after heartbeat commit.
They remain useful only for the existing cumulative metric.

### Let OTP restart temporary workers

Rejected because a supervisor restart would bypass durable crash acceptance, backoff, cleanup proof, desired residency, open suppression, and recovery generation fencing.

### Make the Controller own worker restart timers

Rejected because the Controller cannot prove local process cleanup during a partition and should not manage provider subprocesses directly.
The Controller owns authorization, durable cluster projection, and scheduler enforcement instead.

### Keep all recovery state process-local

Rejected because a ModelManager, Node Agent, or host restart would erase backoff and reopen a crash loop.
Treating a missing old process as recovery would also let an open breaker disappear.

### Clear on healthy observation or elapsed time

Rejected because §12.2 names explicit recovery paths and defines no suppression duration.
Health, loadedness, and crash-loop recovery are independent facts.

### Let ordinary unload or eviction clear the breaker

Rejected because automatic eviction or routine cleanup would become an unaudited recovery bypass.
Only a Controller-authorized recovery operation may advance the recovery generation and reset crash state.

### Replay in-flight Requests from the Node Agent

Rejected because the Node Agent cannot prove Output Commitment, Controller attempt identity, caller liveness, logical deadline, different-Node exclusion, or Controller-owned capacity release.
Layered replay would violate the at-most-once retry contract.

## Risks And Trade-Offs

- A Node-local durable store adds a new compatibility and corruption boundary.
The design fails closed for established placements, requires a versioned schema, and forbids downgrade from treating unknown state as empty.
- Two durable authorities cannot commit atomically across a partition.
The operation protocol uses intent, generation, idempotent Node result, and explicit unknown outcome instead of claiming distributed atomicity.
- Automatic residency restoration consumes resources after a crash.
The proposal limits Node-local restoration to prior desired residency, one generation-fenced pipeline, exact artifact binding, local custody, and Node-owned resource gates, and grants no Controller or serving authority.
- Startup classification can overlap a Request-visible model-load failure.
The domains remain separate: one worker generation contributes at most one local incident, and only the actual attempt outcome may contribute to §5.10.
- Runtime model reference and catalog identity can diverge.
The Controller must resolve them exactly or fail closed, never guess.
- Clock uncertainty can delay recovery or retain evidence longer than ten minutes.
That conservative availability cost is preferable to early restart or accidental breaker clearance.

## Vertical TDD Delivery Plan

Implementation proceeds one public red-green slice at a time.
Each slice uses injected clocks and timers for policy tests, then preserves or adds a real process or transport test where custody or normalization is material.

1. First public recovery seam: load an exact placement through the Runtime Endpoint, terminate its exact current worker, durably record one incident, wait a deterministic 1-second step, and observe exactly one replacement with no request replay.
2. Recovery policy matrix: prove incident deduplication, full inclusion and exclusion, exact lower boundary, delay sequence and cap, fifth-crash open, version and Node isolation, stable reset, and no automatic expiry.
3. Durable recovery-owner seam: persist before side effects, reconstruct after owner and Agent restart, prove operation-progress and timer restoration, cleanup-before-replacement, corruption and write-failure fail-closed behavior, and clock rollback conservatism.
4. Node Agent lifecycle and load reconciliation seam: cover startup death, intentional stop, duplicate and stale events, one automatic restoration for desired residency, single-flight joining, pending-timer cancellation, late load cleanup, forced unload behavior, and no second worker under concurrent events.
5. Runtime Endpoint evidence seam: prove bounded additive evidence, evidence-producing first-load bootstrap, both BEAM and compatibility mappings, authenticated persistence, stale or malformed rejection, failed-placement visibility with no live worker, and unchanged metrics-counter behavior.
6. Controller enforcement seam: prove candidate, cold or warm load, reconciliation, and final authorization reject `worker_crash_loop_open` while §5.10 Node and model-load breakers retain their independent behavior.
7. Operator recovery seam: prove the transition table, authorization, audit, exact target, expected generation, durable progress, retained result, cap refusal, duplicate ID, conflicting reuse, concurrent operations, stale generation, lost acknowledgement, and idempotent retry.
8. Request-separation seam: kill a real worker before and after Output Commitment and prove existing execution-resolution, identity, deadline, capacity-release, at-most-once retry, per-attempt §5.10 attribution, and no Node-local replay.

## First Implementation Slice

The first implementation PR should deliver the smallest vertical recovery path through the public Runtime Endpoint seam.
A test loads one exact placement, terminates the bound current worker, observes one failed placement and one durable incident, advances an injected timer by the deterministic 1-second first step, and observes exactly one replacement generation.
The slice includes only the minimum policy transition, protected record, custody binding, timer injection, and observation fields needed for that path, plus proof that duplicate terminal notifications do not count and no request content is replayed.
The broader pure-policy matrix, startup classification, persistence fault matrix, Controller projection, scheduler enforcement, and Operator actions follow as later red-green slices.
