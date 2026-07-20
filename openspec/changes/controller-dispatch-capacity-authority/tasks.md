# Tasks

## 1. Contract and architecture

- [x] 1.1 Update `SPEC.md` with the accepted authority split, formulas, policy persistence, migration, consumer, placement-bound, diagnostics, and scope contract.
- [x] 1.2 Add ADR 0013 for Controller dispatch capacity authority and rejected alternatives.
- [x] 1.3 Add the canonical glossary terms and `_Avoid_` aliases, including the rejected `Admitted Capacity` alias.
- [x] 1.4 Add focused `dispatch-capacity` and `runtime-endpoints` OpenSpec deltas with acceptance scenarios.
- [x] 1.5 Run strict validation for this exact OpenSpec change.
- [ ] 1.6 Review generated main specs for placeholder prose after archive or sync.
  Foundation evidence, 2026-07-20: after the post-PR #93 foundation tracer sync, the five merged `dispatch-capacity` requirements and the merged `runtime-endpoints` requirements carried no duplicate headings and no placeholder purpose prose.
  This gate is recurring and remains open: it must repeat at every later sync of this change and again at parent archive.

## 2. Non-enforcing foundation tracer

PR #93 completes only the non-enforcing foundation.
Temporary legacy claims are evaluator inputs only and are not acquired or serialized.
MultiNode, admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch revalidation remain unwired, and Controller capability publication remains `dispatch_capacity_consumers_ready = false`.
No Operator policy mutation, Controller retirement, cutover, quiescence, acceptance gate, or production enforcement task is completed by this reconciliation.

- [x] 2.1 Add `node_dispatch_capacity_policies` plus the singleton dispatch-capacity authority row in `pre_cutover`, with policy states, approval and cutover provenance, positive required contract version, non-negative explicit ceilings, and constraints that allow a null ceiling only in temporary `shadow_legacy`.
  Completed by PR #93: the expand migration, schemas, constraints, singleton seed, provenance fields, explicit-zero support, and rollback guard are merged.
- [ ] 2.2 Create `shadow_legacy` rows only for non-removed production Nodes whose Node Admission committed before the expand migration, selected from durable `admitted_at` or equivalent admission history, without assigning `1` and without reading telemetry into policy; retain historical policy for durably removed, trust-revoked, audited tombstones without making them cutover blockers.
  Partial after PR #93: the expand migration creates null-ceiling `shadow_legacy` policies from durable successful admission evidence for non-removed Nodes, without telemetry backfill or an implicit ceiling of `1`.
  Remaining work must preserve historical policy evidence for removed tombstones and prove that operational and cutover exclusion occurs only when lifecycle is `removed`, trust is revoked, and a successful removal audit exists.
  That conjunctive exclusion remains covered by 3.3 and 5.7c, so 2.2 remains unchecked.
- [x] 2.3 Add one pure shared capacity evaluator that takes durable phase and normalized target management class, calculates the frozen pre-cutover runtime-max-or-1 minus reported-active-or-0 and live temporary legacy claims centrally, and returns the five canonical aggregate values plus Placement Capacity, durable phase, policy state, normalized management class, explicit authority decision, decision-specific available slots, eligibility, and reason codes.
  Completed by PR #93 for the evaluator boundary: temporary claim count is a pure input and the evaluator centrally subtracts it, while live claim acquisition and ownership remain in 4.5 and 4.9.
- [x] 2.4 Add truth-table tests for phase-policy combinations, trust, lifecycle, healthy-only eligibility, heartbeat and capacity freshness, policy presence, runtime evidence, target management class, explicit zero, and min/headroom arithmetic.
  Completed by PR #93 through evaluator, evidence, and management-classifier truth-table coverage.
- [x] 2.5 Make Node Admission lock and read the durable phase, atomically persist `approved_explicit` before cutover with an administrator-supplied value or the explicit default `1`, and roll back admission if phase, policy, or audit persistence fails.
  Completed by PR #93 for pre-cutover admission; enforcing post-cutover admission remains in 3.5.
- [x] 2.6 Expose policy and counterfactual capacity diagnostics without advancing any policy to `enforcing` or claiming production enforcement.
  Completed by PR #93 through read-only operator diagnostics and the five-consumer non-enforcement boundary test.
- [x] 2.7 Add the supervised Controller membership owner and its `10000` ms heartbeat, atomically publishing `last_seen_at`, software version, supported dispatch-capacity contract version, all-five-consumers-ready declaration, and capability observation time at boot and on each heartbeat.
  Completed by PR #93 with readiness forced to false; publishing true remains in 4.8 after all five consumers are wired.

## 3. Operator approval and migration cutover

- [ ] 3.1 Add the specified Operator API policy and Controller-instance reads, leader-only admin-authorized approval/update, cutover, and Controller retirement endpoints, Admin admission ceiling and reason fields, and matching `orchardctl nodes admit` flags with shared Action Previews, confirmations, actor provenance, and cluster-scoped audit writes.
  Partial after PR #93, reviewed 2026-07-20; PR #93 merged at `7d76ccd1` on 2026-07-17: the Admin Node Admission API/UI and local `orchardctl nodes admit` surfaces landed the optional Controller Dispatch Ceiling, required capacity policy reason, shared Action Preview and confirmation behavior, local operator actor provenance, and Console drawer verification.
  Remaining work includes Operator API policy and Controller-instance reads, policy approval/update, enforcement cutover, and Controller retirement endpoints, with required authorization, leadership, optimistic concurrency, confirmation, and atomic audit behavior, so 3.1 remains unchecked.
- [ ] 3.2 Add optimistic concurrency, mutation-time authorization, leadership, durable-phase and policy revalidation, and explicit support for an audited ceiling of `0`.
- [ ] 3.3 Add cutover preview and preflight proving every non-removed admitted legacy Node has an approved ceiling and every non-retired Controller has fresh capability evidence at the required contract version with all five consumers ready; exclude only durably removed Nodes with revoked trust and successful removal audit.
- [ ] 3.4 Under the migration advisory lock and Controller-local transition barrier, quiesce new legacy claims, wait for zero live temporary claims and new fresh zero-active aggregate observations, acquire every per-Node acceptance gate in stable order, revalidate, then atomically advance approved policies and the durable phase or reopen legacy dispatch unchanged on failure.
- [ ] 3.5 After enforcement cutover, make Node Admission lock the phase and atomically persist `enforcing` policy and its audit record before the lifecycle transition commits.
- [ ] 3.6 Contract away the bounded legacy migration state after every non-removed admitted production Node has explicit policy, while retaining removed tombstones as historical evidence.
- [ ] 3.7 Implement Controller retirement blockers for the current Active, leadership-lock holder, and last non-retired instance, with optimistic concurrency and atomic cluster audit.

## 4. First enforcing vertical tracer

- [ ] 4.1 Wire MultiNode eligibility and lane contribution to the shared evaluation.
- [ ] 4.2 Wire admitted and production-managed SingleNode paths to the same evaluation while preserving only explicitly unmanaged source-development compatibility behavior.
- [ ] 4.3 Wire Node queue-source refresh to publish bounded effective capacity and clear sources on trust, lifecycle, health, freshness, policy, or runtime-limit loss.
- [ ] 4.4 Wire QueueManager so all placements and lanes on one Node share one aggregate allocation bound.
- [ ] 4.5 Serialize Controller-local acquisition of both temporary legacy claims and the final Dispatch Headroom unit across all placements and lanes, retain the applicable claim through model loading, acceptance, and terminal completion, and release it exactly once on failure, cancellation, retry, or completion.
- [ ] 4.6 Add the per-Node acceptance gate shared by policy mutation and dispatch, then revalidate after model loading and immediately before `ExecuteInference`, excluding only the request's recognized claim from the applicable operand and holding the gate through Node acceptance or pre-acceptance failure.
- [ ] 4.7 Prove with one shared fixture that MultiNode, admitted SingleNode, Node refresh, QueueManager, and dispatch revalidation return the same capacity values and reasons.
- [ ] 4.8 Publish `dispatch_capacity_consumers_ready = true` only when the running Controller version has all five consumers wired and the shared fixture passes; otherwise publish false.
- [ ] 4.9 Prove all five consumers authorize `legacy_pre_cutover` from the same central temporary slots and serialized claims without requiring positive Dispatch Headroom, then quiesce to zero live claims and fresh zero observed occupancy before switching atomically to F11 authority at cutover.

## 5. Acceptance and diagnostics

- [ ] 5.1 Cover trusted and untrusted, Active and non-Active, healthy, degraded, unhealthy, fresh and stale, policy present, missing, and malformed, explicit zero, runtime-bound, ceiling-bound, and equal-bound scenarios.
- [ ] 5.2 Cover raising and lowering, pre-acceptance held-allocation revalidation without double-counting, accepted/running/streaming natural drain without forced cancellation solely because of a reduction, and queue wake-up after re-evaluation.
- [ ] 5.3 Cover two concurrent requests racing for one final allocation and prove exactly one succeeds.
- [ ] 5.3a Cover two legacy queue lanes racing for one temporary slot and prove exactly one acquires a temporary claim.
- [ ] 5.4 Cover Placement Capacity above the Effective Dispatch Limit, Placement Capacity below it, and aggregate exhaustion with per-placement room.
- [ ] 5.5 Cover migration without telemetry backfill or existing-row default `1` and fail-closed cutover for missing policy.
- [ ] 5.6 Cover `approved_explicit` to `enforcing` cutover and post-cutover admission entering `enforcing` directly.
- [ ] 5.7 Cover an empty cluster, admission racing with cutover, rollback of partial cutover, exact Controller-to-required-version equality, expected-version mismatch, and incompatible Controller fail-closed behavior against the durable phase.
- [ ] 5.7a Cover cutover quiescing, new-claim refusal, natural legacy drain, stale or nonzero occupancy timeout with unchanged phase, and successful zero-occupancy revalidation under every acceptance gate.
- [ ] 5.7b Cover ceiling mutation racing the final dispatch-to-acceptance handoff and prove the shared gate linearizes either acceptance before mutation or revalidation under the new policy.
- [ ] 5.7c Cover removed tombstone exclusion, rejection of implicit exclusion for unreachable or other lifecycle states, and re-enrollment under the current phase.
- [ ] 5.8 Cover fresh, stale, missing, incompatible, and all-consumers-not-ready Controller capability evidence plus audited retirement before exclusion from cutover.
- [ ] 5.9 Cover Admin and CLI admission preview, pre-cutover not-yet-enforcing warnings including zero, Operator API read and update authorization, optimistic concurrency, enforcing drain confirmation, standby rejection, local actor provenance, and atomic audit persistence.
- [ ] 5.10 Cover always-on capacity management classification independently of the durable enforcement phase and of published `dispatch_capacity_consumers_ready`, explicit unmanaged source-development and compatibility modes, absent, malformed, conflicting, or unresolved classification failing closed with stable reason codes and no legacy normalization, admitted-inventory override of a conflicting unmanaged declaration, admitted production over gRPC compatibility, static targets matching admitted production inventory, and the separately always-on proof that an admitted production target lacking fresh trusted capacity evidence cannot receive new work through unmanaged classification or compatibility fallback. Broader production probe-failure direct scheduling fallback cleanup remains pending separately.
- [ ] 5.11 Add fixed reason codes and expose the complete shared evaluation result, including phase, policy state, management class, authority decision, decision-specific available slots, eligibility, the five canonical aggregate capacity values, and Placement Capacity, consistently across operator status surfaces.

## 6. Validation

- [x] 6.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate controller-dispatch-capacity-authority --type change --strict --no-interactive`.
  Validation passed for this contract PR.
- [ ] 6.2 For implementation slices, run `mise exec -- mix format`.
  Foundation evidence reviewed 2026-07-20 for PR #93, merged at `7d76ccd1` on 2026-07-17: PR #93 does not durably list an exact successful `mise exec -- mix format` run.
  This gate is recurring and remains open.
- [ ] 6.3 For implementation slices, run `mise exec -- mix compile --warnings-as-errors`.
  Foundation evidence reviewed 2026-07-20 for PR #93, merged at `7d76ccd1` on 2026-07-17: PR #93 does not durably list an exact successful `mise exec -- mix compile --warnings-as-errors` run.
  This gate is recurring and remains open.
- [ ] 6.4 For implementation slices, run `mise exec -- mix credo --strict`.
  Foundation evidence reviewed 2026-07-20 for PR #93, merged at `7d76ccd1` on 2026-07-17: PR #93 does not durably list an exact successful `mise exec -- mix credo --strict` run.
  This gate is recurring and remains open.
- [ ] 6.5 For implementation slices, run `mise exec -- mix dialyzer`.
  Foundation evidence reviewed 2026-07-20 for PR #93, merged at `7d76ccd1` on 2026-07-17: PR #93 does not durably list an exact successful `mise exec -- mix dialyzer` run.
  This gate is recurring and remains open.
- [ ] 6.6 For implementation slices, run `mise exec -- mix test`.
  Foundation evidence reviewed 2026-07-20 for PR #93, merged at `7d76ccd1` on 2026-07-17: PR #93 durably reports a successful full umbrella `mix test` run with 645 tests and 10 excluded after stale temporary directories were removed, plus targeted suites and the real Repo-restart E2E.
  This gate is recurring and remains open.
- [ ] 6.7 For implementation slices, run `mise exec -- mix test --cover`.
  Foundation evidence reviewed 2026-07-20 for PR #93, merged at `7d76ccd1` on 2026-07-17: PR #93 does not durably list an exact successful `mise exec -- mix test --cover` run.
  This gate is recurring and remains open.
- [ ] 6.8 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and remove placeholder prose such as `Purpose TBD`.
  Foundation evidence, 2026-07-20: after the foundation tracer sync and archive, all nine remaining validation items, comprising six active changes and three main specs, passed strict validation with no placeholder prose.
  This gate is recurring and remains open: it must repeat at every later sync of this change and again at parent archive.
