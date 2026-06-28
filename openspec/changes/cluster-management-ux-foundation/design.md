## Context

Orchard targets one to four Apple Silicon macOS nodes, with all durable state in Postgres and HA-lite coordination through a Postgres advisory lock.
`SPEC.md` §4 defines a managed node lifecycle from `provisioned` through `removed`, with explicit Admin API admission before a node can become `active`.
`SPEC.md` §4.5 says health is orthogonal to lifecycle state.
`SPEC.md` §5.5 says scheduler eligibility depends on lifecycle, health, pool policy, model/runtime support, memory, concurrency, placements, and circuit breakers.
`SPEC.md` §7.3 and §7.4 split operator actions from admin actions.
`SPEC.md` §7.5 says Runtime Endpoint observations are transport-independent and Postgres remains durable truth for inventory, lifecycle state, observations, scheduling history, request state, and operator-visible status.

The current source tree has useful foundations but does not yet implement the full lifecycle UX.
`apps/orchard_controller/lib/orchard/nodes.ex` describes observational node discovery and inserts new nodes from successful Runtime Endpoint observations with `state: :active`.
`apps/orchard_controller/lib/orchard/console/nodes_live.ex` renders persisted inventory and live Runtime Endpoint diagnostics, but it does not yet expose pending admission review or safe lifecycle actions.
`apps/orchard_cli/lib/orchard_cli/commands/nodes.ex` supports `orchardctl nodes list`, while `orchardctl nodes admit` is a deferred command.
`apps/orchard_cli/lib/orchard_cli/commands/support.ex` already has a redacted support bundle flow that can become the shared diagnostics foundation.

## Goals

- Make pending admission explicit and auditable before a first-observed node can receive work.
- Give operators a stable vocabulary for why a node is allowed, healthy, compatible, schedulable, warning-only, or blocked.
- Keep CLI, Console, Operator API, and Admin API behavior consistent enough that automation and human review speak the same language.
- Make risky node actions reviewable before execution, especially drain, maintenance, resume, and decommission.
- Let support and diagnostic workflows collect useful evidence without leaking secrets or collapsing local evidence logs into product truth.
- Show HA-lite leadership and advisory-lock status as read-only status first.

## Non-Goals

- Do not include product code in this OpenSpec-only change package; implementation tasks below are future slices.
- Do not define active/active controller behavior.
- Do not add HA-lite failover, leadership transfer, or standby mutation actions.
- Do not change scheduler ranking policy or dispatch behavior beyond explanation vocabulary.
- Do not make local research outputs product truth.
- Do not commit raw prompt exports, local context stores, tool identifiers, credentials, DSNs, or transient evidence logs.

## UX Direction

The cluster-management surface should feel operational, compact, and repeatable.
It should favor dense but readable tables, clear filtering, restrained status badges, secondary detail panels, and reason-code drill-ins over decorative presentation.
Dangerous actions should use explicit previews, concise consequence copy, affected-resource summaries, confirmation requirements, and visible success or failure feedback.
Support bundle generation should start from scope selection, show included and omitted evidence categories, expose redaction status, and produce the same artifact contract from CLI and Console.
These UX conclusions are subordinate to `SPEC.md`, `docs/brand-identity.md`, `docs/DESIGN.md`, and the accepted OpenSpec requirements below.

## Decision Ledger

| Decision | Source | Why |
|----------|--------|-----|
| First-observed nodes enter pending admission and do not become `active` automatically. | `SPEC.md` §4.2, §4.3, §7.5.4, current `Orchard.Nodes` gap | Prevent accidental cluster expansion and reconcile current implementation with explicit admission. |
| Status presentation separates lifecycle, health, freshness, transport, runtime, compatibility, scheduling, and warnings. | `SPEC.md` §4.5, §4.6.1, §5.5, §7.5 | Operators need to know whether the problem is trust, reachability, runtime readiness, version compatibility, or scheduler policy. |
| Scheduler explanations use fixed reason codes shared by API, CLI, Console, support bundles, and tests. | `SPEC.md` §5.5, §7.3.5, §9.1 | Durable codes make automation and support analysis possible. |
| Node actions expose preview, eligibility, blockers, and consequences before mutation. | `SPEC.md` §4.4, §4.8, §7.3, §7.4, §13.4 | Cordon, drain, maintenance, resume, and decommission can affect live work. |
| Support bundle creation has shared CLI and Console semantics, including scope and redaction manifest. | `SPEC.md` §7.3, §9, §10.2, §11.9, current support bundle CLI | Operators need one evidence artifact, not separate Console-only and CLI-only formats. |
| HA-lite starts read-only in Console and CLI. | `SPEC.md` §3.3, §12.6, §13.3 | Leadership and lock state are high-risk control-plane facts and mutating actions need a separate design. |

## UX Model

The cluster surface answers three operator questions.
First: who is allowed in this cluster.
Second: who is healthy, compatible, fresh, and schedulable right now.
Third: what action is safe next.

Console should organize these as a Nodes workspace with a pending admission queue, an admitted node inventory, per-node detail, scheduler explanation drill-in, diagnostics/support actions, and a read-only control-plane status section.
The existing `NodesLive` split between persisted inventory and live Runtime Endpoint diagnostics is a good starting structure.
The next implementation should add pending admission and action review without turning the page into a single mixed table of ambiguous badges.

CLI should expose the same facts with stable command output and JSON modes.
Human-readable table output can stay compact, but `--json` output should preserve the same reason-code arrays and status groups that Console receives.

Operator API and Admin API remain the machine contract.
Console and CLI should be clients of the same domain semantics, even when the first implementation calls local contexts directly.

## Signal Taxonomy

Lifecycle answers whether Orchard is allowed to use the node.
Values come from `SPEC.md` §4.2.

Admission answers whether a first-observed or registered node is waiting for admin review, admitted, rejected, or removed.
Admission is not the same as current scheduler eligibility.
Pending admission is an admission category, not a new node lifecycle enum, unless `SPEC.md` is first reconciled to add such a lifecycle state.
Pending nodes remain in `provisioned` or `registered` lifecycle states until admitted.
First-observed Runtime Endpoint observations that do not match an existing provisioned placeholder or registered node are observed admission candidates outside the node lifecycle state machine.
Observed candidates are not `provisioned`, because no admin-created placeholder or bootstrap exists.
Observed candidates are not `registered`, because `RegisterNode` or equivalent `SPEC.md` §4.4 trust proof has not completed.
Observed candidates may appear in admission review, but admit execution is blocked until they are reconciled to a registered node with required trust, inventory, pool, and policy inputs.
Provisioned placeholders may appear in review, but admit execution is blocked until registration inventory, trust evidence, pool assignment, and required policy inputs are present.
Rejected pending admission is an auditable admission decision for a non-admitted node and is not `decommissioning`.
Rejected admission is stored as admission decision metadata on the admission candidate or node admission record.
The decision includes `decision=rejected`, actor, decided timestamp, reason, observed identity or node reference, target reference when applicable, and audit event reference.
For lifecycle-managed node rows, rejection leaves lifecycle as `provisioned` or `registered` and sets admission category to `rejected`.
Re-admission after rejection requires an explicit admin clear action or a new registration and trust event recorded in audit.

## Persistence Model

`SPEC.md` §8 defines `node_admission_candidates` for first-observed Runtime Endpoint metadata and review state before the observation becomes a trusted Node.
Rows may also link to provisioned placeholders or registered Nodes through `node_id`.
The table stores source, admission category, sanitized observed identity, sanitized target reference, endpoint transport and target reference, inventory, compatibility evidence, and optional last observation timestamp.
The last observation timestamp is required for first-observed Runtime Endpoint observation rows and whenever the row represents a concrete Runtime Endpoint observation, but may be null for provisioned placeholder or registered-node review rows before an observation occurs.
This keeps admission review state outside the Node Lifecycle State machine while still making pending, rejected, and admitted review categories queryable.
Linked candidates should reference their Node when created, but that reference may become null after retention cleanup.
The candidate must retain enough bounded snapshot fields to remain understandable after the linked Node row is removed.
Target references remain non-authoritative operator-review fields and are indexed for lookup, not uniqueness or reconciliation identity.

`SPEC.md` §8 defines `node_admission_decisions` for durable rejection, rejection-clearance, and admission-after-rejection decisions.
Decision rows append history and include candidate or node reference, decision kind, actor, reason, observed identity, target reference, audit log reference, and decided timestamp.
Implementation must not update a prior decision row to rewrite history.
Later decisions append new rows.
Decision rows should reference a candidate or node when created, but those references may become null after retention cleanup.
The decision must retain enough bounded snapshot fields to remain understandable after referenced candidate or node rows are removed, even if an audit reference is no longer present after retention cleanup.
Node admission decisions use cluster-scoped audit events unless a future accepted contract makes the action tenant-owned.

Candidate and decision metadata must be sanitized and bounded.
It must not contain plaintext secrets, credentials, DSNs, prompt bodies, response bodies, raw local evidence logs, local tool session identifiers, or machine-specific prompt exports.

Freshness answers whether the latest heartbeat or Runtime Endpoint observation is current under `SPEC.md` §4.5 thresholds.
Freshness values should be `fresh`, `stale`, `unreachable`, and `unknown`.

Transport answers whether the configured Runtime Endpoint target can be contacted.
Transport values should be `reachable`, `timeout`, `connect_failed`, `identity_mismatch`, `target_unconfigured`, and `unknown`.

Runtime readiness answers whether the Runtime Endpoint can accept runtime work.
Runtime values should preserve `StatusResponse.runtime_health.health_code` when present and normalize missing legacy status as compatibility detail rather than probe failure.

Compatibility answers whether the node agent, runtime endpoint, and reported features are compatible with the controller.
Compatibility values should be `compatible`, `legacy_metadata`, `partial_metadata`, `version_skew`, `unsupported_version`, and `unknown`.

Scheduling answers whether the scheduler could consider the node for new work.
Scheduling values should be derived from fixed reason codes rather than a free-text sentence.

Warnings answer operator attention needs that do not by themselves decide lifecycle or scheduling.
Warnings include degraded health causes, swap pressure, thermal pressure, low disk, old metadata, and observe-only telemetry risks.

HA-lite answers which controller is leader, whether this controller is leader or standby, lock age, last renew time, and write-path behavior.
This status is read-only in this foundation.

## Reason-Code Vocabulary

Scheduler explanation rejection codes should include these initial stable values:

- `inventory_missing`
- `node_not_admitted`
- `node_not_active`
- `node_not_registered`
- `node_health_unreachable`
- `node_health_unhealthy`
- `node_observation_stale`
- `transport_unreachable`
- `runtime_not_ready`
- `runtime_identity_mismatch`
- `version_incompatible`
- `pool_not_allowed`
- `model_format_unsupported`
- `model_not_available_on_node`
- `insufficient_memory`
- `node_concurrency_exhausted`
- `placement_concurrency_exhausted`
- `placement_suppressed`
- `node_circuit_breaker_open`
- `model_load_suppressed`
- `policy_required`
- `pool_required`
- `queue_lane_capacity_unavailable`
- `trust_not_established`
- `unknown_capacity`

Action preview blocker codes should include these initial stable values:

- `requires_admin`
- `requires_operator`
- `node_not_found`
- `node_not_pending_admission`
- `node_not_admitted`
- `node_not_active`
- `node_not_registered`
- `node_unreachable`
- `inventory_missing`
- `drain_already_running`
- `decommission_already_running`
- `maintenance_requires_drain`
- `ha_standby_write_blocked`
- `cluster_lock_unavailable`
- `version_incompatible`
- `pool_required`
- `policy_required`
- `trust_not_established`

Action preview confirmation requirement codes should include these initial stable values:

- `requires_yes_flag`
- `requires_typed_node_id`
- `requires_reason`
- `requires_drain_consequence_acknowledgement`
- `requires_decommission_consequence_acknowledgement`

Action preview consequence codes should include these initial stable values:

- `active_requests_present`
- `would_cancel_active_requests`
- `existing_requests_continue_until_deadline`

Support bundle and diagnostics scope codes should include:

- `cluster`
- `node`
- `request`
- `scheduler_decision`
- `runtime_endpoint`
- `control_plane`
- `ha_lite`

These vocabularies are intentionally small enough for tests and docs to lock down.
Future implementation may add codes, but it should not replace accepted codes without a SPEC reconciliation.

## Safe Action Model

Every eligibility-changing or destructive action should have a preview.
The preview should return the current node state, current health, freshness, active request count when known, scheduler eligibility summary, blockers, warnings, consequence codes, confirmation requirements, expected state transition, and whether confirmation is required.
Blockers are non-bypassable safety or permission constraints.
Consequence codes describe effects that may be accepted only through explicit action parameters or confirmation requirements.
Confirmation requirements are user acknowledgements or typed values that can be satisfied without bypassing blockers.
Action execution should revalidate permissions, leadership and write-path availability, lifecycle state, health, active request count when relevant, and blockers at mutation time.
A prior preview should not authorize mutation if execution-time blockers are present.
Confirmation requirements and consequence flags should not bypass blockers.

Low-risk actions such as refresh and diagnostics may run directly with visible progress and failure feedback.
Cordon, uncordon, maintenance resume, and admit require explicit permission checks and an action preview.
Drain requires a deadline, `cancel_after_deadline`, `enter_maintenance`, active request summary, and post-deadline consequence copy.
Decommission requires admin authority, affected trust material, active request handling, no rejoin with the same `node_id`, and explicit typed confirmation or an equivalent CLI confirmation flag.
Rejecting a pending admission is not the same as decommissioning an admitted node.

Console should present action previews in focused dialogs.
CLI should expose `--dry-run` and `--json` for previews, and require `--yes` plus any action-specific confirmation value for non-interactive destructive execution.

## Diagnostics And Support Bundles

Diagnostics and support bundle creation should share a single mental model.
Operators choose a scope, review included evidence categories, see redaction status, generate the artifact, and receive a durable path or download result.

This change defines `orchard.support_bundle.v2` for shared Console and CLI cluster-management bundles.
The v2 support bundle manifest should include bundle format, generated time, Orchard version, scope, included sections, omitted sections, redaction manifest, max log bytes, and relevant SPEC references.
The existing v1 support bundle command may remain for compatibility only if v2 behavior is explicitly selected or made the default in the implementation slice.
The fields required by this change are mandatory for the v2 contract.
The redaction manifest should list redaction classes and counts, not secret values.
Support bundles must exclude plaintext secrets, credentials, DSNs, prompt bodies, response bodies, raw token sequences, raw local evidence logs, and tool session identifiers.
Scoped bundles should include only evidence relevant to the selected scope and should record omitted sections.
Request and scheduler-decision scopes should include sanitized metadata only and should not include prompt bodies, response bodies, raw token sequences, raw prefix-cache fingerprints, or tenant secret material.

Console-triggered bundles should produce the same v2 archive format as `orchardctl support bundle create`.
Console may add a guided wizard, but it must not create a separate support artifact contract.

## HA-Lite Read-Only Status

The first HA-lite UX should show read-only control-plane state.
At minimum it should show deployment mode, this controller identity, leader identity when known, advisory-lock status, lock age, last renewal, standby write-path behavior, and last observed leadership error.

Standby controllers must make write-path limits obvious.
`SPEC.md` §3.3 says standby may serve liveness but must return `503 controller_standby` for write paths if directly addressed.
Console and CLI should explain that behavior without offering leadership mutation controls in this foundation.

## Alternatives Considered

Alternative: keep auto-discovery as `active` and add admission later.
This conflicts with `SPEC.md` §4.2 and §7.5.4 and makes the first safe cluster UX harder to reason about.

Alternative: show one combined status badge per node.
That is compact, but it hides whether an operator should fix trust, transport, runtime, compatibility, policy, capacity, or lifecycle.

Alternative: build Console first and let CLI follow.
That risks mismatched vocabulary and makes automated operations weaker.
The contract should define shared semantics first, then allow UI-specific presentation differences.

Alternative: include HA-lite failover actions now.
That increases risk before the read-only status model and permission/audit contract are stable.

## Migration Plan

1. Add accepted OpenSpec and SPEC reconciliation before changing product code.
2. Add observed admission candidate persistence for first-observed Runtime Endpoint observations that are not yet lifecycle-managed nodes.
3. Update the node persistence model so first-observed nodes do not become `active` without explicit admission.
4. Add rejected-admission decision metadata and audit handling.
5. Add CLI parity commands and JSON contracts for list, detail, admission, rejection, actions, explanations, and support bundles.
6. Add Console pending admission, detail drill-in, action preview dialogs, diagnostics entry points, and HA-lite read-only status.
7. Add scheduler explanation persistence and rendering using fixed reason-code vocabularies.
8. Add tests that cite the accepted SPEC sections and verify CLI/Console parity.
9. Run the applicable Elixir quality workflow for implementation slices.

Rollback for implementation should preserve existing node inventory rows and avoid deleting durable state.
If a migration introduces pending-admission state, it should classify existing source-dev observed rows conservatively and document how operators review them.
