## ADDED Requirements

### Requirement: EnsureModelLoaded Placement Capacity evidence
Orchard SHALL support optional Node-owned Placement Capacity on a successful
`EnsureModelLoaded` result for the exact requested model reference.
Included evidence SHALL contain a non-negative active request count and a positive maximum
concurrency and SHALL normalize through the same canonical validity rules as placement
capacity from Runtime Endpoint Observations.
Failed or non-loaded results MUST NOT supply placement authority.
Absent, malformed, zero-maximum, negative, invalid-model-reference, or otherwise invalid
evidence SHALL normalize to missing and MUST NOT be fabricated.
Producing this evidence MUST NOT cause an additional Controller Runtime Endpoint status
attempt.
This requirement refines `SPEC.md` §§6.8 and 7.5.2 and ADR 0017.

#### Scenario: Successful load returns valid placement evidence
- **WHEN** `EnsureModelLoaded` successfully loads or confirms the requested model and the
  Node Agent has a trustworthy placement request limit
- **THEN** the result may include the exact requested model reference, current active
  request count, and positive maximum concurrency
- **AND** the Node Agent does not perform another Controller Runtime Endpoint status
  operation to produce it

#### Scenario: Capacity evidence is unavailable
- **WHEN** a successful load cannot obtain trustworthy valid placement capacity
- **THEN** the result omits Placement Capacity
- **AND** Orchard does not substitute a default maximum or active count

#### Scenario: Additive protocol version skew
- **WHEN** an old protobuf or BEAM agent returns a successful result without the additive
  Placement Capacity field or key
- **THEN** a new Controller decodes the result as missing evidence without raising
- **AND** an old protobuf Controller may ignore evidence returned by a new agent
