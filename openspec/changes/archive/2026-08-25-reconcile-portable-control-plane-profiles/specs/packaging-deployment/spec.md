## RENAMED Requirements

- FROM: `### Requirement: DMG And Orchard.app Are The Current Native Distribution`
- TO: `### Requirement: DMG And Orchard.app Are The Approved macOS Native Distribution`
- FROM: `### Requirement: Distribution Requirements Are Platform Profile Scoped`
- TO: `### Requirement: Distribution Requirements Are Distribution-Profile Scoped`
- FROM: `### Requirement: Platform Runtime Payloads Are Selected Explicitly`
- TO: `### Requirement: Distribution Payloads Are Selected Explicitly`

## ADDED Requirements

### Requirement: Source Availability Does Not Imply Public Binary Support

Orchard SHALL permit the initial Curated OSS transition to be source-first without publishing a supported public binary.
Source availability SHALL NOT be represented as public binary availability or support.
A supported public binary SHALL require an explicit release decision and completion of every applicable build, verification, signing, notarization, stapling, and publication gate.

#### Scenario: Source is available before public binaries

- **WHEN** Orchard source is available without an approved public binary release
- **THEN** documentation does not promise a supported downloadable binary
- **AND** the approved Orchard.app-inside-DMG design remains unchanged

## MODIFIED Requirements

### Requirement: DMG And Orchard.app Are The Approved macOS Native Distribution

The approved macOS native distribution profile SHALL use a signed and notarized DMG containing `Orchard.app`.
The app-owned lifecycle SHALL remain the current root-authorized path for role-aware service installation, update, uninstall, and status.

#### Scenario: Current macOS distribution is assembled

- **WHEN** Orchard produces a supported macOS distribution
- **THEN** the distribution contains a verifiable `Orchard.app` in the DMG
- **AND** it does not require a native PKG artifact

### Requirement: Distribution Requirements Are Distribution-Profile Scoped

DMG, Orchard.app, launchd, Keychain, Apple signing, notarization, and stapling requirements SHALL apply to the macOS native distribution profile and SHALL remain release gates for that profile.
Portable Orchard control-plane core compilation and the Linux Controller profile MUST NOT require those Apple distribution tools.
Generic secret-free artifact, Product Version, trust, role, rollback, retained-state, and protocol compatibility invariants SHALL remain shared where applicable across profiles.

#### Scenario: macOS release is produced

- **WHEN** Orchard produces a supported macOS distribution
- **THEN** the app, DMG, launchd, signing, notarization, and retained-state requirements remain applicable

#### Scenario: Linux Controller is compiled and validated

- **WHEN** Orchard compiles or validates the portable Orchard control-plane core for the Linux Controller profile
- **THEN** the workflow does not require Apple packaging or publication tools
- **AND** it still enforces generic version, trust, secret-free artifact, and protocol compatibility contracts

### Requirement: Distribution Payloads Are Selected Explicitly

A distribution profile SHALL contain only runtime providers and native host artifacts compatible with its declared platform and runtime-provider profiles.
The macOS native distribution profile SHALL retain the accepted Controller, Node Agent, MLX, tokenizer, app-owned host lifecycle, and role-selected payload behavior for the all-in-one topology until a separately accepted change supersedes it.

#### Scenario: Mac all-in-one artifact is assembled

- **WHEN** the existing macOS all-in-one topology is built during the portability migration
- **THEN** it continues to contain the accepted Mac-compatible role payloads
- **AND** no future Linux or CUDA payload is required for acceptance
