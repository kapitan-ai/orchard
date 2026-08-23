## ADDED Requirements

### Requirement: Heterogeneous Runtime Capability Observations
Runtime Endpoint Observations SHALL carry normalized platform, architecture, runtime-provider, capability-version, acceleration, device-resource, memory-domain, runtime-health, and availability evidence required for heterogeneous scheduling.
The evidence SHALL remain transport-independent and MUST NOT make provider or operating-system strings implicit policy.
Unknown, malformed, stale, unauthenticated, or version-incompatible required evidence MUST NOT prove capability eligibility.
This requirement refines `SPEC.md` §§4.1, 4.6.1, and 7.5.

#### Scenario: Mac MLX Node is observed by Linux Controller
- **WHEN** a Linux Controller receives an authenticated Runtime Endpoint Observation from an admitted macOS MLX Node
- **THEN** it records normalized platform, provider, device, memory, health, and capacity evidence
- **AND** transport or host differences do not change Runtime Endpoint semantics

#### Scenario: Older Node Agent omits additive capabilities
- **WHEN** an older Node Agent returns an observation without newly additive capability fields
- **THEN** the Controller decodes the observation without crashing
- **AND** absent evidence does not affirm compatibility for a requirement it must prove

### Requirement: Node And Worker Capability Evidence Remain Distinct
Runtime Endpoint Observations SHALL distinguish Node capability-provider evidence from runtime-provider evidence.
Node hardware health MUST NOT by itself prove runtime initialization, and runtime readiness MUST NOT fabricate host device inventory.

#### Scenario: Device exists but runtime cannot initialize
- **WHEN** a capability provider reports a healthy device and the selected runtime provider reports initialization unavailable
- **THEN** the Runtime Endpoint Observation preserves both facts
- **AND** the endpoint does not claim executable capacity from device presence alone
