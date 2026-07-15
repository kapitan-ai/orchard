## MODIFIED Requirements

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
