# worker-runtime-providers Specification

## Purpose

Defines the provider-neutral Worker Runtime contract, capability negotiation and resource normalization, Node Agent ownership of worker processes, and conformance evidence required for supported runtime providers.

## Requirements

### Requirement: Provider-Neutral Worker Runtime Contract Ownership
The Worker Runtime protocol source, version policy, generated bindings, and conformance fixtures SHALL be owned outside any runtime-provider implementation.
Supported language bindings SHALL be generated from one normative source, and validation SHALL fail when committed generated bindings drift.
This requirement refines `SPEC.md` §§4.9, 4.10, and 7.5.2a.

#### Scenario: MLX provider evolves
- **WHEN** the MLX runtime provider changes its implementation without changing Worker Runtime semantics
- **THEN** the provider does not redefine or privately fork the Worker Runtime contract

### Requirement: Versioned Runtime Capability Negotiation
A Worker Runtime provider SHALL report protocol version, provider identity and version, supported artifact formats, runtime features, acceleration implementations, device-resource bindings, memory semantics, concurrency, and cache capabilities before those facts authorize work.
Unknown, malformed, incompatible, or absent required capability evidence MUST NOT be treated as affirmative compatibility.
This requirement changes the MLX-default assumptions in `SPEC.md` §§1.5, 4.6.1, 5.5, and 7.5.2a.

#### Scenario: New Node Agent contacts an older worker
- **WHEN** an older worker omits additive capability negotiation fields
- **THEN** the Node Agent decodes the response without crashing
- **AND** it does not claim capabilities the worker did not prove

### Requirement: Normalized Runtime Resources And Failures
Worker Runtime contracts SHALL express device resources and memory through normalized identities, memory domains, capacity, reservation, allocation, and observation freshness.
Portable durable failure state SHALL use provider-neutral categories, while bounded provider-specific codes MAY be retained as diagnostics.
Provider-specific codes MUST NOT become scheduler policy or new durable public categories without an explicit contract change.
This requirement changes `SPEC.md` §§4.6.1, 5.7, 7.5.2a, and 10.10.

#### Scenario: MLX reports unified memory
- **WHEN** an MLX worker reports Apple unified-memory capacity and headroom
- **THEN** the Node Agent maps it to a normalized unified memory resource
- **AND** portable scheduling does not require an Apple working-set field name

#### Scenario: Provider cannot initialize
- **WHEN** a runtime provider reports a provider-specific initialization failure
- **THEN** Orchard records the provider-neutral runtime-unavailable category required by policy
- **AND** any provider-specific detail remains bounded diagnostic evidence

### Requirement: Node Agent Owns Worker Processes
The Node Agent SHALL continue to supervise Worker Runtime subprocesses, model loading, execution, cancellation, active allocation, diagnostics, and cleanup.
The Controller MUST communicate through the Node Agent Runtime Endpoint rather than directly managing runtime-provider processes.

#### Scenario: Runtime provider crashes
- **WHEN** a Worker Runtime provider process crashes during local operation
- **THEN** the Node Agent applies the portable worker supervision and failure contract
- **AND** the Controller observes the result through Runtime Endpoint semantics

### Requirement: Runtime Provider Conformance
Every supported runtime provider SHALL pass the same provider-neutral conformance scenarios for negotiation, health, load, unload, generation, streaming, cancellation, capacity, failure normalization, and version skew.
Hardware-specific acceptance SHALL supplement and MUST NOT replace provider-neutral conformance.

#### Scenario: Provider is proposed for support
- **WHEN** a runtime provider is proposed for a supported runtime-provider profile
- **THEN** it passes provider-neutral conformance
- **AND** it passes the applicable real-hardware acceptance lane
