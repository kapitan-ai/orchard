## ADDED Requirements

### Requirement: Native PKG Distribution Is Not Supported

Native PKG SHALL NOT be a current supported distribution channel, release artifact, operator workflow, or validation gate.
The app MAY retain legacy PKG receipt detection solely to prevent silent ownership takeover of an existing installation.

#### Scenario: A legacy PKG receipt is present

- **WHEN** the app detects a legacy PKG receipt
- **THEN** it blocks app-owned lifecycle takeover
- **AND** receipt detection does not establish an active distribution contract or supported install path

### Requirement: Future Distribution Channels Require Fresh Approval

A future native package or additional distribution channel SHALL require a fresh accepted OpenSpec proposal and a separate implementing pull request before support is claimed.
That proposal and pull request SHALL update `SPEC.md`, security posture, operator documentation, artifact governance, and validation gates for the proposed channel.

#### Scenario: A native package is proposed later

- **WHEN** Orchard considers restoring PKG or adding another distribution channel
- **THEN** existing legacy material is insufficient authority to ship it
- **AND** review begins from a fresh proposal and implementing pull request

## MODIFIED Requirements

### Requirement: DMG And Orchard.app Are The Current Native Distribution

Orchard's current macOS distribution SHALL use a signed and notarized DMG containing `Orchard.app`.
The app-owned lifecycle SHALL remain the current root-authorized path for role-aware service installation, update, uninstall, and status.

#### Scenario: Current macOS distribution is assembled

- **WHEN** Orchard produces a supported macOS distribution
- **THEN** the distribution contains a verifiable `Orchard.app` in the DMG
- **AND** it does not require a native PKG artifact

### Requirement: Distribution Artifacts Remain Generic

Orchard distribution artifacts SHALL remain generic across app, DMG, and future approved release channels, with database configuration, TLS material, and deployment secrets provided out of band.

#### Scenario: Deployment secrets stay separate

- **WHEN** Orchard is distributed through the app-primary DMG or a future approved channel
- **THEN** the artifact does not embed customer identifiers, database DSNs, production TLS material, or deployment secrets
- **AND** the artifact does not require product-license activation

### Requirement: Distribution Requirements Are Platform Profile Scoped

DMG, Orchard.app, launchd, Keychain, Apple signing, notarization, and stapling requirements SHALL apply to the macOS distribution profile and SHALL remain release gates for that profile.
Portable Controller compilation and the Linux Controller profile MUST NOT require those Apple distribution tools.
Generic secret-free artifact, Product Version, trust, role, rollback, retained-state, and protocol compatibility invariants SHALL remain shared where applicable across profiles.

#### Scenario: macOS release is produced

- **WHEN** Orchard produces a supported macOS distribution
- **THEN** the app, DMG, launchd, signing, notarization, and retained-state requirements remain applicable

#### Scenario: Linux Controller is compiled and validated

- **WHEN** Orchard compiles or validates the portable Linux Controller profile
- **THEN** the workflow does not require Apple packaging or publication tools
- **AND** it still enforces generic version, trust, secret-free artifact, and protocol compatibility contracts
