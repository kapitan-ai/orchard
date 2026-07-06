# ADR: `draining -> cordoned` recovery edge (cancel drain)

## Status

Accepted. Implementation of the edge closes GitHub issue #48.

## Context

A node in `draining` has no operator recovery path. SPEC.md §4.3 gives `draining` exactly two outgoing edges — `draining -> maintenance` and `draining -> decommissioning` — and the transition table in
`apps/orchard_controller/lib/orchard/nodes/lifecycle.ex` implements that literally: `resume` is allowed only from `[:maintenance]` and `uncordon` only from `[:cordoned]`, so either command from `draining` hits the catch-all blocker `lifecycle_transition_invalid`. The remaining forward edge is deliberately gated: `add_maintenance_drain_verification_blocker/3` blocks manual `draining -> maintenance` with `drain_completion_unverified`, per SPEC.md §11.9 ("Manual `draining -> maintenance` execution SHALL remain blocked with a `drain_completion_unverified` blocker until drain completion can be verified") and OpenSpec `cluster-management-ux-foundation` task 4.6.

Net effect, confirmed by the two-node smoke: the only executable exit from `draining` is `decommission`, and §4.4 makes `decommissioning -> removed` terminal ("no rejoin with same `node_id`"). An operator who drains by mistake, or whose drain never quiesces, must destroy the node identity to recover.

SPEC.md §4.8 already treats `cordoned` as drain's resting state: on quiescence with `enter_maintenance=false` the node is to "remain `cordoned`" — an outcome §4.3's edge list does not currently admit.

## Decision

Add a `draining -> cordoned` edge ("cancel drain") to SPEC.md §4.3 and to the lifecycle action table, triggered by operator/admin action. Effect: the node stops waiting for quiescence and holds as `cordoned` (still unschedulable); no drain-completion verification is required because nothing is being certified as drained. Recovery to scheduling then uses the existing `cordoned -> active` edge, so the operator regains a full path (`draining -> cordoned -> active`) without weakening the `drain_completion_unverified` gate on `maintenance`.

Semantics fixed at acceptance:

* Cancel drain is a distinct action (`cancel_drain`), not a reuse of `uncordon`: `uncordon` is bound to `cordoned -> active` in code and operator language, and cancel drain must not reopen scheduling.
* Cancel drain does not restore, replay, or migrate back work that already completed, was cancelled, or quiesced while the drain ran; it only stops further waiting.
* Cancel drain is allowed only from `draining`. Attempts from any other state produce a lifecycle blocker (`drain_not_running`), mirroring the existing `drain_already_running` blocker rather than introducing an idempotent no-op, which the lifecycle state machine has no precedent for. Mutation-time revalidation inside the lifecycle transaction already guarantees the state is re-checked at execution, so a drain that completed between preview and execution is rejected cleanly.

Prior art supports this shape: Nomad exposes an explicit `node drain -disable` cancel primitive whose `-keep-ineligible` flag leaves the node unschedulable (exactly this edge), and Kubernetes models drain as cordon plus evictions where `uncordon` restores schedulability without undoing evictions.

Alternatives rejected:

* `draining -> active` directly — reopens scheduling in one step, skipping the explicit `uncordon` consent and its health considerations, and adds a second recovery edge to maintain for no extra capability.
* Fold recovery into the future drain-verification slice — cancel-drain does not depend on verification at all, so coupling them only ships the dead-end for longer.

## Consequences

Drains become reversible. The lifecycle module gains one action (allowed from `[:draining]`, target `cordoned`) with the usual dry-run preview, confirmation, blocker, and audit vocabulary, plus tests for the new edge. §4.3 becomes consistent with §4.8's completion semantics. Drain-deadline orchestration and automatic `draining -> maintenance` remain untouched future work; when drain-deadline orchestration lands it must honor an executed cancel drain by stopping its own countdown rather than acting on a node that is no longer `draining`.

## SPEC.md impact

Update required in §4.3 (add `draining -> cordoned` to the edge list) and §4.4 (transition rule: trigger operator/admin action; effect: stop waiting for active-request quiescence, remain unschedulable as `cordoned`).
