## ADDED Requirements

### Requirement: Durable circuit-breaker eligibility gates

Production candidate construction and final dispatch revalidation SHALL consume database-authoritative breaker facts for canonical Node and placement identities.
An active Node breaker SHALL reject the Node before tiering, ranking, scoring, prefix-cache scoring, or dispatch with `node_circuit_breaker_open`.
An active placement breaker SHALL reject only a cold or warm loading path with `model_load_suppressed`; a separately valid already-loaded placement remains dispatchable.
`placement_suppressed` SHALL remain the broader placement-lifecycle reason.
This requirement implements `SPEC.md` §5.5, §5.10, and §7.3.5.

#### Scenario: Node breaker is open

- **WHEN** durable current breaker state proves a candidate Node is suppressed
- **THEN** the scheduler rejects it before ranking with `node_circuit_breaker_open`

#### Scenario: Placement breaker is open and model is already loaded

- **WHEN** durable current breaker state suppresses loading for a placement but current trusted facts prove the requested model is already loaded and every other gate passes
- **THEN** the placement breaker does not reject dispatch

#### Scenario: Placement breaker is open and loading is required

- **WHEN** a candidate requires cold or warm loading on a durably suppressed placement
- **THEN** the scheduler rejects that load path with `model_load_suppressed`

### Requirement: Breaker authority failures fail closed distinctly

If scheduler or final-revalidation code cannot resolve required canonical breaker identity, read durable state, or establish a coherent breaker decision, it SHALL fail closed with the applicable existing identity or unavailable-facts reason.
It MUST NOT emit `node_circuit_breaker_open` or `model_load_suppressed` unless durable state proves that breaker is active.
This requirement refines the fail-closed scheduler behavior in `SPEC.md` §5.5 and §7.3.5.

#### Scenario: Breaker read fails

- **WHEN** the scheduler cannot read the required durable breaker facts
- **THEN** the candidate is not authorized for dispatch
- **AND** its explanation reports unavailable authority rather than falsely claiming a breaker is open
