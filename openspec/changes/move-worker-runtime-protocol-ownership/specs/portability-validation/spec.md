## MODIFIED Requirements

### Requirement: Validation Triggers Follow Dependencies

Validation selection SHALL follow owned dependency edges and contract fan-out rather than directory names alone.
Changes to the provider-neutral Worker Runtime schema, generator or check inputs, committed Python or Elixir bindings, descriptor golden, root configuration, toolchain, release composition, normative product contracts, or a portable interface SHALL trigger every consuming lane needed to prove compatibility.
Documentation-only optimization MUST NOT classify a normative `SPEC.md` or OpenSpec contract change as ordinary prose that skips applicable validation.

#### Scenario: Worker protocol changes

- **WHEN** the provider-neutral Worker Runtime protocol changes
- **THEN** portable binding and conformance lanes run
- **AND** every supported runtime-provider acceptance lane runs

#### Scenario: Generated binding infrastructure changes

- **WHEN** the Worker Runtime generator, drift check, or committed binding changes
- **THEN** portable binding and provider-neutral conformance lanes run
- **AND** macOS host, MLX provider, packaging, and OpenSpec validation lanes run
