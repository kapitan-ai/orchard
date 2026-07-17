## 1. Persistence Foundation

- [x] 1.1 Add the expand migration for the cluster-scoped authority row, per-Node dispatch-capacity policies, one-to-one current aggregate capacity evidence, and Controller capability columns with all database constraints and indexes from the design.
- [x] 1.2 Insert the singleton authority row in `pre_cutover` with a positive required contract version and no cutover provenance.
- [x] 1.3 Backfill exactly one null-ceiling `shadow_legacy` policy for each non-removed Node with qualifying pre-migration successful admission evidence, without reading telemetry or assigning a ceiling.
- [x] 1.4 Add Ecto schemas, public types, changesets, and read APIs for authority, policy, and capacity evidence while exposing no phase or policy transition to `enforcing`.
- [x] 1.5 Add migration and constraint tests for qualifying legacy admissions, missing admission proof, removed Nodes, duplicate policy prevention, explicit zero, invalid ceilings, invalid state-provenance combinations, and the empty-cluster singleton.

## 2. Runtime Evidence And Classification

- [x] 2.1 Preserve raw normalized aggregate runtime maximum, active count, validity, and trusted observation time before existing scheduler fallbacks are applied.
- [x] 2.2 Upsert at most one current aggregate evidence row per admitted Node only from authenticated observations, with an observation-time guard that prevents stale overwrite.
- [x] 2.3 Add tests for newer replacement, stale and unauthenticated rejection, missing and malformed values, and proof that runtime evidence never creates or changes policy.
- [x] 2.4 Implement the Controller-owned capacity-management classifier that resolves admitted inventory before explicit mode-valid unmanaged configuration and returns typed invalid results for missing or conflicting classification.
- [x] 2.5 Add BEAM, gRPC compatibility, static target, admitted-inventory override, source-development, compatibility, missing, and invalid classification tests.

## 3. Pure Capacity Evaluator

- [x] 3.1 Add typed evaluator input and result modules covering the five canonical values, durable phase, policy state, management class, authority decision, available slots, eligibility, observation time, and ordered stable reason codes.
- [x] 3.2 Implement one pure total evaluator for `legacy_pre_cutover`, `f11_enforcing`, fail-closed production decisions, explicit unmanaged compatibility decisions, minimum arithmetic, headroom arithmetic, placement bounds, and temporary claim subtraction.
- [x] 3.3 Add table-driven tests for every phase-policy combination, trust, lifecycle, healthy-only F11 eligibility, heartbeat and capacity freshness, policy presence, explicit zero, runtime evidence validity, target management class, and placement evidence.
- [x] 3.4 Add arithmetic and reason-precedence tests for runtime-bound, ceiling-bound, equal-bound, allocation exhaustion, over-allocation after lowering, placement exhaustion, malformed active count, and pre-cutover fallback behavior.
- [x] 3.5 Verify the evaluator has no database, process, queue, scheduler, dispatch, or transport dependency.

## 4. Controller Capability Evidence

- [x] 4.1 Extend Controller instance persistence with software version, supported dispatch-capacity contract version, all-five-consumers readiness, and capability observation time.
- [x] 4.2 Replace the single-row Controller instance assumption with authenticated identity-keyed local upsert while preserving immutable certificate, BEAM name, authorization-root, and uniqueness checks.
- [x] 4.3 Add a supervised Controller membership owner that publishes `last_seen_at` and the complete capability tuple atomically at boot and every `10000` ms.
- [x] 4.4 Hard-code this tracer's published all-five-consumers readiness to false and add a test that no runtime configuration can promote it to true.
- [x] 4.5 Add tests for multiple Controller identities, own-row-only updates, atomic heartbeat refresh, stale evidence after failed writes, supervision restart, and the exact heartbeat interval.

## 5. Atomic Node Admission

- [x] 5.1 Extend the shared Node Admission preview with required non-empty capacity policy reason, optional non-negative ceiling, explicit default `1`, phase-derived policy state, and `controller_dispatch_ceiling_not_yet_enforcing` under `pre_cutover`.
- [x] 5.2 Thread the shared fields and preview semantics through the Admin API and local `orchardctl nodes admit` human and JSON paths without adding general policy mutation or cutover endpoints.
- [x] 5.3 Refactor admission to lock the authority row before the Node and grant rows, then revalidate the phase and persist admission, decision, cluster audit, and linked policy in one transaction.
- [x] 5.4 Add admission tests for omitted ceiling, explicit zero, invalid ceiling, missing reason, pre-cutover state, actor and reason provenance, and proof that telemetry cannot supply policy.
- [x] 5.5 Add transaction-failure tests for phase, grant, lifecycle, decision, policy, and audit writes and assert that every partial admission side effect rolls back.
- [x] 5.6 Add concurrent admission tests that verify phase-first lock ordering, one policy per Node, and policy state matching the locked phase.

## 6. Counterfactual Diagnostics

- [x] 6.1 Build a read-only diagnostic snapshot from durable policy, current aggregate evidence, Controller-owned management classification, current allocation evidence, placement evidence, and freshness inputs.
- [x] 6.2 Add the complete counterfactual evaluation to the shared cluster-management Node status model and existing operator-facing human and JSON presenters.
- [x] 6.3 Keep Effective Dispatch Limit and Dispatch Headroom at `0` under `pre_cutover`, expose temporary legacy slots separately, and label approved ceilings as not yet enforcing.
- [x] 6.4 Add diagnostics tests for missing policy, shadow policy, approved policy, explicit zero, stale and malformed runtime evidence, degraded health, invalid management class, and stable reason-code output.
- [x] 6.5 Add boundary tests proving MultiNode, SingleNode, Node queue-source refresh, QueueManager, and dispatch revalidation do not consume the evaluator or change authorization behavior in this tracer.

## 7. Validation And Handoff

- [x] 7.1 Run `mise exec -- mix format`.
- [x] 7.2 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 7.3 Run `mise exec -- mix credo --strict`.
- [x] 7.4 Run `mise exec -- mix dialyzer`.
- [x] 7.5 Run the smallest focused migration, evaluator, evidence, heartbeat, admission, CLI, API, and diagnostics test slices during implementation.
- [x] 7.6 Run `mise exec -- mix test`.
- [x] 7.7 Run `mise exec -- mix test --cover` and review coverage for every new module and materially changed branch.
- [x] 7.8 Run exact strict validation for `controller-dispatch-capacity-foundation-tracer` and full strict OpenSpec validation.
- [x] 7.9 After archive or sync, review generated main specs and replace placeholder prose such as `Purpose TBD` before final validation.
