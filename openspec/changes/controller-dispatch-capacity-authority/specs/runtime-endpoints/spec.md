## MODIFIED Requirements

### Requirement: Controller-Owned Capacity Management Classification
Orchard SHALL normalize a Runtime Endpoint target's capacity management class from Controller-owned configuration and admitted inventory before shared capacity evaluation.
A target that resolves to admitted production inventory SHALL be `production_managed` regardless of transport or a conflicting unmanaged declaration.
An unmanaged source-development or compatibility class SHALL require explicit mode-valid Controller configuration and MUST NOT be inferred from Node telemetry, transport, address, or probe failure.
Until `Orchard.Scheduler.MultiNode`, admitted `Orchard.Scheduler.SingleNode`, Node queue-source refresh, `Orchard.Inference.QueueManager`, and dispatch-time revalidation all actually consume the shared evaluation, capacity management classification SHALL remain diagnostics-only and SHALL NOT change dispatch behavior.
`dispatch_capacity_consumers_ready = true` SHALL be capability evidence only and SHALL NOT by itself enable any classification-driven behavior.
After every named consumer actually consumes the shared evaluation, classification MAY affect dispatch only as an input to the complete shared authority decision under the applicable durable phase contract.
Classification alone SHALL NOT authorize dispatch, and every phase, policy, trust, lifecycle, health, freshness, runtime, placement, routing, breaker, allocation, temporary-claim, and claim-acquisition gate SHALL still apply.
Transport selection SHALL NOT determine whether the capacity-authority contract applies.
An admitted production Node SHALL remain governed over BEAM, gRPC compatibility, or a static target reference.
Production inventory resolution SHALL happen before any unmanaged exception is considered.
Every normalized Runtime Endpoint target SHALL carry Controller-owned `capacity_management_class` of `production_managed`, `unmanaged_source_development`, or `unmanaged_compatibility`.
`unmanaged_source_development` SHALL be valid only in Controller source-development mode, and `unmanaged_compatibility` SHALL be valid only for explicitly enabled compatibility configuration that does not match admitted inventory.
Before the named consumers consume the shared evaluation, missing, malformed, conflicting, Node-reported, transport-inferred, or probe-inferred classification SHALL be diagnostic only and SHALL NOT alter dispatch.
After the named consumers consume the shared evaluation, such classification SHALL make the complete shared authority decision fail closed for new dispatch.
At no stage SHALL invalid, missing, or inferred classification become an unmanaged exception, and failure to resolve or probe a production-managed target SHALL NOT downgrade it to unmanaged behavior.
Only a valid explicitly classified unmanaged source-development or compatibility target MAY retain documented unmanaged legacy capacity behavior once classification participates in the fully wired shared evaluation.
This requirement traces to `SPEC.md` §4.6.2, §5.9, and §7.5.

#### Scenario: Admitted gRPC target remains production managed
- **WHEN** a gRPC compatibility target resolves to an admitted production Node
- **THEN** the normalized class is `production_managed`
- **AND** before the named consumers consume the shared evaluation, counterfactual diagnostics apply the production fail-closed contract without changing dispatch
- **AND** after the named consumers consume the shared evaluation, Orchard requires an in-force Controller Dispatch Ceiling and the complete shared authority decision under the current durable phase

#### Scenario: Static target matches production inventory
- **WHEN** a static target reference resolves to an admitted production Node
- **THEN** static configuration does not create an unmanaged exemption
- **AND** before the named consumers consume the shared evaluation, the production classification is diagnostics-only
- **AND** after the named consumers consume the shared evaluation, Orchard applies the complete shared authority decision under the current durable phase before dispatch

#### Scenario: Admitted inventory overrides unmanaged declaration
- **WHEN** a target resolves to admitted production inventory
- **AND** configuration declares an unmanaged capacity management class
- **THEN** Orchard classifies the target as `production_managed`
- **AND** before the named consumers consume the shared evaluation, that reclassification is diagnostics-only
- **AND** after the named consumers consume the shared evaluation, Orchard applies the production contract for the current durable phase

#### Scenario: Explicit unmanaged source development
- **WHEN** Controller-owned source-development configuration sets `capacity_management_class = unmanaged_source_development`
- **AND** the Controller is in source-development mode and the target does not resolve to admitted production inventory
- **THEN** Orchard may retain documented unmanaged legacy capacity behavior once classification participates in the fully wired shared evaluation
- **AND** any missing-runtime normalization to `1` remains ephemeral runtime interpretation
- **AND** Orchard creates no durable Controller Dispatch Ceiling from that interpretation

#### Scenario: Missing unmanaged declaration is invalid
- **WHEN** a target does not resolve to admitted inventory and has no explicit mode-valid management class
- **THEN** classification is invalid
- **AND** diagnostics expose `runtime_endpoint_management_class_missing`
- **AND** Orchard does not infer an unmanaged class from successful or failed probing

#### Scenario: Management class is malformed or invalid for the mode
- **WHEN** a target does not resolve to admitted inventory and its capacity management class is malformed, conflicting, or invalid for the Controller mode
- **THEN** Orchard exposes `runtime_endpoint_management_class_invalid`
- **AND** before the named consumers consume the shared evaluation, the invalid classification is diagnostic and does not alter dispatch
- **AND** after the named consumers consume the shared evaluation, the complete shared authority decision fails closed for new dispatch under the current durable phase
- **AND** Orchard does not infer classification from transport, address, telemetry, or probe outcome, and never treats the invalid classification as an unmanaged exception

#### Scenario: Production probe fails
- **WHEN** a target resolves to admitted production inventory and is normalized `production_managed`
- **AND** that target lacks fresh trusted capacity evidence before dispatch
- **THEN** Orchard does not downgrade or reclassify the target to unmanaged behavior
- **AND** Orchard does not allocate or execute new work through a compatibility fallback
- **AND** that prohibition applies regardless of `dispatch_capacity_consumers_ready`
- **AND** before all named consumers actually consume the shared evaluation, normalized classification remains diagnostics-only and does not otherwise change dispatch behavior
- **AND** broader production probe-failure direct scheduling fallback cleanup remains a separate implementation finding

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
