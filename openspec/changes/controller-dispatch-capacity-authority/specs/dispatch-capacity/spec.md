## MODIFIED Requirements

### Requirement: Capacity Authority Persistence
Orchard SHALL persist one cluster-scoped dispatch-capacity authority singleton initialized in enforcement phase `pre_cutover`, with a positive required contract version.
Orchard SHALL persist one policy for each governed admitted production Node and SHALL distinguish `shadow_legacy`, `approved_explicit`, and `enforcing` from missing policy.
A policy ceiling MUST be a non-negative integer for `approved_explicit` and `enforcing` and MUST be null only for `shadow_legacy`.
Only the approved enforcement-cutover workflow MAY advance the durable phase or a policy to `enforcing`.
Every admitted production Node SHALL have one durable Controller dispatch capacity policy.
Registered but unadmitted production inventory SHALL NOT enter the migration cohort or require dispatch policy until Node Admission commits.
The operational cohort SHALL end only when lifecycle `removed`, trust revocation, and the removal audit commit durably.
A removed tombstone SHALL retain historical policy evidence but SHALL NOT block approval, compatibility preflight, zero-occupancy quiescence, or cutover.
Later re-enrollment SHALL pass a new Node Admission and persist policy under the then-current phase.
Except for the bounded pre-F11 cohort while its policy state is `shadow_legacy`, that policy SHALL have an explicit non-negative Controller Dispatch Ceiling.
The `shadow_legacy` record SHALL deliberately have no ceiling, SHALL authorize none of the new production capacity semantics, and SHALL remain distinct from a missing policy record.
An explicit ceiling of `0` SHALL be valid policy and SHALL remain distinct from missing policy.
It SHALL stop new allocation only under `f11_enforcing`; before cutover, it SHALL be approved but not yet authoritative.
A missing policy or missing ceiling for an admitted production Node SHALL yield Effective Dispatch Limit `0`.
A permanent null ceiling meaning runtime-managed capacity SHALL be prohibited.
The durable ceiling SHALL NOT be inferred or backfilled from Runtime Endpoint telemetry.
Existing production Nodes SHALL migrate through `shadow_legacy`, `approved_explicit`, and `enforcing` in that order.
`shadow_legacy` SHALL apply only to non-removed production Nodes whose Node Admission committed before the F11 expand migration, selected from durable admission evidence, and SHALL be temporary and counterfactual.
Operator approval SHALL persist a ceiling, actor, timestamp, and reason before policy becomes `approved_explicit`.
No policy SHALL become `enforcing` until every named consumer uses the shared evaluation.
After cutover, every otherwise eligible non-removed admitted production Node SHALL have enforcing explicit policy or fail closed.
The durable phase SHALL take the values `pre_cutover` and `enforcing` and SHALL carry cutover provenance.
The phase row SHALL exist for an empty cluster and SHALL NOT be inferred from Node policy rows, Controller version, transport, or cluster occupancy.
Cutover SHALL use the migration advisory lock and one transaction to validate the expected phase and fresh compatible all-consumers-ready evidence for every non-retired Controller, advance approved policies, record provenance, and change the phase atomically.
Before that transaction, cutover SHALL enter a visible Controller-local quiescing barrier, refuse new temporary legacy claims, wait for zero live temporary claims and a new fresh aggregate observation reporting zero active requests for every non-removed admitted production Node, then acquire every applicable per-Node acceptance gate in stable order and revalidate the zero-occupancy boundary.
Cutover SHALL exclude a removed tombstone only when durable lifecycle `removed`, revoked trust, and the existing successful removal audit all prove the exclusion; every other lifecycle state and unreachable Node SHALL remain a blocker.
Cutover SHALL hold those gates through commit and local phase publication, SHALL NOT adopt live legacy work into Controller-accounted Allocation, and SHALL reopen legacy dispatch without phase or policy changes when quiescence or revalidation fails.
This refines `SPEC.md` §4.1, §4.4, §4.6.2, §8, §8.3, §10.9, and §13.2.

#### Scenario: Expand migration creates bounded legacy shadow rows
- **WHEN** the expand migration finds a non-removed production Node with durable successful admission evidence committed before the migration boundary
- **THEN** Orchard creates exactly one `shadow_legacy` policy linked to that evidence
- **AND** the policy has no Controller Dispatch Ceiling
- **AND** Orchard does not assign `1`
- **AND** the migration does not read runtime telemetry into policy

#### Scenario: Inventory without admission proof receives no authority
- **WHEN** an existing Node has no durable successful admission evidence before the migration boundary
- **THEN** Orchard does not create a synthetic policy or ceiling
- **AND** counterfactual evaluation reports missing policy

#### Scenario: Removed inventory is not operationally backfilled
- **WHEN** a Node is already durably `removed` at the expand migration boundary
- **THEN** Orchard does not create an operational `shadow_legacy` policy for that Node

#### Scenario: Explicit zero pauses new allocation
- **WHEN** under `f11_enforcing` an admitted production Node has Controller Dispatch Ceiling `0`
- **THEN** its Effective Dispatch Limit is `0`
- **AND** Orchard distinguishes the explicit policy from missing policy
- **AND** Orchard does not forcibly cancel accepted, running, or streaming work solely because of the policy value or change Node Lifecycle State

#### Scenario: Production policy is missing
- **WHEN** an admitted production Node has no durable policy record or no in-force explicit ceiling
- **THEN** its Effective Dispatch Limit is `0`
- **AND** Orchard does not infer ceiling `1` or copy a runtime limit into policy

#### Scenario: Enforcing policy ceiling is malformed
- **WHEN** an admitted production Node resolves an `enforcing` policy whose ceiling input is unavailable, malformed, or negative
- **THEN** its Effective Dispatch Limit is `0`
- **AND** Orchard exposes `controller_dispatch_ceiling_invalid`
- **AND** Orchard does not pass the invalid value to the minimum formula

#### Scenario: Shadow diagnostics are counterfactual
- **WHEN** a legacy Node lacks an explicit ceiling during the bounded shadow window
- **THEN** its counterfactual Effective Dispatch Limit is `0`
- **AND** any temporary legacy behavior is named and non-authoritative
- **AND** Orchard distinguishes the present `shadow_legacy` policy from a missing policy record
- **AND** Orchard exposes a shadow mismatch reason when legacy behavior differs

#### Scenario: Operator approves explicit policy
- **WHEN** an authorized operator approves a ceiling for a shadow Node
- **THEN** Orchard persists the value and provenance
- **AND** the policy becomes `approved_explicit`
- **AND** telemetry does not supply the value

#### Scenario: Enforcement cutover finds missing policy
- **WHEN** cutover evaluates an otherwise eligible admitted production Node without approved policy
- **THEN** Orchard excludes the Node with Effective Dispatch Limit `0`
- **AND** Orchard does not treat the missing record as legacy mode

#### Scenario: Cutover advances approved policy
- **WHEN** cutover verifies that every named semantic consumer uses the shared evaluation
- **AND** a legacy Node has an `approved_explicit` ceiling with approval provenance
- **THEN** Orchard advances that policy to `enforcing` as part of cutover
- **AND** the Node can have a non-zero Effective Dispatch Limit only after that advancement

#### Scenario: Cutover commits atomically
- **WHEN** cutover proves every non-removed admitted production Node has approved policy and every non-retired Controller has fresh capability evidence at the required version with all five consumers ready
- **AND** quiescing has reached zero live temporary claims and new fresh zero-active aggregate observations under the per-Node acceptance gates
- **THEN** Orchard advances approved policies and the phase to `enforcing` in one transaction
- **AND** Orchard records cutover actor, time, reason, and required contract version
- **AND** any failed precondition or write rolls back both policy and phase changes

#### Scenario: Cutover cannot reach zero occupancy
- **WHEN** a temporary legacy claim remains live or a fresh aggregate observation remains nonzero, stale, missing, or malformed until the quiescing deadline
- **THEN** Orchard leaves every policy and the durable phase unchanged
- **AND** Orchard reopens legacy dispatch and exposes `dispatch_capacity_cutover_occupancy_not_zero`

#### Scenario: Removed tombstone does not block cutover
- **WHEN** a former production Node has durable lifecycle `removed`, revoked trust, and a successful removal audit
- **THEN** cutover retains its historical policy but excludes it from approval and zero-occupancy blockers
- **AND** an unreachable, decommissioning, or otherwise non-removed Node receives no implicit exclusion
- **AND** later re-enrollment persists a new admission policy under the current phase

#### Scenario: Cutover excludes new legacy handoffs
- **WHEN** cutover enters its Controller-local quiescing barrier
- **THEN** Orchard refuses new temporary legacy claims with `dispatch_capacity_cutover_quiescing`
- **AND** existing accepted work drains without forced cancellation
- **AND** no pre-acceptance handoff crosses the phase commit

#### Scenario: Cutover expected version mismatches durable authority
- **WHEN** a cutover request's `expected_required_contract_version` differs from the locked singleton row
- **THEN** Orchard rejects cutover as an optimistic concurrency conflict
- **AND** Orchard does not change the durable required version, policy states, or enforcement phase

### Requirement: Pure Shared Capacity Evaluation
Orchard SHALL provide one pure transport-independent evaluator that accepts normalized policy, phase, management class, eligibility, freshness, capacity, allocation, placement, and temporary-claim inputs.
The evaluator SHALL return Runtime Concurrency Enforcement Limit, Controller Dispatch Ceiling, Effective Dispatch Limit, Controller-accounted Allocation, Dispatch Headroom, Placement Capacity, authority decision, decision-specific available slots, eligibility, and ordered stable reason codes.
In `pre_cutover`, canonical Effective Dispatch Limit and Dispatch Headroom SHALL remain `0` while the temporary legacy decision is calculated separately.
In `enforcing`, the evaluator SHALL calculate the approved minimum and headroom formulas and fail closed for every missing or invalid production prerequisite.
For a trusted, Active, healthy admitted production Node with scheduler-fresh heartbeat and capacity observations, durable cluster phase `enforcing`, in-force explicit policy, and valid runtime evidence, Orchard SHALL compute Effective Dispatch Limit as the smaller of Runtime Concurrency Enforcement Limit and Controller Dispatch Ceiling.
Orchard SHALL compute Effective Dispatch Limit `0` when any required gate fails.
Under `f11_enforcing`, health SHALL mean exactly `healthy`; `degraded` SHALL NOT authorize new production allocation.
Freshness SHALL require both the Node heartbeat and the capacity observation to remain within the scheduler freshness threshold.
Under `legacy_pre_cutover`, the shared evaluator SHALL calculate one temporary available-slot result as positive fresh runtime `max_concurrency` or fallback `1`, minus non-negative fresh aggregate `active_request_count` or fallback `0`, minus unique non-released Controller-local temporary legacy claims, floored at `0`.
That temporary branch SHALL require trusted identity, lifecycle `active`, health `healthy` or `degraded`, fresh heartbeat and observation, and existing pool, format, memory, placement, and breaker gates.
Every named consumer SHALL use that central result, and no legacy value SHALL be presented as Effective Dispatch Limit or Dispatch Headroom or persisted as policy.
Temporary legacy claim acquisition SHALL serialize across every placement and lane, retain the claim through Node acceptance and terminal completion, and release it exactly once.
Orchard SHALL compute Dispatch Headroom as the non-negative difference between Effective Dispatch Limit and Controller-accounted Allocation.
Controller-accounted Allocation SHALL count unique, non-released, Node-scoped logical allocations owned by the current Active Controller.
It SHALL exclude queued requests, unassigned grants, configured queue capacity, Node-reported active request counts, and Placement Capacity telemetry.
Allocation of the final unit of headroom SHALL be serialized.
Each request SHALL acquire at most one Node allocation, retain it through model loading and execution, and release it exactly once before retry or after failure, cancellation, or completion.
Dispatch Headroom SHALL authorize only acquisition of a new allocation.
Pre-acceptance revalidation SHALL serialize with allocation changes, exclude only the request's recognized allocation from the allocation operand, and require the resulting value to be positive without counting that claim twice.
Final revalidation SHALL share a per-Node acceptance gate with policy mutation and SHALL hold that gate continuously through Node acceptance or pre-acceptance failure.
Orchard SHALL require MultiNode, admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch-time revalidation to consume that single evaluation.
No named consumer SHALL re-derive the formulas, default missing production policy to `1`, or use configured queue capacity as dispatch authority.
Every consumer SHALL accept either `legacy_pre_cutover` with positive centrally calculated temporary slots and successful serialized temporary-claim acquisition or `f11_enforcing` with positive Dispatch Headroom.
Dispatch SHALL re-run the same decision after model loading and immediately before `ExecuteInference`, using held-claim revalidation under both decisions and retaining the per-Node acceptance gate through Node acceptance.
This refines `SPEC.md` §4.5, §4.6.2, §5.4, §5.5, and §5.9.

#### Scenario: Ceiling is the counterfactual binding limit
- **WHEN** an enforcing evaluator fixture has runtime limit `4`, Controller ceiling `2`, Controller-accounted Allocation `1`, and every eligibility gate satisfied
- **THEN** Effective Dispatch Limit is `2`
- **AND** Dispatch Headroom is `1`
- **AND** the authority decision is `f11_enforcing`

#### Scenario: Explicit zero remains explicit
- **WHEN** an enforcing evaluator fixture has Controller ceiling `0` and otherwise valid evidence
- **THEN** Controller Dispatch Ceiling is `0`
- **AND** Effective Dispatch Limit and Dispatch Headroom are `0`
- **AND** reason codes distinguish explicit zero from missing policy

#### Scenario: Pre-cutover values remain counterfactual
- **WHEN** a pre-cutover legacy fixture has fresh runtime maximum `3`, reported active count `1`, and one live temporary legacy claim
- **THEN** Effective Dispatch Limit and Dispatch Headroom are `0`
- **AND** temporary legacy available slots are `1`
- **AND** the authority decision is `legacy_pre_cutover`

#### Scenario: Production prerequisite fails closed
- **WHEN** an enforcing production-managed fixture lacks trusted fresh runtime-limit evidence
- **THEN** Effective Dispatch Limit and Dispatch Headroom are `0`
- **AND** eligibility is false
- **AND** its Controller Dispatch Ceiling alone does not prove positive capacity
- **AND** stable reason codes identify runtime-limit uncertainty

#### Scenario: All production gates pass
- **WHEN** a Node identity is trusted
- **AND** lifecycle is `active`
- **AND** health is `healthy`
- **AND** heartbeat and capacity observation are scheduler-fresh
- **AND** the ceiling and runtime limit are valid
- **AND** the durable cluster phase and policy state are both `enforcing`
- **THEN** Orchard derives the Effective Dispatch Limit with the minimum formula

#### Scenario: Pre-cutover policies use one legacy decision
- **WHEN** the durable cluster phase is `pre_cutover`
- **AND** an admitted production Node policy is `shadow_legacy` or `approved_explicit`
- **THEN** the shared evaluation reports counterfactual Effective Dispatch Limit and Dispatch Headroom `0`
- **AND** every named consumer receives the same explicit `legacy_pre_cutover` decision for named temporary legacy behavior
- **AND** the decision carries the centrally calculated temporary available slots
- **AND** Orchard does not present legacy values as either canonical F11 value

#### Scenario: Frozen legacy fallback remains temporary
- **WHEN** a fresh pre-cutover observation omits or zeroes runtime `max_concurrency`
- **AND** aggregate `active_request_count` is missing or malformed
- **THEN** the central legacy calculation uses limit `1` and reported allocation `0`
- **AND** Orchard still subtracts serialized live temporary legacy claims
- **AND** Orchard records `dispatch_capacity_pre_cutover_legacy`
- **AND** Orchard does not persist either fallback as Controller policy

#### Scenario: Phase and policy mismatch fails closed
- **WHEN** the cluster observes either `pre_cutover` with an `enforcing` policy or `enforcing` with a `shadow_legacy` or `approved_explicit` policy
- **THEN** Orchard permits no new allocation
- **AND** Orchard exposes `dispatch_capacity_phase_policy_mismatch`

#### Scenario: Identity is not trusted
- **WHEN** a target is unresolved, rejected, identity-mismatched, or otherwise untrusted
- **THEN** its Effective Dispatch Limit is `0`

#### Scenario: Lifecycle is not Active
- **WHEN** a trusted Node is `admitted`, `cordoned`, `draining`, `maintenance`, `decommissioning`, or `removed`
- **THEN** its Effective Dispatch Limit is `0`

#### Scenario: Health is degraded or unhealthy
- **WHEN** the decision is `f11_enforcing` and a trusted Active Node is `degraded`, `unhealthy`, or `unreachable`
- **THEN** its Effective Dispatch Limit is `0`
- **AND** a degraded Node exposes `node_health_degraded`
- **AND** existing work may finish under its existing lifecycle and failure contracts

#### Scenario: Capacity evidence is stale
- **WHEN** either the trusted Node heartbeat or Runtime Endpoint capacity observation exceeds the scheduler freshness threshold
- **THEN** its Effective Dispatch Limit is `0`
- **AND** Orchard clears Node-owned queue capacity sources

#### Scenario: Allocation leaves headroom
- **WHEN** Effective Dispatch Limit is `4`
- **AND** Controller-accounted Allocation is `1`
- **THEN** Dispatch Headroom is `3`

#### Scenario: Allocation equals or exceeds the limit
- **WHEN** Controller-accounted Allocation is greater than or equal to Effective Dispatch Limit
- **THEN** Dispatch Headroom is `0`
- **AND** Orchard allocates no new work to that Node

#### Scenario: Two requests race for one unit
- **WHEN** two concurrent requests attempt to acquire the final unit of Dispatch Headroom on one Node
- **THEN** exactly one request acquires the allocation
- **AND** the other request waits, retries, or fails under the existing queue contract

#### Scenario: Node occupancy telemetry is malformed
- **WHEN** Node-reported aggregate active-request telemetry is missing or malformed
- **THEN** Orchard does not use that value to increase Dispatch Headroom
- **AND** hardening the malformed telemetry path remains a separate follow-up

#### Scenario: All consumers evaluate the same Node fixture
- **WHEN** the same trusted Node, policy, observation, allocation, and placement fixture is evaluated through every named consumer
- **THEN** every consumer returns the same authority decision, available slots, canonical capacity values, and reason codes

#### Scenario: Ceiling changes during model loading
- **WHEN** under `f11_enforcing` a request holds a Node allocation while `EnsureModelLoaded` runs
- **AND** the ceiling is lowered so dispatch revalidation fails
- **THEN** Orchard does not call `ExecuteInference`
- **AND** Orchard excludes only that request's recognized allocation from the serialized allocation operand during revalidation
- **AND** Orchard releases the allocation exactly once
- **AND** Orchard requeues or fails under the existing deadline and public error contract

### Requirement: Atomic Admission Policy Persistence
Every new Node Admission SHALL lock and read the durable authority phase and atomically persist the admission transition, admission decision, cluster audit evidence, and phase-derived dispatch-capacity policy.
The shared Admin API and local CLI admission preview SHALL require a non-empty capacity policy reason, accept an optional non-negative ceiling, and resolve omission to explicit ceiling `1`.
While the phase is `pre_cutover`, admission SHALL persist `approved_explicit` and SHALL warn that the ceiling is not yet enforcing.
No telemetry value SHALL supply the default or override the explicit admission value.
Node Admission SHALL persist the policy atomically before the Node enters `admitted`, using an administrator-supplied value or the explicit default `1`, and SHALL record approval provenance.
After enforcement cutover, admission SHALL persist `enforcing` policy and its audit record directly rather than stranding the Node in `approved_explicit`.
This refines `SPEC.md` §4.6.2 and §13.2.

#### Scenario: Admission omission persists explicit one
- **WHEN** an administrator confirms admission with a non-empty capacity policy reason and omits the ceiling
- **THEN** the preview and transaction resolve Controller Dispatch Ceiling `1`
- **AND** the transaction persists `approved_explicit` under `pre_cutover`
- **AND** Orchard records approval provenance
- **AND** diagnostics report that the ceiling is not yet enforcing

#### Scenario: Administrator supplies a ceiling
- **WHEN** an administrator admits a registered production Node with an explicit non-negative ceiling
- **THEN** Orchard persists exactly that ceiling
- **AND** Orchard does not replace it with runtime telemetry

#### Scenario: Admission accepts explicit zero
- **WHEN** an administrator confirms admission with explicit ceiling `0` and a non-empty reason
- **THEN** Orchard persists explicit ceiling `0`
- **AND** Orchard does not replace it with the default or a telemetry value

#### Scenario: Policy failure rolls back admission
- **WHEN** policy or policy-audit persistence fails inside Node Admission
- **THEN** the Node lifecycle, admission candidate, admission decision, grants, policy, and audit writes all roll back

#### Scenario: Admission and phase use a stable lock order
- **WHEN** concurrent admission transactions operate while the authority row is available
- **THEN** each transaction locks the authority row before its Node and related grant rows
- **AND** each persisted policy state matches the phase locked by that transaction

#### Scenario: Empty cluster admission reads durable phase
- **WHEN** no Node policy rows exist and a Node Admission begins
- **THEN** the admission transaction locks and reads the cluster-wide phase row
- **AND** Orchard does not infer `pre_cutover` from the empty policy set

#### Scenario: Admission races with cutover
- **WHEN** Node Admission and enforcement cutover execute concurrently
- **THEN** both operations serialize through the locked phase row
- **AND** the admitted policy state matches the phase observed in its transaction

#### Scenario: Post-cutover admission is immediately enforcing
- **WHEN** an administrator admits a new production Node after enforcement cutover
- **THEN** Orchard persists an `enforcing` explicit policy in the admission transaction
- **AND** Orchard does not strand the Node in `approved_explicit`
- **AND** admission fails if policy or audit persistence fails

### Requirement: Controller Capability Evidence
Every operational Controller SHALL atomically publish membership freshness, software version, supported dispatch-capacity contract version, all-five-consumers readiness, and capability observation time at boot and every `10000` ms.
The local Controller identity owner SHALL update only its authenticated durable identity row.
A Controller SHALL publish all-five-consumers readiness as false until MultiNode, admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch-time revalidation all consume the shared evaluation.
For F11, compatibility SHALL require exact equality between the published contract version and the locked durable required contract version plus an all-five-consumers-ready declaration of true.
Greater-than-or-equal comparison SHALL NOT prove compatibility.
Missing, version-zero, false, or stale capability evidence SHALL block cutover until the Controller refreshes evidence or is explicitly retired through `POST /ops/v1/controllers/:controller_id/retire`.
A Controller that cannot enforce the recorded contract version SHALL fail readiness and refuse admission and dispatch after cutover.
This refines `SPEC.md` §8.3 and §13.2.

#### Scenario: Heartbeat publishes one complete tuple
- **WHEN** the supervised membership owner boots or reaches its `10000` ms heartbeat
- **THEN** Orchard updates `last_seen_at` and the complete capability tuple atomically
- **AND** a partial write cannot make stale evidence fresh

#### Scenario: Controller with incomplete consumer wiring is not cutover-ready
- **WHEN** any named capacity consumer does not use the shared evaluation
- **THEN** the Controller publishes a positive supported contract version
- **AND** it publishes all-five-consumers readiness as false
- **AND** diagnostics do not claim the cluster can cut over

#### Scenario: Stale Controller capability blocks cutover
- **WHEN** any non-retired Controller has missing, stale, version-zero, incompatible, or all-consumers-not-ready evidence
- **THEN** cutover Action Preview lists that Controller as a blocker
- **AND** Orchard does not advance any policy or the durable phase

#### Scenario: Incompatible Controller observes enforcing phase
- **WHEN** a Controller cannot enforce the durable required contract version
- **AND** the cluster-wide phase is `enforcing`
- **THEN** that Controller fails readiness
- **AND** it refuses admission and dispatch rather than treating the cluster as `pre_cutover`

### Requirement: Counterfactual Capacity Diagnostics
Shared operator Node status SHALL expose the complete evaluator result, durable phase, policy state, normalized management class, observation time, and stable reason codes.
Under `pre_cutover`, diagnostics SHALL label the result counterfactual, keep canonical enforcing values at `0`, and expose temporary legacy available slots separately.
Counterfactual diagnostics MUST NOT mutate scheduler, queue, placement, reservation, or dispatch authorization behavior.
The complete evaluator result SHALL include the authority decision, Runtime Concurrency Enforcement Limit, Controller Dispatch Ceiling, Effective Dispatch Limit, Controller-accounted Allocation, Dispatch Headroom, and Placement Capacity.
Under `legacy_pre_cutover`, diagnostics SHALL expose temporary `legacy_pre_cutover_available_slots`, live temporary legacy claim count, and cutover quiescing state while keeping the canonical F11 Effective Dispatch Limit and Dispatch Headroom at `0`.
The stable reason vocabulary SHALL distinguish degraded health, missing policy, invalid policy, explicit zero, ceiling exhaustion, runtime-limit uncertainty or exhaustion, headroom exhaustion, placement exhaustion, revalidation failure, pre-cutover legacy mode, phase-policy mismatch, missing or invalid target management class, shadow mismatch, and unapproved policy.
Public inference errors SHALL retain existing sanitized `cluster_busy`, `queue_timeout`, and dispatch error contracts.
The term `Admitted Capacity` SHALL NOT be used.
This refines `SPEC.md` §7.3.5 and the shared cluster-management contract.

#### Scenario: Approved ceiling is visible but not enforced
- **WHEN** a pre-cutover Node has an `approved_explicit` ceiling and fresh runtime evidence
- **THEN** diagnostics show the ceiling, `pre_cutover`, and the counterfactual evaluator result
- **AND** diagnostics report `controller_dispatch_ceiling_not_yet_enforcing`
- **AND** the approved ceiling does not authorize dispatch while the durable phase remains `pre_cutover`

#### Scenario: Missing policy is distinguishable
- **WHEN** an admitted production Node has no dispatch-capacity policy
- **THEN** diagnostics show Effective Dispatch Limit and Dispatch Headroom as `0`
- **AND** diagnostics include `controller_dispatch_ceiling_missing`
- **AND** diagnostics do not display a synthesized ceiling of `1`

#### Scenario: Pre-cutover zero is not yet authority
- **WHEN** an administrator approves Controller Dispatch Ceiling `0` during `pre_cutover`
- **THEN** the Action Preview exposes `controller_dispatch_ceiling_not_yet_enforcing`
- **AND** the `legacy_pre_cutover` decision remains authoritative until cutover
- **AND** Orchard does not claim the approved zero has paused temporary legacy allocation

#### Scenario: Ceiling is the binding authority
- **WHEN** the Controller Dispatch Ceiling is lower than the Runtime Concurrency Enforcement Limit and allocation exhausts the ceiling
- **THEN** diagnostics distinguish ceiling exhaustion from runtime-limit exhaustion

## ADDED Requirements

### Requirement: Node-Owned Runtime Concurrency Enforcement Limit
The Node SHALL own and locally enforce the dynamic Runtime Concurrency Enforcement Limit.
The Controller SHALL treat that limit as one input to Effective Dispatch Limit and SHALL NOT replace the Node's local enforcement.
Missing, malformed, unavailable, or scheduler-stale runtime-limit evidence for an admitted production Node SHALL NOT prove positive capacity.
This refines `SPEC.md` §4.6.1, §4.6.2, and §7.5.3.

#### Scenario: Runtime limit binds below the ceiling
- **WHEN** a production Node reports a valid Runtime Concurrency Enforcement Limit of `2`
- **AND** its Controller Dispatch Ceiling is `4`
- **AND** every production eligibility gate passes
- **THEN** its Effective Dispatch Limit is `2`

#### Scenario: Controller ceiling binds below runtime
- **WHEN** a production Node reports a valid Runtime Concurrency Enforcement Limit of `8`
- **AND** its Controller Dispatch Ceiling is `3`
- **AND** every production eligibility gate passes
- **THEN** its Effective Dispatch Limit is `3`

### Requirement: Capacity Policy Management Surface
`POST /admin/v1/nodes/:node_id/admit` SHALL accept optional non-negative `controller_dispatch_ceiling`, required non-empty `capacity_policy_reason`, `dry_run`, and required confirmation, and SHALL expose the resolved ceiling and phase-derived policy state in its Action Preview.
`orchardctl nodes admit` SHALL accept optional `--controller-dispatch-ceiling`, required `--capacity-policy-reason`, `--dry-run`, and execution confirmation, and SHALL expose the same resolved ceiling, phase-derived state, and preview semantics in human and JSON output.
`GET /ops/v1/nodes/:node_id/dispatch-capacity-policy` SHALL require cluster `operator` or `admin` authority.
`GET /ops/v1/controllers` SHALL require cluster `operator` or `admin` authority.
`POST /ops/v1/controllers/:controller_id/retire` SHALL require cluster `admin`, Active leadership, reason, optimistic concurrency, side-effect-free Action Preview, and typed Controller ID confirmation.
Retirement SHALL be blocked for the current Active Controller, a Controller holding the leadership lock, or the last non-retired Controller, and successful retirement SHALL atomically persist status plus cluster-scoped audit evidence.
`PATCH /ops/v1/nodes/:node_id/dispatch-capacity-policy` and `POST /ops/v1/dispatch-capacity/enforcement-cutover` SHALL be leader-only, require cluster `admin`, support side-effect-free Action Preview, and revalidate authorization, leadership, durable phase, compatibility, and mutation blockers inside the transaction.
Cutover SHALL accept `expected_required_contract_version`, require it to equal the locked singleton row, and SHALL NOT change the durable required version.
Policy updates SHALL require a non-negative ceiling, non-empty reason, optimistic concurrency value, and any consequence confirmation.
Policy updates SHALL hold the target Node's acceptance gate through commit and local policy publication.
Before cutover, admission and policy-mutation previews SHALL expose `controller_dispatch_ceiling_not_yet_enforcing` and SHALL NOT claim any approved ceiling changes temporary legacy allocation.
Under `f11_enforcing`, lowering below Controller-accounted Allocation SHALL require `capacity_reduction_drain` confirmation.
Successful admission policy writes, approvals, ceiling changes, and cutover SHALL persist cluster-scoped audit evidence atomically with the authoritative mutation.
Local CLI admission SHALL use actor type `operator` with bounded Controller-runtime principal provenance and the same leader-only atomic admission, policy, decision, and audit transaction as the Admin API.
This refines `SPEC.md` §7.3.1, §7.4.1, §10.9, and §13.2.

#### Scenario: Admission preview resolves default
- **WHEN** an administrator previews Node Admission without supplying a ceiling
- **THEN** the Action Preview shows explicit Controller Dispatch Ceiling `1`
- **AND** it shows `approved_explicit` for `pre_cutover` or `enforcing` for the enforcing phase
- **AND** it warns `controller_dispatch_ceiling_not_yet_enforcing` when the phase is `pre_cutover`
- **AND** the preview creates no policy or audit row

#### Scenario: CLI admission uses the shared policy contract
- **WHEN** a local administrator previews `orchardctl nodes admit --capacity-policy-reason planned-capacity` without a ceiling flag
- **THEN** human and JSON output show explicit ceiling `1` and the phase-derived policy state
- **AND** execution with required confirmation persists the same policy, admission decision, local operator provenance, and cluster audit atomically

#### Scenario: Operator approves or changes a ceiling
- **WHEN** a cluster administrator submits a policy mutation with a non-negative ceiling, reason, current optimistic concurrency value, and required confirmation
- **THEN** the Active Controller revalidates the phase and policy version inside the transaction
- **AND** Orchard persists actor, reason, prior value, new value, timestamp, and cluster-scoped audit evidence atomically

#### Scenario: Lowering preview shows drain consequence
- **WHEN** under `f11_enforcing` a proposed ceiling is below Controller-accounted Allocation
- **THEN** the Action Preview requires `capacity_reduction_drain` confirmation
- **AND** it explains natural drain for accepted, running, or streaming work and revalidation for pre-acceptance work

#### Scenario: Standby or unauthorized mutation fails closed
- **WHEN** a non-Active Controller or a principal without cluster `admin` attempts policy mutation or cutover
- **THEN** Orchard performs no authoritative write
- **AND** Orchard returns the existing leadership or authorization blocker contract

#### Scenario: Administrator retires a stale Controller
- **WHEN** a cluster administrator previews retirement of a non-Active non-last Controller with stale capability evidence
- **AND** supplies reason, current optimistic concurrency value, and typed Controller ID confirmation
- **THEN** the Active Controller revalidates membership and leadership blockers
- **AND** Orchard atomically marks the instance `retired` and persists cluster-scoped audit evidence
- **AND** only then may cutover preflight exclude that instance

### Requirement: Raising And Lowering Semantics
Under `f11_enforcing`, lowering a Controller Dispatch Ceiling SHALL apply to new allocations and pre-acceptance held-allocation revalidation immediately.
It SHALL NOT forcibly cancel accepted, running, or streaming work solely because of the reduction.
Dispatch Headroom SHALL remain `0` while Controller-accounted Allocation is greater than or equal to the lowered Effective Dispatch Limit.
Under `f11_enforcing`, raising a ceiling SHALL create no allocation and SHALL remain bounded by runtime enforcement and all other eligibility gates.
Queue wake-up after a raise SHALL require shared capacity re-evaluation.
Policy mutation and final dispatch revalidation SHALL serialize through the same per-Node acceptance gate, held by dispatch through Node acceptance or pre-acceptance failure.
This refines `SPEC.md` §4.6.2 and §5.4.

#### Scenario: Ceiling is lowered below current allocation
- **WHEN** the ceiling falls from `4` to `2`
- **AND** Controller-accounted Allocation is `3`
- **THEN** Orchard does not forcibly cancel accepted, running, or streaming work solely because of the ceiling change
- **AND** Dispatch Headroom is `0`
- **AND** no new allocation occurs until allocation falls below the Effective Dispatch Limit

#### Scenario: Ceiling is raised
- **WHEN** an operator raises a ceiling and the fresh runtime limit permits more work
- **THEN** Orchard re-evaluates capacity
- **AND** queued work may wake when Dispatch Headroom becomes positive
- **AND** the raise does not bypass trust, lifecycle, health, freshness, placement, or breaker gates

#### Scenario: Ceiling mutation races Node acceptance
- **WHEN** a ceiling mutation races a dispatch after final revalidation but before Node acceptance
- **THEN** the shared per-Node gate linearizes the operations
- **AND** either Node acceptance completes before the mutation and the work drains naturally, or the mutation completes first and dispatch revalidates under the new policy
- **AND** pre-acceptance work never executes under an obsolete authority decision
