## MODIFIED Requirements

### Requirement: Runtime Provider Conformance
Every supported runtime provider SHALL pass the same provider-neutral conformance scenarios for negotiation, health, load, unload, generation, streaming, cancellation, capacity, failure normalization, and version skew.
Hardware-specific acceptance SHALL supplement and MUST NOT replace provider-neutral conformance.

#### Scenario: Provider is proposed for support
- **WHEN** a runtime provider is proposed for support under a runtime-provider profile
- **THEN** it passes provider-neutral conformance
- **AND** it passes the applicable real-hardware acceptance lane
