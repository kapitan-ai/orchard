## Why

Issue #379 requires the Node-owned worker restart and placement crash-loop policy in `SPEC.md` §12.2. Losing a worker must not make the same placement immediately loadable through ensure-load, reconciliation, or stale scheduler evidence. Recovery must restore residency without replaying a Request.

## What Changes

- Clarify §12.2 crash identity, the monotonic ten-minute window, capped restart delays, stable-operation reset, and fifth-crash ordering.
- Define explicit operator clear, ordinary operator unload/reload, and forced reload with generation-safe cleanup and no implicit clear through routine operations.
- Preserve recovery safety through a bounded Postgres checkpoint per affected placement, accessed through the authenticated Controller. After state loss, only interrupted/uncertain placements or placements with retained crash state require explicit recovery; clean and new placements retain normal startup/load behavior.
- Add retained Runtime Endpoint recovery evidence, a narrowly scoped authenticated recovery operation, and scheduler/final-admission exclusion for the affected placement.
- Distinguish pre-execution recovery admission refusal from an actual load or worker-loss failure. Preserve §5.10 thresholds/attribution and the closed Request retry contract.

This is a contract-only change package. Its implementation checklist remains open; the package does not claim runtime enforcement already exists.

## SPEC Impact

`SPEC.md` §12.2.1–§12.2.3 reconcile previously unspecified details beneath the existing §12.2 behavior. Sections 5.10 and the Request retry rules are unchanged. New delta capabilities are `worker-crash-recovery`, plus bounded additions to `runtime-endpoints` and `scheduler`.

Recovery state survives clean shutdown/reset. An unclean epoch loss cannot prove the outcome of an in-progress worker or safely reuse old monotonic time, so interrupted placements require explicit recovery rather than an automatic restart. This scoped conservative recovery trades unattended restart of interrupted placements for safety, without imposing a new-installation or healthy-key startup interlock.

## Scope and Non-goals

Implementation ownership is ModelManager orchestration, a pure recovery policy, worker-incarnation fencing, Runtime Endpoint evidence/command adapters, and Controller admission integration. Temporary worker supervision and OS process custody remain as they are.

No second database, local journal, general recovery/event store, Controller breaker policy change, Request retry class, UI, host suspension support, pilot qualification, packaging change, or general architecture refactor. Persistence is limited to one current recovery checkpoint per Node/model/version in the existing Postgres database; existing observation/audit facilities carry status and operator evidence. Transport/schema changes are limited to this checkpoint and supported Runtime Endpoint recovery paths.

Rollout must coordinate checkpoint support and Node/Controller adapters before enabling recovery-gated scheduling; pre-upgrade Nodes lacking recovery evidence are ineligible until upgraded, not silently trusted. Drain/stop resident workers while checkpoint authority is reachable for clean shutdown; abrupt agent loss or Controller-first shutdown can require explicit recovery for still-resident placements.

## Validation

Before implementation or PR handoff, run strict OpenSpec validation for `worker-crash-recovery`. The implementing work must add deterministic policy/race regressions and run the applicable ordered quality workflow and coverage in `AGENTS.md`. Tooling setup and transient execution evidence are separate from this contract.
