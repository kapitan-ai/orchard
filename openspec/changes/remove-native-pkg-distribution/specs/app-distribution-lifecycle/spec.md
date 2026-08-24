## MODIFIED Requirements

### Requirement: DMG Is App-Primary

Orchard's interactive DMG in `SPEC.md` §11.3 SHALL contain a real signed `Orchard.app` as its install artifact and SHALL NOT require a native PKG artifact under the current distribution contract.

#### Scenario: Operator opens the DMG

- **WHEN** an operator mounts an Orchard DMG
- **THEN** the mounted image contains a verifiable `Orchard.app` whose embedded service payload can be inspected directly

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
