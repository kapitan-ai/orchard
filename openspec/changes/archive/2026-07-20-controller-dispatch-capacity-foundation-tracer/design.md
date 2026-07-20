## Context

PR #92 established the F11 capacity-authority contract in `SPEC.md`, ADR 0013, the glossary, and the `controller-dispatch-capacity-authority` OpenSpec change.
The current Controller still stores aggregate runtime concurrency only in transient observation structures, admits a Node without a dispatch-capacity policy, and lets scheduler and queue modules interpret capacity independently.
The existing `controller_instances` table supplies durable Controller identity and `last_seen_at`, but it does not yet store the complete dispatch-capacity capability tuple or refresh it through a supervised membership heartbeat.

This slice must create durable, bounded evidence and one semantic evaluator while preserving current dispatch behavior.
It must not create an accidental partial enforcement mode, derive policy from telemetry, or make existing Nodes inherit a ceiling of `1`.

## Goals / Non-Goals

**Goals:**

- Persist the cluster phase, per-Node policies, bounded aggregate runtime evidence, and Controller capability evidence required by the approved contract.
- Create migration rows from durable admission history with a null ceiling only for eligible `shadow_legacy` Nodes.
- Provide one pure evaluator and truth table for both `pre_cutover` and `enforcing` inputs before any production consumer is wired to it.
- Make every new admission persist explicit policy, provenance, and audit evidence in the existing admission transaction.
- Expose counterfactual diagnostics that are honest about the durable phase and non-enforcing state.

**Non-Goals:**

- Advancing the durable phase or any policy to `enforcing`.
- Replacing capacity logic in MultiNode, SingleNode, Node queue-source refresh, QueueManager, or dispatch revalidation.
- Implementing policy mutation, Controller retirement, or enforcement-cutover endpoints.
- Implementing temporary legacy claims, cutover quiescence, the per-Node acceptance gate, durable permits, leadership fencing, reservation recovery, or compromised occupancy handling.

## Decisions

### Use normalized relational authority records

Add one cluster-scoped dispatch-capacity authority row keyed by the durable cluster identity.
It starts in `pre_cutover`, stores a positive required contract version, and leaves cutover provenance empty until a later slice performs cutover.

Add one `node_dispatch_capacity_policies` row per governed admission, keyed uniquely by Node ID and linked to durable admission evidence.
The database enforces the state vocabulary, a non-negative ceiling for `approved_explicit` and `enforcing`, a null ceiling only for `shadow_legacy`, and approval provenance for every explicit policy.
Use an integer optimistic-concurrency version from the start so later mutation work does not require another identity migration.

Alternative considered: add nullable ceiling and phase columns directly to `nodes`.
That collapses missing policy, explicit zero, and legacy shadow state and makes policy history subordinate to mutable inventory, so it is rejected.

### Expand from durable admission history only

The expand migration inserts `shadow_legacy` only for non-removed Nodes with a successful durable `admitted` decision committed before the migration boundary.
It records the admission decision and time as migration provenance, does not inspect Runtime Endpoint evidence, and does not insert a ceiling.
Nodes without qualifying admission evidence receive no synthetic policy and remain visibly fail-closed in counterfactual evaluation.
Removed Nodes are not inserted by the expand backfill; policies retained after a later durable removal remain historical evidence for the cutover slice.

Alternative considered: backfill all existing inventory rows or copy observed runtime maximum concurrency.
Both approaches create authority without proof of admission or operator approval, so they are rejected.

### Persist one bounded current aggregate observation per Node

Add a one-to-one aggregate capacity evidence row for each admitted Node instead of appending telemetry history or expanding admission-candidate JSON.
The row stores the raw normalized runtime limit, raw normalized active count, validity status, trusted observation time, and update time.
An authenticated newer observation replaces the row atomically; an older observation cannot overwrite newer evidence.
Missing or malformed values remain missing or invalid in durable evidence and are never normalized to policy or silently persisted as `1` and `0`.

Alternative considered: retain an unbounded observation log.
The foundation evaluator needs the latest trusted evidence and freshness timestamp, while an unbounded log adds retention and privacy obligations without serving this slice.

### Keep the evaluator pure and total

Implement the evaluator in a shared Controller domain module with typed input and result structs and no database, process, queue, or transport calls.
Inputs include durable phase, policy, normalized Controller-owned target management class, trust and lifecycle state, health, heartbeat freshness, aggregate capacity evidence and freshness, Controller-accounted allocation, placement capacity, and temporary legacy claim count.
The result includes the five canonical capacity values, phase, policy state, management class, authority decision, decision-specific available slots, eligibility, observation time, and ordered stable reason codes.

In `pre_cutover`, the evaluator keeps Effective Dispatch Limit and Dispatch Headroom at `0` and may calculate the frozen temporary legacy decision from fresh runtime evidence plus caller-supplied claim count.
In `enforcing`, it implements the approved fail-closed `min(runtime limit, Controller ceiling)` and headroom formulas for truth-table readiness, even though no persisted row can enter that phase in this slice.
Reason-code precedence is data, tested explicitly, so diagnostics do not depend on branch order hidden in callers.

Alternative considered: let each diagnostic or future consumer call small formula helpers.
That would preserve semantic drift between the five consumers, so one total evaluation boundary is required.

### Normalize management class before evaluation

A small Controller-owned classifier resolves admitted inventory first and forces `production_managed` regardless of transport or configuration.
Only explicit mode-valid source-development or compatibility configuration may produce an unmanaged class.
Missing, conflicting, Node-reported, or transport-inferred values become an invalid classification and a counterfactual fail-closed reason.
This classifier is used only by diagnostics in this slice and does not alter dispatch.

### Extend existing Controller identity with an atomic heartbeat tuple

Extend `controller_instances` with software version, supported dispatch-capacity contract version, `dispatch_capacity_consumers_ready`, and capability observation time.
Replace the current single-row cardinality assumption with identity-keyed local upsert while retaining immutable certificate and authorization-root checks and uniqueness constraints.
A supervised owner writes `last_seen_at` and the complete capability tuple in one update at boot and every `10000` ms.
This tracer always publishes `dispatch_capacity_consumers_ready = false` because none of the five production consumers is wired.

Alternative considered: create a second Controller capability table.
The capability tuple has the same lifecycle and identity boundary as Controller membership, so splitting it would permit mismatched freshness and retirement state.

### Extend the existing admission boundary atomically

Admission locks the cluster authority row before the Node and related grant rows to establish a stable lock order.
The existing Admin API and local CLI admission paths require a non-empty capacity policy reason, accept an optional non-negative ceiling, and resolve omission to explicit ceiling `1` in their shared preview.
Inside the existing transaction, Orchard revalidates the locked phase, performs admission, writes the admission decision and cluster audit evidence, and inserts the phase-derived policy linked to that decision.
Any phase, policy, decision, grant, lifecycle, or audit failure rolls back the complete admission.
Because the durable phase is `pre_cutover`, every policy created by this slice is `approved_explicit` and the preview reports `controller_dispatch_ceiling_not_yet_enforcing`.

Alternative considered: insert policy after admission in a second transaction.
That would permit an admitted production Node without explicit Controller authority, so it is rejected.

### Expose diagnostics through the shared status model

Add the complete counterfactual evaluation to the shared cluster-management Node status representation used by the current operator surfaces.
Diagnostics label the authority decision as counterfactual, show `pre_cutover`, keep the canonical enforcing values at zero, and show temporary legacy slots separately.
They never claim that a ceiling constrains dispatch, never mutate queue state, and never call the evaluator from a production authorization path.

## Risks / Trade-offs

- [Risk] A broad migration query could grant policy to inventory without durable admission proof.
  Mitigation: join only successful admission decisions before the migration boundary and assert the selected cohort in migration tests.
- [Risk] Concurrent admission and future cutover code could acquire locks in opposite order.
  Mitigation: establish phase-row-first lock ordering now and document it in the domain API.
- [Risk] Diagnostics could be mistaken for enforcement.
  Mitigation: publish explicit counterfactual and consumers-not-ready fields and test that no scheduler, queue, or dispatch module calls the evaluator.
- [Risk] Persisted telemetry could accidentally become policy.
  Mitigation: separate schemas, foreign keys, changesets, and names, and test that policy writes never read capacity evidence.
- [Risk] Heartbeat failure could leave partially fresh Controller evidence.
  Mitigation: update membership freshness and the full capability tuple in one database statement.
- [Trade-off] The evaluator supports enforcing inputs before enforcement is reachable.
  Mitigation: keep it pure, cover the full truth table, and prohibit durable phase advancement in the repository API delivered by this slice.

## Migration Plan

1. Run an expand migration that creates the authority, policy, and current-evidence relations, extends Controller membership, inserts the `pre_cutover` authority row, and creates qualifying `shadow_legacy` policies.
2. Deploy code that requires and reads the authority row, refreshes bounded evidence, publishes Controller capability with consumers-ready false, and atomically writes new admission policies.
3. Enable counterfactual diagnostics after the persistence and heartbeat paths are healthy.
4. Leave all existing dispatch paths unchanged until a separate all-five-consumers enforcing slice is reviewed and deployed.

Rolling application code back is safe because the added relations and columns are additive and old code ignores them.
Dropping the migration after new admissions is destructive because it discards policy provenance, so database rollback is allowed only before such writes or after an explicit export and recovery plan.

## Open Questions

None for this bounded tracer.
The M7 durability and fencing questions remain explicitly assigned to later milestones.
