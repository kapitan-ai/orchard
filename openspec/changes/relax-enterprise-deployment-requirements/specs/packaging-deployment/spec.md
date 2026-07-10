## ADDED Requirements

### Requirement: PKG Supports Privileged Local Installation

Orchard's v1 macOS packaging contract in SPEC.md §11 SHALL require PKG support only for root-authorized local installation needs: launchd service installation, system support directories, wrapper scripts, role selection, upgrade handling, and repeatable operator-driven installation.

#### Scenario: Local PKG install remains supported

- **WHEN** an operator installs Orchard from a signed PKG on a Mac
- **THEN** the installer can install the configured role's launchd services and shared support-root files without relying on MDM or Jamf infrastructure

### Requirement: Managed Device Deployment Is Deferred

Orchard's v1 macOS packaging contract in SPEC.md §11 SHALL NOT require MDM, Jamf, or enterprise managed-device deployment as a supported current distribution channel.

#### Scenario: MDM is not an acceptance gate

- **WHEN** v1 packaging behavior is reviewed for release readiness
- **THEN** absence of Jamf or MDM deployment automation does not block the packaging milestone

### Requirement: Unattended Installer Command Remains Useful

Orchard's v1 macOS packaging contract in SPEC.md §11 SHALL retain support for `installer -pkg ... -target /` as a local and offline automation path.

#### Scenario: Scripted local install is allowed

- **WHEN** an operator or validation script runs the macOS `installer` command against the Orchard PKG
- **THEN** Orchard treats that as a supported local installation path independent of managed-device deployment

### Requirement: Distribution Artifacts Remain Generic

Orchard distribution artifacts SHALL remain generic across current channels, with customer attribution, license activation, database configuration, TLS material, and deployment secrets provided out of band.

#### Scenario: Activation stays separate

- **WHEN** Orchard is distributed through a signed PKG, interactive DMG wrapper, or future download channel
- **THEN** the artifact does not embed license keys, customer identifiers, database DSNs, production TLS material, or activation secrets
