## RENAMED Requirements

- FROM: `### Requirement: Platform Acceptance Remains Separate`
- TO: `### Requirement: macOS Contract Lanes Remain Separate`

## MODIFIED Requirements

### Requirement: Required Linux Portable Validation
Every non-documentation product change that can affect the portable Orchard control-plane core SHALL run required Linux validation for portable application compilation, static analysis, tests, and coverage without Apple or accelerator toolchains.
The lane SHALL include the portable tokenizer workflow and Worker Runtime stubs that do not import accelerator implementations.

#### Scenario: Controller source changes
- **WHEN** a change modifies portable Controller behavior
- **THEN** required validation runs on Linux
- **AND** the validation does not provision Xcode, launchd, MLX, or CUDA

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
