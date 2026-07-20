# packaging-deployment Specification

## Purpose

Defines Orchard's current macOS packaging and distribution requirements: signed PKG remains a parallel root-authorized local and offline installer, managed-device channels are deferred, unattended `installer` remains supported, and reusable distribution artifacts remain generic and free of customer or deployment secrets.

## Requirements

### Requirement: PKG Supports Privileged Local Installation

Orchard's v1 macOS packaging contract in `SPEC.md` §11 SHALL retain signed PKG as a supported parallel path for root-authorized local installation needs: launchd service installation, system support directories, wrapper scripts, role selection, upgrades, repeatable operator-driven installation, and offline/manual distribution.

#### Scenario: Local PKG install remains supported

- **WHEN** an operator installs Orchard from a signed PKG on a Mac
- **THEN** the installer can install the configured role's launchd services and shared support-root files without relying on MDM or Jamf infrastructure

### Requirement: Managed Device Deployment Is Deferred

Orchard's v1 macOS packaging contract in `SPEC.md` §11 SHALL NOT require MDM, Jamf, or enterprise managed-device deployment as a supported current distribution channel.
Homebrew MAY be considered as an optional future or convenience channel, but SHALL NOT be a v1 release gate.

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
