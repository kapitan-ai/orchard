## ADDED Requirements

### Requirement: Distribution Requirements Are Platform Profile Scoped
DMG, PKG, Orchard.app, launchd, Keychain, Apple signing, notarization, and stapling requirements SHALL apply to the macOS distribution profile and SHALL remain release gates for that profile.
Portable Controller compilation and the Linux Controller profile MUST NOT require those Apple distribution tools.
Generic secret-free artifact, Product Version, trust, role, rollback, retained-state, and protocol compatibility invariants SHALL remain shared where applicable across profiles.
This requirement refines `SPEC.md` §11 without changing existing macOS distribution acceptance.

#### Scenario: macOS release is produced
- **WHEN** Orchard produces a supported macOS distribution
- **THEN** the existing app, DMG, PKG, launchd, signing, notarization, and retained-state requirements remain applicable

#### Scenario: Linux Controller is compiled and validated
- **WHEN** Orchard compiles or validates the portable Linux Controller profile
- **THEN** the workflow does not require Apple packaging or publication tools
- **AND** it still enforces generic version, trust, secret-free artifact, and protocol compatibility contracts

### Requirement: Platform Runtime Payloads Are Selected Explicitly
A platform distribution SHALL contain only runtime providers and native host artifacts compatible with its declared profile.
The macOS all-in-one profile SHALL retain its current Controller, Node Agent, MLX, tokenizer, host lifecycle, and role-selected payload behavior until a separately accepted packaging change supersedes it.

#### Scenario: Mac all-in-one artifact is assembled
- **WHEN** the existing macOS all-in-one profile is built during this portability migration
- **THEN** it continues to contain the accepted Mac-compatible role payloads
- **AND** no future Linux or CUDA payload is required for acceptance
