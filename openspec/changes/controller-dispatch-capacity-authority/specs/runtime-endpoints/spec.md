## MODIFIED Requirements

### Requirement: Controller-Owned Capacity Management Classification
Orchard SHALL normalize a Runtime Endpoint target's capacity management class from Controller-owned configuration and admitted inventory before shared capacity evaluation or any capacity behavior.
The Controller SHALL resolve trusted admitted production inventory before applying configured classification, and an inventory match SHALL force `production_managed` regardless of transport or a conflicting unmanaged declaration.
Every normalized Runtime Endpoint target SHALL carry Controller-owned `capacity_management_class` of `production_managed`, `unmanaged_source_development`, or `unmanaged_compatibility`.
`unmanaged_source_development` SHALL be accepted only from Controller-owned source-development configuration while the Controller runs in source-development mode.
`unmanaged_compatibility` SHALL be accepted only from an explicitly enabled mode-valid Controller-owned compatibility configuration that does not resolve to admitted production inventory.
Absent, malformed, conflicting, or unresolved classification SHALL fail closed for production dispatch with no legacy normalization.
Only a valid explicitly classified unmanaged source-development or compatibility target MAY retain documented unmanaged legacy capacity behavior, and only through shared capacity evaluation.
Classification SHALL NOT be inferred from Node telemetry, transport type, address shape, probe outcome, or adapter fallback.
Missing, stale, invalid, or unavailable trusted capacity evidence after a target is classified as `production_managed` is governed by the separate `Admitted Production Evidence Safety` requirement.
Transport selection SHALL NOT determine whether the capacity-authority contract applies, and an admitted production Node SHALL remain governed over BEAM, gRPC compatibility, or a static target reference.
Capacity management classification SHALL NOT by itself authorize dispatch, create an unmanaged exception, or relax production fail-closed behavior required by `SPEC.md` §4.6.2, and every phase, policy, trust, lifecycle, health, freshness, runtime, placement, routing, breaker, allocation, temporary-claim, and claim-acquisition gate SHALL still apply.
`dispatch_capacity_consumers_ready` SHALL be Controller capability evidence for enforcement-cutover preflight only, and SHALL NOT enable, disable, defer, or weaken this classification contract.
Admitted production identity and the fresh-trusted-capacity-evidence and no-compatibility-fallback prohibitions SHALL remain separately and always enforced under `Admitted Production Evidence Safety`.
This requirement traces to `SPEC.md` §4.6.2, §5.9, and §7.5.

#### Scenario: Admitted gRPC target remains production managed
- **WHEN** a gRPC compatibility target resolves to an admitted production Node
- **THEN** the normalized class is `production_managed`
- **AND** Orchard applies the production capacity-authority contract for the current durable enforcement phase
- **AND** the gRPC compatibility transport creates no unmanaged exemption

#### Scenario: Static target matches production inventory
- **WHEN** a static target reference resolves to an admitted production Node
- **THEN** static configuration does not create an unmanaged exemption
- **AND** the normalized class is `production_managed`
- **AND** Orchard applies the complete shared authority decision under the current durable enforcement phase before dispatch

#### Scenario: Admitted inventory overrides unmanaged declaration
- **WHEN** a target resolves to admitted production inventory
- **AND** configuration declares an unmanaged capacity management class
- **THEN** Orchard classifies the target as `production_managed`
- **AND** Orchard applies the production contract for the current durable enforcement phase

#### Scenario: Explicit unmanaged source development
- **WHEN** Controller-owned source-development configuration sets `capacity_management_class = unmanaged_source_development`
- **AND** the Controller is in source-development mode and the target does not resolve to admitted production inventory
- **THEN** Orchard may retain documented unmanaged legacy capacity behavior only through shared capacity evaluation
- **AND** any missing-runtime normalization to `1` remains ephemeral runtime interpretation
- **AND** Orchard creates no durable Controller Dispatch Ceiling from that interpretation

#### Scenario: Explicit unmanaged compatibility stays bounded
- **WHEN** an explicitly enabled mode-valid compatibility target does not resolve to admitted production inventory
- **THEN** the normalized class is `unmanaged_compatibility`
- **AND** the documented unmanaged legacy capacity behavior applies only through shared capacity evaluation
- **AND** that classification creates no durable Controller Dispatch Ceiling and no aggregate Controller authority

#### Scenario: Missing unmanaged declaration is invalid
- **WHEN** a target does not resolve to admitted inventory and has no explicit mode-valid management class
- **THEN** classification is invalid and fails closed for production dispatch with no legacy normalization
- **AND** diagnostics expose `runtime_endpoint_management_class_missing`
- **AND** Orchard does not infer an unmanaged class from successful or failed probing

#### Scenario: Management class is malformed or invalid for the mode
- **WHEN** a target does not resolve to admitted inventory and its capacity management class is malformed, conflicting, or invalid for the Controller mode
- **THEN** Orchard exposes `runtime_endpoint_management_class_invalid`
- **AND** the complete shared authority decision fails closed for new dispatch with no legacy normalization
- **AND** Orchard does not infer classification from transport, address, telemetry, or probe outcome, and never treats the invalid classification as an unmanaged exception

#### Scenario: Classification does not depend on published readiness
- **WHEN** `dispatch_capacity_consumers_ready` is `false`, absent, or stale for the running Controller
- **THEN** normalization, admitted-inventory precedence, and the fail-closed contract for absent, malformed, conflicting, or unresolved classification still apply
- **AND** a later `dispatch_capacity_consumers_ready = true` neither relaxes nor strengthens this classification contract
- **AND** the readiness value remains capability evidence for enforcement-cutover preflight only

### Requirement: Placement Capacity Observation
Placement Capacity SHALL be a first-class Runtime Endpoint Observation for Model Placements.
Placement Capacity SHALL include the model reference, active request count, and maximum concurrency for the placement.
Unknown, malformed, duplicate, or nonmatching Placement Capacity MUST NOT prove scheduler eligibility for an active loaded placement.
Placement Capacity SHALL remain Node-owned and MAY reduce capacity for one requested Model Placement.
The effective capacity of one placement SHALL be bounded by both its Placement Capacity and the shared authority decision's available slots.
Under `f11_enforcing`, no new Controller-accounted Allocation across all placements and queue lanes on one Node SHALL cause the total to exceed that Node's Effective Dispatch Limit.
Under `legacy_pre_cutover`, the central temporary legacy available slots SHALL subtract both reported allocation and serialized live temporary legacy claims across all placements and lanes while Effective Dispatch Limit remains counterfactual `0`.
A lower ceiling MAY temporarily leave accepted, running, or streaming allocations above the new limit while they drain naturally.
Placement Capacity SHALL NOT create aggregate Controller authority or increase Dispatch Headroom.
This requirement traces to `SPEC.md` §4.6.1, §4.6.2, §5.4, §5.5, §7.5, and §7.5.3.

#### Scenario: Active loaded placement has spare capacity
- **WHEN** exactly one matching Placement Capacity observation reports `active_request_count < max_concurrency`
- **AND** the shared authority decision has positive available slots
- **THEN** the Scheduler may keep that active loaded placement eligible for the requested work

#### Scenario: Active loaded placement has unknown capacity
- **WHEN** Placement Capacity is absent, malformed, duplicate, or nonmatching for an active loaded placement
- **THEN** the Scheduler does not treat that placement as eligible based on capacity

#### Scenario: Active loaded placement is full
- **WHEN** matching Placement Capacity reports `active_request_count >= max_concurrency`
- **THEN** the Scheduler treats that placement as currently unavailable for new work

#### Scenario: Placement reports more than aggregate authority
- **WHEN** a Placement Capacity reports maximum concurrency above the shared authority decision's available slots
- **THEN** Orchard bounds allocatable placement capacity by those available slots
- **AND** the placement report does not increase aggregate authority

#### Scenario: Multiple placement lanes share one Node bound
- **WHEN** multiple placement lanes on one Node each report spare capacity
- **THEN** every dispatch grant serializes acquisition of one aggregate Node claim
- **AND** under `f11_enforcing` no new allocation causes combined Controller-accounted Allocation to exceed Effective Dispatch Limit
- **AND** under `legacy_pre_cutover` every grant requires freshly recomputed positive temporary available slots and serialized temporary-claim acquisition

#### Scenario: Placement is tighter than aggregate authority
- **WHEN** the shared authority decision has positive available slots but the requested Placement Capacity is exhausted
- **THEN** Orchard does not allocate the request to that placement

## ADDED Requirements

### Requirement: Admitted Production Evidence Safety
Admitted production identity SHALL govern a Runtime Endpoint target at every stage, independently of the normalized `capacity_management_class`.
When a target that resolves to admitted production inventory lacks fresh trusted capacity evidence before dispatch, Orchard SHALL NOT allocate or execute new work for that target through an unmanaged or compatibility fallback.
For a target resolved to admitted production inventory, missing, stale, malformed, invalid, or unavailable required capacity evidence, including Runtime Endpoint capacity probe failure, SHALL fail closed for positive capacity and SHALL NOT downgrade or reclassify the target from `production_managed` to `unmanaged_source_development` or `unmanaged_compatibility`.
`dispatch_capacity_consumers_ready` SHALL NOT weaken that prohibition in either state.
This requirement SHALL remain always active and independent of the durable enforcement phase, of published readiness, and of the normalized `capacity_management_class`.
Broader production probe-failure direct scheduling fallback cleanup remains a separate implementation finding and is not resolved by this requirement.
This requirement traces to `SPEC.md` §4.6.2, §5.9, and §7.5.

#### Scenario: Admitted production target lacks fresh trusted evidence
- **WHEN** a target resolves to admitted production inventory
- **AND** that target lacks fresh trusted capacity evidence before dispatch
- **THEN** Orchard does not downgrade or reclassify the target to unmanaged behavior
- **AND** Orchard does not allocate or execute new work through an unmanaged or compatibility fallback
- **AND** that prohibition holds while `dispatch_capacity_consumers_ready` is `false`
- **AND** that prohibition holds independently of the normalized `capacity_management_class` and the durable enforcement phase
