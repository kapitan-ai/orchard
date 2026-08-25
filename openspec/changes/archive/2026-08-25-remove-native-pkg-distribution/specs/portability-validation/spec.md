## RENAMED Requirements

- FROM: `### Requirement: Platform Acceptance Remains Separate`
- TO: `### Requirement: macOS Contract Lanes Remain Separate`

## MODIFIED Requirements

### Requirement: macOS Contract Lanes Remain Separate

macOS host-lifecycle validation, Orchard.app and DMG validation, and macOS MLX Node runtime validation SHALL run as separate applicable lanes.
Credential-free signing-contract validation MAY run in normal CI.
Developer ID signing, notarization, stapling, and publication SHALL remain release-only operations.
Future Linux host and CUDA acceptance SHALL be added as separate lanes when their qualified profiles are proposed.
Fake or Linux portable validation MUST NOT replace real platform acceptance for platform-specific behavior.

#### Scenario: MLX provider behavior changes

- **WHEN** a change modifies the MLX runtime implementation or its provider mapping
- **THEN** provider-neutral conformance runs
- **AND** the Apple Silicon MLX acceptance lane runs
