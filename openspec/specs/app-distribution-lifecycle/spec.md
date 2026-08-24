# app-distribution-lifecycle Specification

## Purpose

Defines Orchard's app-primary macOS distribution lifecycle, including app assembly and release sidecars, root-authorized role-aware service operations, transactional rollback and operator-state retention, inner-first signing, and verified Amore DMG handoff.

The generic-distribution-artifact contract that the archived `2026-07-20-amore-dmg-service-lifecycle` delta also proposed here is owned solely by `packaging-deployment`, so it is deliberately not restated in this capability.

## Requirements

### Requirement: DMG Is App-Primary

Orchard's interactive DMG in `SPEC.md` §11.3 SHALL contain a real signed `Orchard.app` as its install artifact and SHALL NOT require a native PKG artifact under the current distribution contract.

#### Scenario: Operator opens the DMG

- **WHEN** an operator mounts an Orchard DMG
- **THEN** the mounted image contains a verifiable `Orchard.app` whose embedded service payload can be inspected directly

### Requirement: Release Metadata Is Verifiable Without Rewriting The DMG

The Orchard release distribution set SHALL place release notes, a SHA-256 checksum, and before/after app-signing manifests alongside the Amore-produced DMG.
Orchard SHALL NOT rewrite the DMG after Amore has assembled or notarized it to inject metadata.

#### Scenario: Operator receives a release distribution set

- **WHEN** Orchard marks a DMG distribution set ready
- **THEN** the set contains the DMG, release notes, its SHA-256 checksum, and the app-signing manifests used to prove nested signature preservation

### Requirement: App Owns A Root-Authorized Service Lifecycle

`Orchard.app` SHALL own a lifecycle interface for role-aware install, update, uninstall, and status operations, and system-root mutation SHALL require effective root privileges with effective user id 0.

#### Scenario: Non-root system mutation is refused

- **WHEN** a non-root process requests app-owned install, update, or uninstall against the system root
- **THEN** Orchard refuses before changing files, launchd state, role markers, or service state

#### Scenario: Relocated integration root is safe

- **WHEN** the lifecycle interface targets a non-system root for validation
- **THEN** every installed path and launchd effect is relocated or simulated without changing the host's Orchard installation

### Requirement: Lifecycle Updates Are Transactional

App-owned install and update SHALL preflight before stopping services and SHALL restore the prior app-owned payload, links, plists, role marker, and loaded-service state when a commit-phase failure occurs.

#### Scenario: Update fails after mutation begins

- **WHEN** an app-owned update fails after one or more app-owned paths or launchd records have changed
- **THEN** Orchard restores the complete prior app-owned state and reports whether rollback succeeded

### Requirement: Operator State Is Preserved

App-owned install and update SHALL preserve operator-owned `config`, `data`, `models`, `bundles`, `logs`, and support-bundle contents, and default uninstall SHALL retain those paths while removing app-owned payloads, links, launchd plists, and install markers.

#### Scenario: Default uninstall retains recoverable state

- **WHEN** an operator runs app-owned uninstall without a separately approved destructive purge operation
- **THEN** Orchard removes executable service artifacts and retains operator configuration, data, models, bundles, logs, and support bundles

### Requirement: TLS State Fails Closed

The app lifecycle SHALL preserve complete TLS state, SHALL reject partial TLS state before mutation, SHALL NOT generate or trust production TLS material, and SHALL NOT mutate system trust stores.

#### Scenario: Partial TLS state blocks mutation

- **WHEN** the target contains only part of the expected TLS state
- **THEN** app-owned install or update fails before changing payloads, services, roles, TLS files, or trust stores

### Requirement: Lifecycle Status Is Non-Mutating

App-owned lifecycle status SHALL report the selected role, installation source, retained-state roots, and launchd state without changing the target.

#### Scenario: Operator inspects status

- **WHEN** an operator requests lifecycle status for the system root or a relocated root
- **THEN** Orchard returns the observable lifecycle state without changing files, markers, or services

### Requirement: Orchard Preserves Inner-First App Signing

Orchard SHALL sign nested Mach-O libraries and executables with their required entitlements before signing app helpers, the main app executable, and the outer `Orchard.app` bundle, and SHALL verify the final bundle strictly before DMG assembly.

#### Scenario: App is ready for the outer distribution layer

- **WHEN** Orchard hands an app bundle to Amore
- **THEN** every nested Mach-O and the final app bundle have passed Orchard-owned identity, hardened-runtime, entitlement, closure, and signature verification appropriate to the build mode

### Requirement: Amore Handoff Fails Closed On Nested Mutation

The Amore DMG handoff SHALL compare signing manifests before and after DMG assembly and SHALL fail when nested code signatures or entitlements change unexpectedly.

#### Scenario: Amore changes nested code

- **WHEN** the mounted DMG contains an app whose nested signature or canonical entitlement digest differs from the verified input app
- **THEN** Orchard rejects the DMG and does not mark it ready for notarization, publication, or distribution
