## MODIFIED Requirements

### Requirement: macOS Contract Lanes Remain Separate
macOS host-lifecycle validation, Orchard.app and DMG validation, and macOS MLX Node runtime validation SHALL run as separate applicable lanes.
Orchard.app and DMG validation SHALL be split into a packaging-contract lane and an app-and-DMG assembly lane.
The packaging-contract lane SHALL cover the shared payload, credential-free payload signing contracts, the Swift app package build and unit tests, the relocated-root app service lifecycle, and packaged `orchardctl` behavior without assembling `Orchard.app` or a DMG.
The app-and-DMG assembly lane SHALL cover app bundle assembly, credential-free app signing, and DMG handoff verification.
Credential-free signing-contract validation MAY run in normal CI.
Developer ID signing, notarization, stapling, and publication SHALL remain release-only operations.
Future Linux host and CUDA acceptance SHALL be added as separate lanes when their qualified profiles are proposed.
Fake or Linux portable validation MUST NOT replace real platform acceptance for platform-specific behavior.

#### Scenario: MLX provider behavior changes
- **WHEN** a change modifies the MLX runtime implementation or its provider mapping
- **THEN** provider-neutral conformance runs
- **AND** the Apple Silicon MLX acceptance lane runs

#### Scenario: Packaging contract changes while distribution is paused
- **WHEN** a change affects packaging and the committed Distribution Pause Control is paused
- **THEN** the packaging-contract lane runs
- **AND** the app-and-DMG assembly lane does not run

## ADDED Requirements

### Requirement: Paused Distribution Assembly Lanes Are Inapplicable
The app-and-DMG assembly lane SHALL be applicable only when packaging is affected and the committed Distribution Pause Control is active.
Lane selection SHALL read that committed control and SHALL fail closed to paused under the same rules as the distribution entrypoints.
The required repository gate SHALL treat a paused assembly lane as inapplicable, SHALL still require every other applicable lane, and SHALL fail if a paused or otherwise inapplicable assembly lane runs.
The pause SHALL NOT use workflow-level path filtering or change the required gate check name.
Distribution Pause guard regression tests SHALL run in required validation without assembling `Orchard.app` or a DMG.

#### Scenario: Paused pull request touches packaging
- **WHEN** a pull request affects packaging while the committed control is paused
- **THEN** the app-and-DMG assembly lane is skipped
- **AND** the required gate passes when every other applicable lane passes

#### Scenario: Paused assembly lane runs anyway
- **WHEN** the app-and-DMG assembly lane reports any result other than skipped while it is inapplicable
- **THEN** the required gate fails

#### Scenario: Distribution is resumed
- **WHEN** the committed control is active and a change affects packaging
- **THEN** the app-and-DMG assembly lane is required and must succeed for the gate to pass
