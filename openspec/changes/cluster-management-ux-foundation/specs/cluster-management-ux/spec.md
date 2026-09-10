## ADDED Requirements

### Requirement: Pending Admission Is Explicit
Orchard SHALL treat first-observed, provisioned, or registered nodes as pending admission until an authorized admin explicitly admits them.
Pending admission SHALL be represented as an admission category derived from lifecycle and admission metadata, not as a new node lifecycle enum, unless `SPEC.md` is first updated to add such a lifecycle state.
Pending nodes SHALL remain in `provisioned` or `registered` lifecycle states until admitted.
First-observed Runtime Endpoint observations that do not match an existing provisioned placeholder or registered node SHALL be stored as observed admission candidates outside the node lifecycle state machine.
Observed admission candidates SHALL NOT be represented as `provisioned` unless an admin-created placeholder or bootstrap exists.
Observed admission candidates SHALL NOT be represented as `registered` unless `RegisterNode` or equivalent trust proof required by `SPEC.md` §4.4 has completed.
Observed admission candidates MAY appear in admission review, but admit execution SHALL be blocked until they are reconciled to a registered node with required trust, inventory, pool, and policy inputs.
Pending admission nodes SHALL NOT be schedulable.
Pending admission nodes SHALL retain observed inventory, target metadata, compatibility evidence, and last observation timestamps for review when observations exist.
Successful Runtime Endpoint observation alone SHALL NOT transition a node to `active`.
Provisioned nodes MAY appear in the admission review surface, but admit execution SHALL be blocked until registration inventory and trust evidence required by `SPEC.md` §4.4 are present.
This refines `SPEC.md` §4.2, §4.3, §4.4, and §7.5.4.

#### Scenario: First-observed node waits for admission
- **WHEN** a new node-agent first reports valid Runtime Endpoint metadata to the Controller
- **THEN** Orchard records an observed admission candidate for operator review when no matching provisioned placeholder or registered node exists
- **AND** Orchard does not represent the observation as `provisioned` or `registered` without the corresponding SPEC-defined evidence
- **AND** Orchard does not mark the candidate `active`
- **AND** Orchard does not include the candidate in scheduler candidates

#### Scenario: Admin admits pending node
- **WHEN** an authorized admin admits a pending node with required pool and policy inputs
- **THEN** Orchard records an admission audit event
- **AND** Orchard transitions the node according to the lifecycle rules in `SPEC.md` §4.3
- **AND** the node becomes schedulable only after the required healthy post-admission signal is present

#### Scenario: Provisioned placeholder lacks registration evidence
- **WHEN** an authorized admin previews admission for a provisioned placeholder without registration inventory or trust evidence
- **THEN** Orchard blocks admission execution
- **AND** Orchard reports blocker codes `node_not_registered`, `inventory_missing`, and `trust_not_established` as applicable

### Requirement: Rejected Admission Is Auditable And Non-Schedulable
Pending-admission rejection SHALL persist an auditable admission decision without deleting observed inventory.
Rejected admission SHALL be stored as admission decision metadata on the admission candidate or node admission record.
Rejected admission decision metadata SHALL include `decision = rejected`, actor, decided timestamp, reason, observed identity or node reference, target reference when applicable, and audit event reference.
For lifecycle-managed node rows, rejection SHALL leave lifecycle as `provisioned` or `registered` and set admission category to `rejected`.
Rejected pending admission SHALL NOT use the `decommissioning` lifecycle state.
Rejected pending admission SHALL remain non-schedulable and visible for review.
Rejected pending admission SHALL NOT allow rejoin or admission behavior that bypasses the normal registration and trust checks in `SPEC.md` §4.4 and §7.5.4.
Re-admission after rejection SHALL require an explicit admin clear action or a new registration and trust event recorded in audit.
This refines `SPEC.md` §4.2, §4.3, §4.4, and §7.5.4.

#### Scenario: Admission decision persistence is append-only
- **WHEN** an authorized admin rejects pending admission and later clears that rejection
- **THEN** Orchard records one `node_admission_decisions` row for rejection
- **AND** Orchard records a later `node_admission_decisions` row for rejection clearance
- **AND** Orchard does not update the original rejection row to erase the historical decision

#### Scenario: Admin rejects pending admission
- **WHEN** an authorized admin rejects a pending node admission
- **THEN** Orchard records an auditable rejection decision
- **AND** Orchard keeps the node non-schedulable
- **AND** Orchard does not transition the node to `decommissioning`

### Requirement: Admission Review Persistence Is Explicit
Orchard SHALL persist first-observed Runtime Endpoint admission candidates in `node_admission_candidates` until they are resolved by admin review.
`node_admission_candidates` SHALL include source, admission category, optional node reference, sanitized observed identity, sanitized target reference, endpoint transport and target reference, inventory, compatibility evidence, and optional last observation timestamp.
`node_admission_candidates.admission_category` SHALL be review state and SHALL NOT add or replace a `node_state` lifecycle enum.
Candidate rows SHOULD reference the linked Node when created for provisioned-placeholder or registered-node sources if that Node row exists.
Candidate rows MAY later have a null node reference after retention cleanup, because bounded snapshot fields preserve admission review evidence.
Candidate rows SHALL populate last observation timestamp when `source = 'runtime_endpoint_observation'` and whenever the row represents a concrete Runtime Endpoint observation.
Candidate rows MAY have a null last observation timestamp before an observation exists.
Candidate lookup indexes MAY include sanitized target reference, but target reference SHALL NOT be treated as a unique candidate identity.
Orchard SHALL persist rejection, rejection clearance, and admission-after-rejection decisions in `node_admission_decisions`.
`node_admission_decisions` SHALL include candidate or node reference, decision kind, actor, decided timestamp, reason, observed identity, target reference when applicable, audit event reference, and bounded metadata.
Admission decision history SHALL be append-only.
Admission decision rows SHOULD reference a candidate or Node when created if that row exists.
Admission decision rows MAY later have null candidate and Node references after retention cleanup, because bounded snapshot fields preserve the durable decision record.
Candidate and decision metadata SHALL be sanitized and MUST NOT include plaintext secrets, credentials, DSNs, prompt bodies, response bodies, raw local evidence logs, local tool session identifiers, or machine-specific prompt exports.
Node Admission candidate review, rejection, rejection clearance, admission after rejection, decommission, and Active/Standby write-path decisions SHALL use cluster-scoped audit events with no tenant id.
Candidate review queries SHALL have indexes for admission category and recent observation time.
Recent-observation indexes SHALL order candidates without an observation timestamp after candidates with observed timestamps.
Decision review queries SHALL have indexes by candidate, node, and audit log reference.
This refines `SPEC.md` §8.1 through §8.5.

#### Scenario: First observation stores review evidence
- **WHEN** Orchard observes Runtime Endpoint metadata that does not match a provisioned placeholder or registered Node
- **THEN** Orchard stores a `node_admission_candidates` row with sanitized observed identity, target reference, inventory, compatibility evidence, and last observation timestamp
- **AND** Orchard does not create a trusted Node row from that observation alone

#### Scenario: Linked candidate survives node retention
- **WHEN** a provisioned-placeholder or registered-node admission candidate remains after its linked Node row is removed by retention cleanup
- **THEN** Orchard preserves the `node_admission_candidates` row
- **AND** the candidate row may retain a null node reference
- **AND** the candidate remains understandable from its source, admission category, observed identity, target reference, inventory, and compatibility evidence

#### Scenario: Unobserved candidate does not invent freshness
- **WHEN** Orchard creates a provisioned-placeholder or registered-node review row before any Runtime Endpoint observation has occurred
- **THEN** Orchard stores the candidate without a last observation timestamp
- **AND** review ordering does not treat the missing timestamp as more recent than observed candidates
- **AND** Orchard does not fabricate observation freshness

#### Scenario: Target reference is not unique identity
- **WHEN** two pending or rejected admission candidates share the same sanitized target reference
- **THEN** Orchard may retain both candidate rows independently
- **AND** Orchard does not reconcile or overwrite either candidate based on target reference alone

#### Scenario: Rejection is traceable to audit
- **WHEN** an authorized admin rejects an admission candidate
- **THEN** Orchard stores a `node_admission_decisions` row with decision `rejected`
- **AND** the decision row references the related audit event when the audit write succeeds
- **AND** the related audit event is cluster-scoped and has no tenant id
- **AND** the candidate remains visible as `rejected`

#### Scenario: Decision survives candidate retention
- **WHEN** a resolved admission candidate is removed by retention cleanup before the corresponding admission decision expires
- **THEN** Orchard preserves the `node_admission_decisions` row
- **AND** the decision row may retain null candidate and Node references
- **AND** the decision remains understandable from its snapshot fields and any retained audit reference

### Requirement: Cluster Status Separates Signal Categories
Orchard Console, CLI, Operator API, and Admin API SHALL present node and cluster status as separate signal categories rather than a single combined status badge.
The categories SHALL include lifecycle, admission, health, heartbeat freshness, transport reachability, runtime readiness, compatibility, scheduling eligibility, warnings, and control-plane status when available.
Health SHALL remain orthogonal to lifecycle state.
Runtime readiness SHALL remain distinct from transport reachability.
Compatibility warnings SHALL remain distinct from scheduler eligibility.
This refines `SPEC.md` §3.3, §4.2, §4.5, §4.6.1, §5.5, and §7.5.

#### Scenario: Node is reachable but not schedulable
- **WHEN** a node is transport-reachable and runtime-ready but lifecycle state is `cordoned`
- **THEN** Orchard shows transport as reachable
- **AND** Orchard shows runtime readiness as ready when the Runtime Endpoint reports readiness
- **AND** Orchard shows scheduling eligibility as blocked with reason code `node_not_active`

#### Scenario: Runtime metadata is legacy
- **WHEN** a Runtime Endpoint responds without newer metadata fields
- **THEN** Orchard shows compatibility as `legacy_metadata` or `partial_metadata`
- **AND** Orchard does not convert missing optional metadata into a transport failure

### Requirement: Scheduler Explanations Use Stable Reason Codes
Scheduler explanations SHALL expose stable reason codes for selected, skipped, and rejected candidates.
Reason codes SHALL be shared by Operator API, CLI, Console, and tests.
Reason codes SHALL be machine-readable and SHALL NOT be replaced by free-text-only explanations.
Rejected candidates SHALL include at least one stable rejection reason code.
Selected candidates MAY have an empty reason-code array.
Skipped candidates SHALL be represented in a `skipped_candidates` collection outside the rejected-candidate list.
Skipped candidates SHALL include at least one stable skip reason code.
The initial scheduler rejection vocabulary SHALL include `inventory_missing`, `node_not_admitted`, `node_not_active`, `node_not_registered`, `node_health_unreachable`, `node_health_unhealthy`, `node_observation_stale`, `transport_unreachable`, `runtime_not_ready`, `runtime_identity_mismatch`, `version_incompatible`, `pool_not_allowed`, `model_format_unsupported`, `model_not_available_on_node`, `insufficient_memory`, `node_concurrency_exhausted`, `placement_concurrency_exhausted`, `placement_suppressed`, `node_circuit_breaker_open`, `model_load_suppressed`, `policy_required`, `pool_required`, `queue_lane_capacity_unavailable`, `trust_not_established`, and `unknown_capacity`.
The initial scheduler skip vocabulary SHALL include `lower_tier_not_considered`, `not_scored_after_selection`, `not_applicable_to_request`, and `candidate_limit_reached`.
This refines `SPEC.md` §5.5, §5.7, §5.8, §5.10, and §7.3.5.

#### Scenario: Explanation includes rejected candidate codes
- **WHEN** an operator inspects a scheduler explanation for a request
- **THEN** each rejected candidate includes at least one stable reason code
- **AND** any human-readable message is supplemental to the reason codes

#### Scenario: Explanation matches decision
- **WHEN** the scheduler rejects a node because it is in `maintenance`
- **THEN** the explanation includes `node_not_active`
- **AND** the Console and CLI render the same underlying reason code

#### Scenario: Explanation includes skipped candidate codes
- **WHEN** the scheduler does not score lower-tier candidates because loaded candidates are available
- **THEN** the explanation may include those candidates in `skipped_candidates`
- **AND** each skipped candidate includes `lower_tier_not_considered`
- **AND** skipped candidates are not reported as rejected candidates

### Requirement: CLI And Console Expose Equivalent Cluster Management Semantics
Orchard CLI and Orchard Console SHALL expose equivalent cluster-management semantics for node list, node detail, pending admission review, admission, lifecycle action previews, scheduler explanations, diagnostics, and control-plane read-only status.
CLI output MAY differ visually from Console, but JSON output SHALL preserve the same status categories and reason-code arrays.
Console copy SHALL not invent meanings that are absent from the shared domain contract.
This refines `SPEC.md` §7.3, §7.4, §11.8, and §11.9.

#### Scenario: CLI and Console show the same reason codes
- **WHEN** a node is blocked from scheduling because its Runtime Endpoint observation is stale
- **THEN** Console renders scheduling eligibility with reason code `node_observation_stale`
- **AND** the corresponding CLI JSON output includes `node_observation_stale`

#### Scenario: CLI preview matches Console preview
- **WHEN** an operator previews a drain action in Console and via CLI JSON
- **THEN** both surfaces report the same blockers, warnings, active request count when known, expected transition, and confirmation requirement

#### Scenario: CLI reject preview matches Console preview
- **WHEN** an operator previews pending admission rejection in Console and via CLI JSON
- **THEN** both surfaces report the same blockers, warnings, audit action, and confirmation requirement
- **AND** both surfaces record rejection as admission decision metadata when execution succeeds

### Requirement: Node Actions Require Previews And Consequence Disclosure
Eligibility-changing or destructive node actions SHALL provide a preview before execution.
The preview SHALL include current lifecycle state, health, freshness, active request count when known, scheduler eligibility summary, blockers, warnings, consequence codes, confirmation requirements, expected state transition, audit action, and whether confirmation is required.
Blockers SHALL be non-bypassable safety, permission, leadership, write-path, lifecycle, or data-integrity constraints.
Consequence codes SHALL describe effects that may be accepted only through explicit action parameters or confirmation requirements.
Confirmation requirements SHALL be user acknowledgements or typed values that can be satisfied without bypassing blockers.
Action execution SHALL revalidate permissions, leadership and write-path availability, current lifecycle state, current health, active request count when relevant, and blockers at mutation time.
A prior preview SHALL NOT authorize mutation if execution-time blockers are present.
Confirmation SHALL acknowledge disclosed consequences only.
Confirmation requirements and consequence flags SHALL NOT bypass blockers.
Drain previews SHALL include deadline, `cancel_after_deadline`, `enter_maintenance`, and remaining active work consequences.
Decommission previews SHALL include trust revocation, future scheduling revocation, active work handling, no rejoin with the same `node_id`, and explicit confirmation requirement.
This refines `SPEC.md` §4.4, §4.8, §7.3, §7.4, §12.7, §13.4, and §13.7.

#### Scenario: Drain preview blocks unsafe default cancellation
- **WHEN** an operator previews drain for a node with active requests and `cancel_after_deadline=false`
- **THEN** Orchard shows the active request count when known
- **AND** Orchard includes consequence codes `active_requests_present` and `existing_requests_continue_until_deadline`
- **AND** Orchard does not claim those requests will be cancelled by default

#### Scenario: Decommission requires confirmation
- **WHEN** an admin attempts to decommission an admitted node
- **THEN** Orchard requires explicit confirmation before mutation
- **AND** Orchard reports a decommission confirmation requirement until confirmation is supplied
- **AND** Orchard does not report confirmation requirements as blockers

#### Scenario: Preview becomes stale before execution
- **WHEN** an operator previews a drain action with no active requests
- **AND** active requests appear before the operator confirms execution
- **THEN** Orchard revalidates the action at execution time
- **AND** Orchard does not execute the stale preview as if the node still had no active requests

### Requirement: Cancel Drain Provides A Draining Recovery Path
Orchard SHALL provide a `cancel_drain` node action that transitions a node from `draining` to `cordoned`.
Cancel drain SHALL stop further waiting for active-request quiescence and SHALL leave the node unschedulable as `cordoned`.
Cancel drain SHALL NOT certify drain completion and SHALL NOT weaken the `drain_completion_unverified` blocker on manual `draining -> maintenance` execution.
Cancel drain SHALL NOT restore, replay, or migrate back work that completed, was cancelled, or quiesced while the drain ran.
Cancel drain SHALL be allowed only from `draining`; execution from any other lifecycle state SHALL produce a `drain_not_running` blocker.
Cancel drain SHALL use the shared action preview, confirmation, blocker, audit, and mutation-time revalidation vocabulary defined for other lifecycle actions.
This refines `SPEC.md` §4.3, §4.4, and §4.8 per ADR 0009.

#### Scenario: Operator cancels a drain that no longer needs to run
- **WHEN** an operator executes `cancel_drain` on a node in `draining`
- **THEN** Orchard transitions the node to `cordoned`
- **AND** the node remains excluded from scheduling until a separate `uncordon` action
- **AND** Orchard records a cluster-scoped audit event for the cancellation

#### Scenario: Cancel drain on a node that is not draining
- **WHEN** an operator previews or executes `cancel_drain` on a node that is not in `draining`
- **THEN** Orchard reports a `drain_not_running` blocker
- **AND** Orchard does not mutate the node

#### Scenario: Drain completes between preview and execution
- **WHEN** an operator previews `cancel_drain` for a draining node
- **AND** the node leaves `draining` before the operator confirms execution
- **THEN** Orchard revalidates at execution time and reports `drain_not_running`
- **AND** Orchard does not execute the stale preview

### Requirement: Diagnostics Reuse Shared Domain Contracts
Orchard diagnostics SHALL reuse the shared node status, request inspection, scheduler explanation, Runtime Endpoint observation, dispatch-capacity, and control-plane status contracts.
CLI, Console, and Operator API presentation MAY differ, but each surface SHALL preserve stable machine-readable codes and bounded sanitized metadata.
Diagnostics MUST NOT include plaintext secrets, credentials, DSNs, prompt bodies, response bodies, raw token sequences, raw local evidence logs, local tool session identifiers, machine-specific prompt exports, raw prefix-cache fingerprints, or tenant secret material.
This refines `SPEC.md` §7.3, §9, §10.2, §11.8, and §11.9.

#### Scenario: Operator inspects shared diagnostics
- **WHEN** an operator inspects a node, request, scheduler explanation, Runtime Endpoint observation, dispatch-capacity result, or control-plane status
- **THEN** Orchard presents the corresponding shared domain contract
- **AND** the surface preserves stable reason codes and bounded sanitized metadata

### Requirement: Control-Plane Status Is Read-Only In The First Cluster UX
Orchard SHALL expose control-plane status as read-only cluster status before any mutating Active/Standby control action is introduced.
The read-only status SHALL include deployment mode, this controller identity when known, leader identity when known, advisory-lock status, lock age, last renewal timestamp, standby write-path behavior, and last observed leadership error when available.
Console and CLI SHALL NOT expose leadership transfer, failover, or standby mutation actions under this foundation change.
This refines `SPEC.md` §3.3, §12.6, and §13.3.

#### Scenario: Standby controller is directly addressed
- **WHEN** an operator views Active/Standby control-plane status from a standby controller
- **THEN** Orchard shows that the controller is standby when known
- **AND** Orchard explains that write paths return `503 controller_standby` when directly addressed
- **AND** Orchard does not offer a failover action in this foundation change

#### Scenario: Leadership status is unavailable
- **WHEN** advisory-lock status cannot be read
- **THEN** Orchard shows control-plane status as unknown or unavailable
- **AND** Orchard does not infer leadership from local process state alone
