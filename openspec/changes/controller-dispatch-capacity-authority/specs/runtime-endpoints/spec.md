## MODIFIED Requirements

### Requirement: Controller-Owned Capacity Management Classification
Orchard SHALL normalize a Runtime Endpoint target's capacity management class from Controller-owned configuration and admitted inventory before shared capacity evaluation.
A target that resolves to admitted production inventory SHALL be `production_managed` regardless of transport or a conflicting unmanaged declaration.
An unmanaged source-development or compatibility class SHALL require explicit mode-valid Controller configuration and MUST NOT be inferred from Node telemetry, transport, address, or probe failure.
While a Controller publishes `dispatch_capacity_consumers_ready = false`, this classification SHALL remain diagnostics-only and SHALL NOT change dispatch behavior.
Transport selection SHALL NOT determine whether the capacity-authority contract applies.
An admitted production Node SHALL remain governed over BEAM, gRPC compatibility, or a static target reference.
Production inventory resolution SHALL happen before any unmanaged exception is considered.
Every normalized Runtime Endpoint target SHALL carry Controller-owned `capacity_management_class` of `production_managed`, `unmanaged_source_development`, or `unmanaged_compatibility`.
`unmanaged_source_development` SHALL be valid only in Controller source-development mode, and `unmanaged_compatibility` SHALL be valid only for explicitly enabled compatibility configuration that does not match admitted inventory.
Missing, malformed, conflicting, Node-reported, transport-inferred, or probe-inferred classification SHALL fail closed.
Only a valid explicitly classified unmanaged source-development or compatibility target MAY retain legacy capacity behavior.
Failure to resolve or probe a production-managed target SHALL NOT downgrade it to unmanaged behavior.
This refines `SPEC.md` §4.6.2, §5.9, and §7.5.

#### Scenario: Admitted gRPC target remains production managed
- **WHEN** a gRPC compatibility target resolves to an admitted production Node
- **THEN** the normalized class is `production_managed`
- **AND** counterfactual diagnostics apply the production fail-closed contract
- **AND** Orchard requires an in-force Controller Dispatch Ceiling and shared capacity evaluation once enforcement is live

#### Scenario: Static target matches production inventory
- **WHEN** a static target reference resolves to an admitted production Node
- **THEN** Orchard applies production capacity authority before dispatch
- **AND** static configuration does not create an unmanaged exemption

#### Scenario: Admitted inventory overrides unmanaged declaration
- **WHEN** a target resolves to admitted production inventory
- **AND** configuration declares an unmanaged capacity management class
- **THEN** Orchard classifies the target as `production_managed`
- **AND** Orchard applies the enforcing production contract

#### Scenario: Explicit unmanaged source development
- **WHEN** Controller-owned source-development configuration sets `capacity_management_class = unmanaged_source_development`
- **AND** the Controller is in source-development mode and the target does not resolve to admitted production inventory
- **THEN** Orchard may retain documented legacy capacity behavior
- **AND** any missing-runtime normalization to `1` remains ephemeral runtime interpretation
- **AND** Orchard creates no durable Controller Dispatch Ceiling from that interpretation

#### Scenario: Missing unmanaged declaration is invalid
- **WHEN** a target does not resolve to admitted inventory and has no explicit mode-valid management class
- **THEN** classification is invalid
- **AND** diagnostics expose `runtime_endpoint_management_class_missing`
- **AND** Orchard does not infer an unmanaged class from successful or failed probing

#### Scenario: Management class is malformed or invalid for the mode
- **WHEN** a target does not resolve to admitted inventory and its capacity management class is malformed, conflicting, or invalid for the Controller mode
- **THEN** Orchard fails closed for new dispatch
- **AND** Orchard exposes `runtime_endpoint_management_class_invalid`
- **AND** Orchard does not infer classification from transport, address, telemetry, or probe outcome

#### Scenario: Production probe fails
- **WHEN** a production-managed target cannot provide fresh trusted capacity evidence before dispatch
- **THEN** Orchard does not allocate or execute new work through a compatibility fallback
- **AND** broader probe-failure fallback cleanup remains a separate implementation finding

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
This refines `SPEC.md` §4.6.1, §4.6.2, §5.4, §5.5, and §7.5.3.

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
