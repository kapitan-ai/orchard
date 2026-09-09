# Define worker crash recovery and crash-loop placement suppression (#379)

## Why

`SPEC.md` §12.2 requires the Node Agent to mark a crashed worker failed, restart it with bounded exponential backoff, and mark the placement failed with an open placement breaker after five crashes in ten minutes.
The current Node Agent records only bounded process-lifetime crash counters for metrics and removes a failed temporary worker without scheduling a replacement.
The current Controller breaker implementation belongs to `SPEC.md` §5.10 and has different triggers, identities, effects, expiry, and contribution ownership.

Issue #379 requires a contract before implementation because `SPEC.md` does not yet define crash incident identity, startup-failure treatment, rolling-window boundaries, stable reset, durable ownership, recovery fencing, or the interaction between Node-local restart state and Controller scheduling state.

## What Changes

- Define one Node Agent-owned recovery state machine per exact `(node_id, model_id, version)` runtime placement, with a durable recovery generation, desired-residency intent, worker-generation identity, rolling crash evidence, restart streak, pending deadline, and latched crash-loop breaker.
- Define one crash as the first accepted unexpected terminal startup or process-loss incident for the current worker generation, independent of exit status and deduplicated across owner, provider, transport, and cleanup notifications.
- Exclude intentional unload, eviction, reset, shutdown, request cancellation, subscriber exit, pre-launch acquisition failure, ordinary model-load failure with a live worker, stale generations, and duplicate notifications.
- Apply the exact 1, 2, 4, 8, 16, then 30 second capped delay sequence to the restart streak and the half-open rolling window `(t - 10 minutes, t]` to distinct crash incidents.
- Reset the restart streak after ten continuous minutes of loaded operation, prune rolling evidence only by the rolling-window rule, and keep an open breaker latched until an explicit recovery succeeds.
- Restore previously loaded residency automatically after an eligible crash, subject to the persisted deadline, cleanup proof, current generation, desired residency, and breaker state.
- Add separate authenticated Runtime Endpoint worker-recovery evidence and a Postgres-backed Controller projection that keeps scheduling, load reconciliation, and final dispatch revalidation from bypassing an open crash-loop breaker.
- Define generation-fenced, time-bounded, idempotent Operator clear, forced reload, and explicit unload/reload recovery operations with durable progress and fail-closed unknown-outcome reconciliation.
- Define provisional first-load bootstrap inside normal Request candidate, attempt, deadline, and allocation ordering, plus typed non-retryable recovery refusals that never become synthetic model-load failures.
- Preserve the independent `SPEC.md` §5.10 Node and model-load breakers, their exactly-once attempt attribution, and every existing Request retry gate.
- Express implementation as vertical test-driven slices through public Node Agent, Runtime Endpoint, Controller, scheduler, and Operator seams.

## Proposed Owner Decisions

The repository fixes the §12.2 threshold and delay sequence but does not already authorize the following policy choices.
This proposal makes them explicit for owner acceptance instead of presenting them as existing product behavior.

1. A successfully loaded placement retains automatic desired residency after an eligible crash.
2. A worker generation that has entered the launch boundary and then fails to spawn, become ready, or remain alive during startup contributes one crash, while acquisition and validation failures before that boundary do not.
3. Ten continuous minutes in the loaded state resets the restart streak but never clears an open breaker.
4. A versioned protected Node-local recovery store is authoritative for worker restart safety, while Postgres is authoritative for the Controller's cluster-visible projection and enforcement; first-load bootstrap and mixed-version cutover use an explicit evidence-producing protocol rather than interpreting missing evidence as closed.
5. Clear leaves the placement unloaded, forced reload repairs an exactly absent placement with one immediate load, unload/reload never force-cancels active Requests, blocked progress resumes only after exact reconciliation, and every recovery command expires within 24 hours.
6. Controller-accepted transition evidence and the bounded proof of each opening transition are retained for at least 30 days, recovery audit evidence for at least 365 days, and `worker_crash_loop_open` is a distinct stable scheduling reason.

Implementation remains blocked until review accepts or replaces these six decisions as one coherent contract.

## Capabilities

### New Capabilities

- `worker-crash-recovery`: Defines crash identity, backoff, rolling threshold, durable lifecycle ownership, explicit recovery, and restart/request separation.

### Modified Capabilities

- `runtime-endpoints`: Adds bounded worker-recovery observations and generation-fenced recovery operations without repurposing metrics counters.
- `circuit-breakers`: Separates §12.2 crash-loop state from §5.10 Node and model-load breakers.
- `scheduler`: Requires crash-loop suppression during candidate selection, loading, reconciliation, and final authorization.
- `automatic-attempt-retry`: Preserves Output Commitment and every closed retry gate while prohibiting Node-local request replay.
- `operator-command-authority`: Adds authenticated, audited worker crash-loop inspection and recovery commands.

## SPEC.md Impact

This change clarifies existing `SPEC.md` §12.2 behavior and its relationship to §§4.6.1, 5.5, 5.8 through 5.10, 6.8, 7.3, 8.5, and 12.7.
The later implementing change must reconcile the accepted decisions into `SPEC.md` before archive or sync.
In particular, it must state the exact crash boundary, automatic desired-residency behavior, half-open rolling window, stable reset, latched no-expiry breaker, recovery-generation semantics, protected Node-local recovery state, Controller projection, first-load bootstrap, typed recovery refusals, command expiry, evidence retention, and distinct scheduler reason `worker_crash_loop_open`.

This contract does not change the §5.10 thresholds, windows, failure eligibility, timed suppression expiry, Operator clear path, or one-breaker-per-attempt rule.
It does not broaden Automatic Attempt Retry or authorize an independent replay from a worker restart timer.

## Impact

- Future Node Agent work will replace cumulative metrics-only crash handling with a separate durable worker-recovery authority while retaining the existing metric counter semantics.
- Future Runtime Endpoint work will carry additive recovery state and a distinct recovery-operation protocol across BEAM and compatibility transports.
- Future Controller work will persist crash-loop projections and operation reconciliation in Postgres, enforce them in scheduler and load paths, and expose bounded Operator surfaces.
- Future tests will require deterministic clocks and timers, persistent-state fault injection, real process-custody coverage, authenticated Runtime Endpoint coverage, and retry/breaker separation regressions.
- This PR changes only OpenSpec contract artifacts.
It does not modify product code, `SPEC.md`, generated bindings, database migrations, routes, CLI behavior, or runtime configuration.

## Out Of Scope

- Product implementation, database migrations, protocol field allocation, generated bindings, or UI work.
- Changes to `SPEC.md` §5.10 Controller breaker policy or its existing routes.
- New Request retry classes, more than two attempts, queue re-entry, deadline extension, or weaker execution-resolution, identity, capacity-release, and Output Commitment gates.
- Reconstructing crash-loop state from Prometheus counters, heartbeat deltas, logs, Request history, or §5.10 contributions.
- Treating health, ordinary placement capacity, managed-profile exclusion, quarantine, or lifecycle state as interchangeable with crash-loop recovery state.
- Importing proposed managed-node helper guarantees as portable worker-recovery behavior.
