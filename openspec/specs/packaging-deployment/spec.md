# packaging-deployment Specification

## Purpose

Defines Orchard's current macOS packaging and distribution requirements: signed PKG remains a parallel root-authorized local and offline installer, managed-device channels are deferred, unattended `installer` remains supported, and reusable distribution artifacts remain generic and free of customer or deployment secrets.

This capability is the sole owner of the generic-distribution-artifact contract; `app-distribution-lifecycle` scopes itself to app-specific behavior and does not restate it. Homebrew has no requirement here: it is neither a current channel nor a v1 release gate, and adopting it would need its own change package.

## Requirements

### Requirement: PKG Supports Privileged Local Installation

Orchard's v1 macOS packaging contract in `SPEC.md` §11 SHALL retain signed PKG as a supported parallel path for root-authorized local installation needs: launchd service installation, system support directories, wrapper scripts, role selection, upgrades, repeatable operator-driven installation, and offline/manual distribution.

#### Scenario: Local PKG install remains supported

- **WHEN** an operator installs Orchard from a signed PKG on a Mac
- **THEN** the installer can install the configured role's launchd services and shared support-root files without relying on MDM or Jamf infrastructure

### Requirement: Managed Device Deployment Is Deferred

Orchard's v1 macOS packaging contract in `SPEC.md` §11 SHALL NOT require MDM, Jamf, or enterprise managed-device deployment as a supported current distribution channel.

#### Scenario: MDM is not an acceptance gate

- **WHEN** v1 packaging behavior is reviewed for release readiness
- **THEN** absence of Jamf or MDM deployment automation does not block the packaging milestone

### Requirement: Unattended Installer Command Remains Useful

Orchard's v1 macOS packaging contract in `SPEC.md` §11 SHALL retain support for `installer -pkg ... -target /` as a local, repeatable, and offline automation path.

#### Scenario: Scripted local install is allowed

- **WHEN** an operator or validation script runs the macOS `installer` command against the Orchard PKG
- **THEN** Orchard treats that as a supported local installation path independent of managed-device deployment

### Requirement: Distribution Artifacts Remain Generic

Orchard distribution artifacts SHALL remain generic across app, DMG, PKG, and future release channels, with customer attribution, license activation, database configuration, TLS material, and deployment secrets provided out of band.

#### Scenario: Activation stays separate

- **WHEN** Orchard is distributed through an app-primary DMG, signed PKG, or future download channel
- **THEN** the artifact does not embed license keys, customer identifiers, database DSNs, production TLS material, or activation secrets

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
