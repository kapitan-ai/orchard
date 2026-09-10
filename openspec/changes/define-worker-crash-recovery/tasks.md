## 1. Contract Approval And SPEC Reconciliation

- [ ] 1.1 Obtain owner acceptance or replacement of the six proposed decisions: automatic desired residency, startup-failure eligibility, ten-minute stable reset plus no automatic expiry, split Node-local plus Controller durable authority with first-load and mixed-version bootstrap, exact recovery-action semantics, and retention plus stable reason-code policy.
- [ ] 1.2 Reconcile accepted crash identity, timing, reset, persistence, recovery, retention, and no-expiry behavior into `SPEC.md` §§4.6.1, 5.5, 5.8 through 5.10, 6.8, 7.3, 8.5, 12.2, and 12.7 before implementation completion.
- [ ] 1.3 Add or update a durable decision under `docs/decisions/**` for the accepted ownership, persistence, mixed-version bootstrap, and recovery-command architecture before implementation completion.
- [ ] 1.4 Keep §5.10 Node and model-load breaker policy, reason codes, expiry, clear, and per-attempt contribution ownership unchanged.

## 2. First Public Worker Recovery Slice

- [ ] 2.1 Write one failing public Runtime Endpoint test that loads an exact placement, terminates its bound current worker, observes one failed placement and one durable incident, advances an injected timer by one second, and observes exactly one replacement generation.
- [ ] 2.2 Implement only the minimum side-effect-free policy transition, protected recovery record, worker-generation custody binding, timer injection, and observation fields required by that public path.
- [ ] 2.3 Prove duplicate owner, provider, cleanup, and transport terminal notifications for the killed generation do not add an incident or create another replacement.
- [ ] 2.4 Prove affected Requests terminalize through the existing path and the replacement does not replay Request content, stream events, generation parameters, or tools.

## 3. Durable Node Agent Recovery Authority Slice

- [ ] 3.1 Write failing policy tests for the complete eligibility matrix, exact rolling boundary, delay sequence and cap, fifth-crash opening, version and Node isolation, stable reset, no automatic expiry, and first-preload startup failure without desired residency; write failing storage tests for atomic persistence before launch, versioned decoding, checksum or schema rejection, missing-established-state handling, write failure, clock rollback, current-generation reconstruction, and bounded history retention.
- [ ] 3.2 Add one protected Node-local recovery store outside worker processes, with injected storage and clock seams and no raw path or provider failure term in logs or observations.
- [ ] 3.3 Write failing restart tests proving that ModelManager, Node Agent, and host-style recovery cannot erase an open breaker, shorten a pending deadline, restore a PID or monitor as custody, or launch before exact old-process absence.
- [ ] 3.4 Add one serialized per-placement recovery owner that reconstructs policy state, reconciles live custody, and fails new starts closed when established state is unavailable or corrupt.

## 4. Worker Lifecycle And Load Reconciliation Slice

- [ ] 4.1 Write failing public Runtime Endpoint tests that load a worker, terminate its exact current owner or provider during startup and loaded operation, and observe one failed placement, one crash incident, affected-request terminal delivery, and no duplicate count.
- [ ] 4.2 Bind owner PID, provider process identity, service incarnation, adapter connection, load operation, expected-stop intent, and cleanup to the current worker generation.
- [ ] 4.3 Write failing deterministic timer tests for no early restart, one replacement at eligibility, queued stale timer rejection, pending timer cancellation, and no automatic replacement after the breaker opens or desired residency becomes unloaded.
- [ ] 4.4 Implement automatic restoration only for accepted desired residency and only after persistence, current-generation, cleanup, breaker, exact artifact binding, and Node-owned resource gates pass, without granting Controller or serving authority.
- [ ] 4.5 Write failing race tests for worker exit versus load result, late successful load after unload or replacement, single-flight demand during backoff, forced request cleanup, slow reaper completion, and concurrent recovery triggers.
- [ ] 4.6 Make loaded publication require the exact current recovery generation, load operation, worker generation, live process identity, desired residency, and closed breaker.

## 5. Runtime Endpoint Evidence Slice

- [ ] 5.1 Write failing provider-neutral tests for bounded `worker_recovery_placements` evidence, exact model reference, generation and state sequence, current-window and opening proof, failed placement without a worker, malformed or duplicate entries, provisional-candidate evidence-producing first-load bootstrap under normal attempt and allocation ordering, and omission by an older endpoint.
- [ ] 5.2 Add the additive shared Runtime Endpoint representation and BEAM mapping without changing `worker_crash_counters`, ordinary placement capacity, readiness, or health semantics.
- [ ] 5.3 Extend the gRPC compatibility schema, generated bindings, descriptor golden, and reciprocal fixtures through the repository-owned generation workflow.
- [ ] 5.4 Write failing authenticated observation tests for exact Node identity, exact catalog resolution, monotonic generation and sequence, stale or out-of-order delivery, missing evidence after enforcement cutover, persistence failure, and unchanged metrics baselining.
- [ ] 5.5 Persist the Controller projection, accepted transitions, and bounded opening proof in Postgres without reconstructing them from metrics, §5.10 rows, Requests, logs, or heartbeat deltas.
- [ ] 5.6 Define and test the mixed-version capability and enforcement cutover so an older Node Agent cannot be silently treated as a closed healthy recovery placement.
- [ ] 5.7 Add typed recovery-only refusal outcomes for open, backoff, pending-operation, unresolved-custody, and unavailable-authority state; prove their closed attempt mappings, effective-once capacity release, non-retryability, public codes, and zero §5.10 contribution without populating `ModelLoadFailure`.

## 6. Controller Scheduling And Breaker Separation Slice

- [ ] 6.1 Write failing scheduler tests proving `worker_crash_loop_open` rejects only the exact Node, model, and version before tiering, ranking, scoring, cold or warm loading, and load reconciliation.
- [ ] 6.2 Add the durable crash-loop projection to candidate selection and queue-source clearing without reusing `Orchard.CircuitBreakers` policy rows or failure contributions.
- [ ] 6.3 Write failing final-authorization tests proving a breaker that opens or becomes unknown after load blocks `ExecuteInference` and releases Controller capacity effectively once.
- [ ] 6.4 Preserve separately valid §5.10 behavior: Node suppression, model-load suppression with already-loaded dispatch, timed expiry, clear, failure eligibility, and one-breaker-per-attempt attribution.
- [ ] 6.5 Add regression tests proving crash incidents, restart timers, observations, stable reset, explicit recovery, retry decisions, and declined restarts contribute nothing to §5.10.

## 7. Explicit Operator Recovery Slice

- [ ] 7.1 Write failing Controller domain and API tests for inspection, clear, forced reload, and unload/reload with Operator or admin authorization, active-leader enforcement, exact target and version, expected generation, operation ID, bounded reason, `Cache-Control: no-store`, and tenant credential denial.
- [ ] 7.2 Add durable Controller command intent, bounded unknown outcome, reconciled result, and cluster-scoped audit evidence without claiming a transaction across Postgres and Node-local storage.
- [ ] 7.3 Write failing Node Agent operation tests for durable progress before each side effect, restart and same-ID resumption from every progress state including `blocked`, operation-ID lookup before expected-generation validation, identical retry, conflicting operation-ID reuse, stale expected generation, authenticated command expiry, no-op replay after result expiry, pre-advance expiry, restart and expiry between atomic stop-intent commit and the first termination signal, post-advance cleanup and load reconciliation after expiry with no expired reload, subsequent-command admission after terminalization, concurrent commands, one effective generation advance, delayed old-generation evidence, 30-day result retention, and 128-result cap refusal.
- [ ] 7.4 Implement the exact clear transition table: reset only an absent open or backoff placement, preserve a closed idle or unloaded placement as a no-op, and reject loading, loaded, live-worker, or unresolved-custody state without mutation.
- [ ] 7.5 Implement forced reload for an absent reconciled placement, including `recovery_uncertain` and non-operation `blocked` only after exact custody and in-flight-side-effect proof, keeping desired residency unloaded until its one immediate load succeeds and retaining every gate other than the old crash-loop latch.
- [ ] 7.6 Implement unload/reload for a loading or loaded placement as one operation with no force-cancellation option, serialized new-execution closure, pre-mutation active-Request rejection, and durable expected-stop intent whose partial unload-only outcome remains closed and unloaded and cannot be resurrected by a timer.
- [ ] 7.7 Write failure-path tests for lost acknowledgement, delivery timeout, Node restart between intent and result, Controller restart or leadership change, Postgres result-write failure, local result-write failure, and retry with the same operation ID.

## 8. Request And Attempt Separation Slice

- [ ] 8.1 Write failing end-to-end tests for a real worker crash before Output Commitment, after Output Commitment, with unresolved execution, with unresolved identity, after deadline, after caller loss, and with ambiguous capacity release.
- [ ] 8.2 Prove only the Controller can start attempt 2, only a different eligible Node can receive it, and no worker restart path replays request content, events, generation parameters, or tools.
- [ ] 8.3 Prove each actual unsuccessful attempt contributes to at most one eligible §5.10 breaker exactly once, while the local crash incident itself contributes none.
- [ ] 8.4 Prove Output Commitment, attempt evidence ordering, deadline, caller liveness, execution resolution, capacity release, hard prior-Node exclusion, quota, capture, and logical-versus-attempt metric contracts remain unchanged.

## 9. Documentation, Validation, And Handoff

- [ ] 9.1 Document operator inspection and recovery, unknown-outcome retry, stable reset, no automatic expiry, protected local state behavior, and the distinction among crash-loop state, §5.10 breakers, health, lifecycle, quarantine, and managed-profile exclusion.
- [ ] 9.2 Run focused policy, Node Agent lifecycle, persistence, process custody, Runtime Endpoint, Controller projection, scheduler, Operator API, and retry-separation tests after each vertical slice.
- [ ] 9.3 Run the complete applicable Elixir, native, proto, macOS helper, full-test, and coverage workflows from `AGENTS.md` after implementation and dependency changes.
- [ ] 9.4 Run the Apple Silicon real-model worker lifecycle smoke because the change affects the MLX Worker Runtime boundary and subprocess custody.
- [ ] 9.5 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate define-worker-crash-recovery --type change --strict --no-interactive` before implementation handoff.
- [ ] 9.6 Obtain an exact-worktree RepoPrompt architecture review and reconcile every finding against current repository truth.
- [ ] 9.7 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and remove placeholder prose such as `Purpose TBD` from generated main specs.
