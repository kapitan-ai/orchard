## ADDED Requirements

### Requirement: Non-Enforcing Capacity Authority Persistence
Orchard SHALL persist one cluster-scoped dispatch-capacity authority row in `pre_cutover` with a positive required contract version.
Orchard SHALL persist one policy for each governed admitted production Node and SHALL distinguish `shadow_legacy`, `approved_explicit`, and `enforcing` from missing policy.
A policy ceiling MUST be a non-negative integer for `approved_explicit` and `enforcing` and MUST be null only for `shadow_legacy`.
This tracer MUST NOT provide a repository operation that advances the durable phase or a policy to `enforcing`.
This implements the approved `SPEC.md` §4.6.2 and §13.2 contract without changing it.

#### Scenario: Expand migration creates bounded legacy shadow rows
- **WHEN** the expand migration finds a non-removed production Node with durable successful admission evidence committed before the migration boundary
- **THEN** Orchard creates exactly one `shadow_legacy` policy linked to that evidence
- **AND** the policy has no Controller Dispatch Ceiling
- **AND** the migration does not read runtime telemetry into policy

#### Scenario: Inventory without admission proof receives no authority
- **WHEN** an existing Node has no durable successful admission evidence before the migration boundary
- **THEN** Orchard does not create a synthetic policy or ceiling
- **AND** counterfactual evaluation reports missing policy

#### Scenario: Removed inventory is not operationally backfilled
- **WHEN** a Node is already durably `removed` at the expand migration boundary
- **THEN** Orchard does not create an operational `shadow_legacy` policy for that Node

### Requirement: Pure Shared Capacity Evaluation
Orchard SHALL provide one pure transport-independent evaluator that accepts normalized policy, phase, management class, eligibility, freshness, capacity, allocation, placement, and temporary-claim inputs.
The evaluator SHALL return Runtime Concurrency Enforcement Limit, Controller Dispatch Ceiling, Effective Dispatch Limit, Controller-accounted Allocation, Dispatch Headroom, Placement Capacity, authority decision, decision-specific available slots, eligibility, and ordered stable reason codes.
In `pre_cutover`, canonical Effective Dispatch Limit and Dispatch Headroom SHALL remain `0` while the temporary legacy decision is calculated separately.
In `enforcing`, the evaluator SHALL calculate the approved minimum and headroom formulas and fail closed for every missing or invalid production prerequisite.
This implements the approved `SPEC.md` §4.6.2, §5.4, and §5.5 contract without changing it.

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
- **AND** stable reason codes identify runtime-limit uncertainty

### Requirement: Atomic Admission Policy Persistence
Every new Node Admission SHALL lock and read the durable authority phase and atomically persist the admission transition, admission decision, cluster audit evidence, and phase-derived dispatch-capacity policy.
The shared Admin API and local CLI admission preview SHALL require a non-empty capacity policy reason, accept an optional non-negative ceiling, and resolve omission to explicit ceiling `1`.
While the phase is `pre_cutover`, admission SHALL persist `approved_explicit` and SHALL warn that the ceiling is not yet enforcing.
No telemetry value SHALL supply the default or override the explicit admission value.
This implements the approved `SPEC.md` §7.3.1 and §10.9 contract without changing it.

#### Scenario: Admission omission persists explicit one
- **WHEN** an administrator confirms admission with a non-empty capacity policy reason and omits the ceiling
- **THEN** the preview and transaction resolve Controller Dispatch Ceiling `1`
- **AND** the transaction persists `approved_explicit` under `pre_cutover`
- **AND** diagnostics report that the ceiling is not yet enforcing

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

### Requirement: Controller Capability Shadow Evidence
Every operational Controller SHALL atomically publish membership freshness, software version, supported dispatch-capacity contract version, all-five-consumers readiness, and capability observation time at boot and every `10000` ms.
The local Controller identity owner SHALL update only its authenticated durable identity row.
This tracer SHALL publish all-five-consumers readiness as false.
This implements the approved `SPEC.md` §8.3 and §13.2 contract without changing it.

#### Scenario: Heartbeat publishes one complete tuple
- **WHEN** the supervised membership owner boots or reaches its `10000` ms heartbeat
- **THEN** Orchard updates `last_seen_at` and the complete capability tuple atomically
- **AND** a partial write cannot make stale evidence fresh

#### Scenario: Foundation Controller is not cutover-ready
- **WHEN** the Controller runs this non-enforcing tracer
- **THEN** it publishes a positive supported contract version
- **AND** it publishes all-five-consumers readiness as false
- **AND** diagnostics do not claim the cluster can cut over

### Requirement: Counterfactual Capacity Diagnostics
Shared operator Node status SHALL expose the complete evaluator result, durable phase, policy state, normalized management class, observation time, and stable reason codes.
Under `pre_cutover`, diagnostics SHALL label the result counterfactual, keep canonical enforcing values at `0`, and expose temporary legacy available slots separately.
Diagnostics MUST NOT alter scheduler, queue, placement, reservation, or dispatch authorization behavior in this tracer.
This implements the approved `SPEC.md` §7.3.5 contract without changing it.

#### Scenario: Approved ceiling is visible but not enforced
- **WHEN** a pre-cutover Node has an `approved_explicit` ceiling and fresh runtime evidence
- **THEN** diagnostics show the ceiling, `pre_cutover`, and the counterfactual evaluator result
- **AND** diagnostics report `controller_dispatch_ceiling_not_yet_enforcing`
- **AND** current dispatch behavior is unchanged

#### Scenario: Missing policy is distinguishable
- **WHEN** an admitted production Node has no dispatch-capacity policy
- **THEN** diagnostics show Effective Dispatch Limit and Dispatch Headroom as `0`
- **AND** diagnostics include `controller_dispatch_ceiling_missing`
- **AND** diagnostics do not display a synthesized ceiling of `1`
