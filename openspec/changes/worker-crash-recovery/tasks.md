## 1. Contract proposal (this work item only)

- [x] 1.1 Reconcile the focused §12.2 contract and create proposal, design, and spec deltas; leave §5.10 thresholds/attribution and Request retry unchanged.
- [x] 1.2 Curate the contract diff and obtain one focused review; resolve concrete contract findings without broad discovery.
- [x] 1.3 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate worker-crash-recovery --type change --strict --no-interactive` and record the outcome in the handoff.

## 2. Node recovery authority and bounded checkpoint

- [x] 2.1 Add a pure, time-injected policy and tests for production delays/cap, half-open window, stability boundary, fifth-crash ordering, deduplication, and Node/model/version isolation.
- [x] 2.2 Add the bounded per-placement Postgres checkpoint with transactional revision/epoch checks and the concrete Node-originated read/CAS interfaces in design §8; Controller Operator API forwarding must remain read-only. Keep Node database credentials/local journaling out of scope; test authoritatively absent versus unavailable and stale/unauthorized writes.
- [x] 2.3 Integrate ModelManager worker/load ownership, write-ahead checkpoint ordering, single-flight automatic residency restart, slot accounting, no-earlier-than timers, ordinary reset, and non-bypassable ensure/execute admission. Keep temporary supervision, cumulative metrics, and Request terminalization intact.
- [x] 2.4 Fence worker/channel/generation/load/timer events and intentional-stop races. Count real loading or loaded worker loss once; non-crash restart failure stops automation without counting a crash.
- [x] 2.5 Test manager/agent restart and persistence loss before/after every checkpoint acknowledgement, including failed fifth-crash persistence, interrupted ownership and affirmative custody proof, retained open/empty-history recovery-required, deferred checkpoint resumption, overlapping stability reset/crash, and normal healthy/new-key startup. Cleanup uncertainty must never release occupancy or authorize a new worker.

## 3. End-to-end evidence, operator recovery, and accounting

- [x] 3.1 Carry retained recovery state and epoch/revision through Node status, RuntimeEndpointMapper, shared Observation/Placement, existing Controller observation storage, and snapshot/final-admission consumers; implement exact-key read-only inspection for new/cold candidates, BEAM and gRPC parity, and only necessary bounded protocol/schema changes.
- [x] 3.2 Implement the dedicated identity-bound `RecoverWorkerPlacement` operation and narrow Operator API status/action routes in the design, using existing authentication, Active Controller authorization, and audit facilities. Test clear, non-forced unload/reload, forced reload, durable operation phases, stale revisions, duplicates, lost acknowledgements, and cleanup/load failures.
- [x] 3.3 Reject blocked/unknown placement recovery evidence before loaded/cold ranking, capacity acquisition, and final execution admission; prove ordinary ensure, reconciliation, force flags, and stale evidence cannot clear or bypass recovery.
- [x] 3.4 Normalize structured recovery refusal before generic ModelLoadFailure conversion: pre-attempt eligibility rejection, post-start proven pre-execution `capacity_rejection`/`model_busy`, existing uncertainty precedence. Prove zero refusal-induced §5.10 events and unchanged attribution for actual failed attempts, retry gates, terminalization, and independent breaker clears.

## 4. Implementing verification and handoff (not performed by this proposal)

- [x] 4.1 Run smallest policy/manager/worker tests first; then shared Runtime Endpoint, Node integration, Controller checkpoint/operator/scheduler/dispatch/inference regressions. Cite §12.2 in new behavioral coverage.
- [x] 4.2 Run the applicable ordered AGENTS.md quality workflows and coverage from the umbrella root; rerun relevant gates if generated transport code changes native packages. Report exact commands/outcomes and blockers, not just a passing subset.
- [x] 4.3 Validate the OpenSpec change strictly before handoff. Record sanitized worker-recovery evidence in the issue/PR, not a committed execution document; no UI or full split-host pilot qualification claims.
- [ ] 4.4 After implementation acceptance, reconcile operator/product docs as needed, sync/archive the accepted deltas, check generated purpose prose, and run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive`.
