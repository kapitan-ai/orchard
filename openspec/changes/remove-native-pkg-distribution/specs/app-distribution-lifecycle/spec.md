## RENAMED Requirements

- FROM: `### Requirement: TLS And Package Ownership Fail Closed`
- TO: `### Requirement: TLS State Fails Closed`

## ADDED Requirements

### Requirement: Legacy Package Ownership Blocks App Takeover

The app lifecycle SHALL refuse system-root install, update, and uninstall while a `com.orchard.pkg` receipt exists, and SHALL fail closed before any mutation, as required by `SPEC.md` §11.4.
Retaining that refusal SHALL NOT establish native PKG as a supported distribution channel, release artifact, operator workflow, or validation gate.

#### Scenario: Legacy package receipt blocks app takeover

- **WHEN** the system root has a `com.orchard.pkg` receipt and the app lifecycle is asked to install, update, or uninstall it
- **THEN** Orchard refuses without changing installed state
- **AND** the refusal does not claim a supported native PKG install path

## MODIFIED Requirements

### Requirement: DMG Is App-Primary

Orchard's interactive DMG in `SPEC.md` §11.3 SHALL contain a real signed `Orchard.app` as its install artifact and SHALL NOT require a native PKG artifact under the current distribution contract.

#### Scenario: Operator opens the DMG

- **WHEN** an operator mounts an Orchard DMG
- **THEN** the mounted image contains a verifiable `Orchard.app` whose embedded service payload can be inspected directly

### Requirement: TLS State Fails Closed

The app lifecycle SHALL preserve complete TLS state, SHALL reject partial TLS state before mutation, SHALL NOT generate or trust production TLS material, and SHALL NOT mutate system trust stores.
The package-ownership clause that previously shared this requirement moves to `Legacy Package Ownership Blocks App Takeover` so the receipt blocker keeps an explicit normative owner.

#### Scenario: Partial TLS state blocks mutation

- **WHEN** the target contains only part of the expected TLS state
- **THEN** app-owned install or update fails before changing payloads, services, roles, TLS files, or trust stores

### Requirement: Lifecycle Status Is Non-Mutating

App-owned lifecycle status SHALL report the selected role, installation source, retained-state roots, launchd state, and blocking legacy package receipt without changing the target.

#### Scenario: Operator inspects status

- **WHEN** an operator requests lifecycle status for the system root or a relocated root
- **THEN** Orchard returns the observable lifecycle state without changing files, markers, receipts, or services

## REMOVED Requirements

### Requirement: PKG Compatibility Is Preserved
