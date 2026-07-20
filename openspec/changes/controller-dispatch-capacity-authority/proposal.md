# Controller dispatch capacity authority

## Why

Orchard currently derives Controller scheduling and queue capacity directly from Node-reported aggregate concurrency telemetry.
There is no durable per-Node Controller authority that limits how much new work the Controller may allocate.
Missing and legacy runtime telemetry can also fall back to capacity `1`, which cannot safely stand in for missing production policy.

This change separates the Node-owned dynamic enforcement limit from the Controller-owned durable ceiling and defines one shared fail-closed production contract.

## What changes

- Add a mandatory durable Controller Dispatch Ceiling for every admitted production Node, with a bounded null-ceiling `shadow_legacy` exception only for Nodes admitted before the F11 migration.
- Persist an explicit ceiling at Node Admission, defaulting new admissions to `1`.
- Define Runtime Concurrency Enforcement Limit, Effective Dispatch Limit, Controller-accounted Allocation, Dispatch Headroom, and their relationship to Placement Capacity.
- Require strict trusted, Active, healthy, and scheduler-fresh production eligibility.
- Add explicit `shadow_legacy -> approved_explicit -> enforcing` migration states with operator approval and no telemetry backfill.
- Add a durable cluster-wide `pre_cutover -> enforcing` phase that serializes admission with atomic enforcement cutover and Controller compatibility checks.
- Serialize temporary legacy claims across all lanes, quiesce them before cutover, and share one per-Node boundary between policy mutation and the final dispatch-to-acceptance handoff.
- Add fresh durable Controller capability evidence for the required contract version and indivisible all-five-consumers readiness.
- Add the Controller membership heartbeat and audited retirement recovery path needed to keep that evidence actionable at cutover.
- Bound placement and queue-lane contributions by one aggregate per-Node authority.
- Require MultiNode, admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch-time revalidation to consume one shared evaluation.
- Define matching Admin API and `orchardctl nodes admit` inputs plus Operator API policy and cutover management surfaces with Action Preview, confirmation, and audit behavior.
- Define a normalized Controller-owned target capacity management class so unmanaged compatibility can never be inferred from transport or failure.
- Define raising, lowering, source-development exceptions, diagnostics, and stable reason vocabulary.

## SPEC.md impact

The apex contract update for this change is complete.
It principally established the accepted Controller dispatch-capacity authority contract in `SPEC.md` §4.6.2 and reconciled related requirements across affected sections.
This reconciliation closes one narrow §4.6.2 output-enumeration gap by adding Placement Capacity and decision-specific available slots to the shared evaluation output, matching the approved parent contract and the corresponding fields already present in the shipped `Orchard.DispatchCapacity.Evaluator.Result`.
It closes the matching §7.3.5 operator-diagnostics enumeration gap by exposing Placement Capacity, decision-specific available slots, and eligibility consistently with §4.6.2.
It changes no other `SPEC.md` behavior.
The active OpenSpec delta is covered by and traces to the current exact union `SPEC.md` §3.3, §4.1, §4.4, §4.5, §4.6.1, §4.6.2, §5.4, §5.5, §5.9, §7.3.1, §7.3.5, §7.4.1, §7.5, §7.5.3, §8, §8.2, §10.9, §11.9, and §13.2.
`SPEC.md` remains the apex contract, and these OpenSpec deltas define the remaining implementation and acceptance intent beneath it.

## Delivery state

PR #93 delivered the non-enforcing foundation only.
The remaining product-code implementation remains active in this parent change.

## Out of scope

- Durable dispatch permits.
- Leadership epochs and dispatch fencing.
- Crash or handover reservation recovery.
- Compromised-node occupancy integrity.
- Malformed aggregate active-count hardening.
- Production probe-failure direct scheduling fallback cleanup.
- Queue-source expiry and reservation provenance.
- Configured-base versus live-capacity provenance.
- Further product-code implementation in this reconciliation PR.
