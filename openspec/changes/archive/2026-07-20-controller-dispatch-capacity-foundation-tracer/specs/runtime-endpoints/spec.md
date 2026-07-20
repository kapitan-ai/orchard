## ADDED Requirements

### Requirement: Bounded Aggregate Runtime Capacity Evidence
Orchard SHALL persist at most one current aggregate runtime capacity evidence row per admitted Node.
The row SHALL preserve the latest trusted authenticated observation time, raw normalized runtime maximum concurrency, raw normalized active request count, and validity state.
A newer authenticated observation SHALL replace older evidence atomically, and an older or unauthenticated observation MUST NOT overwrite it.
Missing or malformed runtime values SHALL remain missing or invalid and MUST NOT be durably normalized to maximum `1`, active count `0`, or a Controller Dispatch Ceiling.
This implements the approved `SPEC.md` §4.6.2 and §7.5.3 contract without changing it.

#### Scenario: Newer trusted observation replaces current evidence
- **WHEN** a trusted authenticated Runtime Endpoint Observation is newer than the current evidence for its admitted Node
- **THEN** Orchard replaces the aggregate capacity values, validity state, and observation time in one write
- **AND** the Node still has exactly one current aggregate evidence row

#### Scenario: Stale observation cannot overwrite evidence
- **WHEN** an authenticated observation is older than the current aggregate evidence
- **THEN** Orchard retains the newer row unchanged

#### Scenario: Malformed runtime limit is preserved as invalid
- **WHEN** a trusted observation has a missing, non-integer, zero, or negative aggregate runtime maximum
- **THEN** Orchard persists invalid or missing evidence rather than maximum `1`
- **AND** counterfactual enforcing evaluation fails closed for runtime-limit uncertainty

#### Scenario: Telemetry never becomes policy
- **WHEN** a trusted observation reports aggregate runtime maximum `8`
- **THEN** Orchard may persist `8` as Node-owned runtime evidence
- **AND** Orchard does not create or change a Controller Dispatch Ceiling from that value

### Requirement: Controller-Owned Capacity Management Classification
Orchard SHALL normalize a Runtime Endpoint target's capacity management class from Controller-owned configuration and admitted inventory before counterfactual evaluation.
A target that resolves to admitted production inventory SHALL be `production_managed` regardless of transport or a conflicting unmanaged declaration.
An unmanaged source-development or compatibility class SHALL require explicit mode-valid Controller configuration and MUST NOT be inferred from Node telemetry, transport, address, or probe failure.
This tracer SHALL use the classification for diagnostics only and SHALL NOT change dispatch behavior.
This implements the approved `SPEC.md` §4.6.2 and §7.5 contract without changing it.

#### Scenario: Admitted gRPC target remains production managed
- **WHEN** a gRPC compatibility target resolves to an admitted production Node
- **THEN** the normalized class is `production_managed`
- **AND** counterfactual diagnostics apply the production fail-closed contract

#### Scenario: Missing unmanaged declaration is invalid
- **WHEN** a target does not resolve to admitted inventory and has no explicit mode-valid management class
- **THEN** classification is invalid
- **AND** diagnostics expose `runtime_endpoint_management_class_missing`
- **AND** Orchard does not infer an unmanaged class from successful or failed probing
