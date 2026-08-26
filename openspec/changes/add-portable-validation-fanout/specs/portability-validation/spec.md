## MODIFIED Requirements

### Requirement: Validation Triggers Follow Dependencies

Validation selection SHALL follow owned dependency edges and contract fan-out rather than directory names alone.
The repository SHALL own an executable classifier that emits independent portable, provider-neutral conformance, macOS host, MLX provider, and packaging decisions from changed paths.
Changes to shared contracts, proto source, root configuration, toolchain, release composition, normative product contracts, accepted OpenSpec contracts, or the required workflow SHALL trigger every consuming lane needed to prove compatibility.
Documentation-only optimization MUST NOT classify a normative `SPEC.md` or OpenSpec contract change as ordinary prose that skips applicable validation.
Unknown paths MUST select every lane rather than risk missing a dependency edge.

#### Scenario: Worker protocol changes

- **WHEN** the provider-neutral Worker Runtime protocol changes
- **THEN** portable binding and conformance lanes run
- **AND** every supported runtime-provider acceptance lane runs

#### Scenario: Controller-only portable change

- **WHEN** a change modifies only portable Controller behavior
- **THEN** the Linux portable and provider-neutral conformance lanes run
- **AND** unrelated macOS host, MLX provider, and packaging lanes are explicitly inapplicable

#### Scenario: Ordinary documentation changes

- **WHEN** a change modifies only non-normative documentation
- **THEN** heavy validation lanes may be explicitly inapplicable
- **AND** the required aggregate gate still evaluates their skipped results

### Requirement: Required Gate Aggregates Conditional Lanes

The required repository gate named `Required Orchard validation gate` SHALL fail when any applicable portable, conformance, platform, or packaging lane fails and SHALL succeed only when every applicable lane passes and every inapplicable lane is explicitly skipped under the dependency rules.
Changed-path classification failure, a skipped applicable lane, or an executed inapplicable lane MUST fail the aggregate.
The aggregate decision SHALL be implemented by a repository-owned evaluator with deliberate success and failure tests.

#### Scenario: Controller-only portable change

- **WHEN** dependency classification proves that no platform implementation or packaging contract is affected
- **THEN** the required gate omits expensive platform lanes
- **AND** it still requires the Linux portable and applicable conformance lanes

#### Scenario: Applicable lane fails or skips

- **WHEN** any lane selected by dependency classification fails or is skipped
- **THEN** the required aggregate gate fails

#### Scenario: Inapplicable lane does not skip

- **WHEN** a lane classified as inapplicable reports success, failure, or cancellation instead of skipped
- **THEN** the required aggregate gate fails closed
