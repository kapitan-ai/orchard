## MODIFIED Requirements

### Requirement: Provider-Neutral Worker Runtime Contract Ownership

The Worker Runtime protocol source, version policy, binding generation authority and output manifest, descriptor golden, and conformance fixtures SHALL be owned outside any runtime-provider implementation.
Generated consumer copies MAY remain under a runtime-provider package when the neutral generator is their only authority and required validation checks every committed output for drift.
Supported Python and Elixir bindings SHALL be generated deterministically from one normative source with pinned repository toolchains.
Required validation SHALL fail when any committed generated output is missing or differs from regeneration.
The ownership migration SHALL preserve the complete current wire descriptor and the existing `Orchard.Node.Worker.V1.*` Elixir consumer surface.
This requirement refines `SPEC.md` sections 4.9, 4.10, and 7.5.2a.

#### Scenario: MLX provider evolves

- **WHEN** the MLX runtime provider changes its implementation without changing Worker Runtime semantics
- **THEN** the provider does not redefine or privately fork the Worker Runtime contract

#### Scenario: Bindings are regenerated

- **WHEN** the repository generates Worker Runtime bindings from the neutral schema twice
- **THEN** both runs produce byte-identical committed Python and Elixir outputs
- **AND** the existing Node Agent consumer modules remain usable

#### Scenario: Committed output drifts

- **WHEN** a committed Worker Runtime binding differs from the canonical schema output
- **THEN** required validation fails
- **AND** the failure identifies the drifted generated path

#### Scenario: Cross-language compatibility is validated

- **WHEN** representative Worker Runtime messages are encoded by Python and Elixir bindings
- **THEN** the other language decodes each fixture with semantic equality
- **AND** validation does not assume a universal canonical protobuf byte order
