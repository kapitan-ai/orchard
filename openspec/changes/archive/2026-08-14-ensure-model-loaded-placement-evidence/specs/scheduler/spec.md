## ADDED Requirements

### Requirement: Compatibility post-load Placement Capacity revalidation
Final revalidation SHALL consume valid Placement Capacity from the successful
`EnsureModelLoaded` result for an initially cold explicitly unmanaged compatibility
candidate and SHALL require its model reference to exactly match the requested model.
Final revalidation SHALL preserve the captured target and resolved Node identity,
aggregate capacity, availability, health, observation time and freshness behavior, and
explicit unmanaged classification.
Missing, malformed, or model-mismatched post-load evidence MUST fail closed before
`ExecuteInference`.
For an initially loaded compatibility candidate, missing additive load-result evidence
MUST NOT replace or invalidate captured valid matching Placement Capacity; valid newer
matching evidence MAY replace it.
This requirement refines `SPEC.md` §§5.5 and 5.9 and ADRs 0013 and 0017.

#### Scenario: Cold compatibility load supplies matching evidence
- **WHEN** the bounded compatibility observation found the requested model cold and
  `EnsureModelLoaded` succeeds with valid matching Placement Capacity
- **THEN** final revalidation evaluates that capacity with the captured identity and
  authority facts
- **AND** Orchard may call `ExecuteInference` only if the full evaluation remains eligible

#### Scenario: Cold compatibility load lacks usable evidence
- **WHEN** the successful load result has absent, malformed, or nonmatching Placement
  Capacity
- **THEN** final revalidation fails closed before `ExecuteInference`
- **AND** existing release, retry, queue, and public error behavior applies

#### Scenario: Loaded compatibility candidate receives an old-agent result
- **WHEN** the initial compatibility observation supplied valid matching Placement Capacity
  and the later result omits the additive field
- **THEN** final revalidation retains the captured placement capacity

### Requirement: One compatibility status attempt per logical request
The bounded explicitly unmanaged compatibility wave SHALL remain the only Controller
Runtime Endpoint status operation for the logical request.
Each target SHALL receive at most one connect/status attempt with no retry through loading,
final revalidation, failure handling, execution, and terminal completion.
An absent or invalid additive load-result field MUST NOT trigger another status attempt.
This requirement refines `SPEC.md` §§5.5 and 5.9 and ADR 0017.

#### Scenario: Post-load revalidation uses returned evidence
- **WHEN** a cold compatibility candidate reaches final revalidation after
  `EnsureModelLoaded`
- **THEN** Orchard uses the successful load result rather than status-probing the target
  again

#### Scenario: Old agent omits placement evidence
- **WHEN** an old agent returns a successful load result without Placement Capacity
- **THEN** the request fails closed before execution
- **AND** Orchard does not make a second status attempt
