## ADDED Requirements

### Requirement: Orchard.app Derives Its Managed Node Subtree from an Admitted Composition

The app assembly path SHALL accept a managed Node subtree only after the common composition verifier returns `admitted`.
The final app build evidence SHALL bind the embedded composition-lock digest and detached build-attestation digest.
App verification SHALL prove that the final embedded bytes and component identities match that admitted composition after signing.
The app MAY continue to contain Controller, CLI, Console, and all-in-one content governed by existing profile requirements.

#### Scenario: Admitted composition is embedded

- **WHEN** app assembly receives an admitted managed Node composition
- **THEN** it SHALL embed the declared Node-role subtree
- **AND** final app verification SHALL match the embedded bytes to the recorded composition identity

#### Scenario: Embedded bytes differ after assembly or signing

- **WHEN** any embedded managed Node byte or identity differs from the admitted composition
- **THEN** app verification SHALL fail
- **AND** the app SHALL NOT proceed to DMG assembly

### Requirement: Release Manifest and DMG Preserve Acyclic Composition Identity

The Candidate or Internal Build Manifest SHALL record the final app-tree identity and embedded composition-lock digest.
The composition lock SHALL NOT reference that later release manifest.
DMG assembly SHALL package the exact verified app tree and SHALL retain the existing signing, Gatekeeper, notarization, stapling, and artifact-verification gates appropriate to the build stage.

#### Scenario: Verified app is packaged into a DMG

- **WHEN** the release manifest records the exact verified app tree and embedded composition-lock digest
- **THEN** DMG assembly SHALL package that exact app tree
- **AND** every later artifact identity SHALL point back to, rather than be referenced by, the composition lock

### Requirement: Composition Inputs Are Not Standalone Distributions

Component archives, component manifests, composition locks, and detached build attestations SHALL be treated as assembly inputs or evidence only.
They SHALL NOT expose an independent supported installation path, update path, publication claim, or distribution profile.

#### Scenario: Operator has a component archive without Orchard.app

- **WHEN** an operator presents a valid component archive, composition lock, or build attestation outside verified app assembly
- **THEN** Orchard SHALL NOT treat it as an installable or supported distribution artifact

### Requirement: Native PKG Remains Outside Managed Composition Delivery

Managed Node composition assembly, activation, migration, rollback, and verification SHALL NOT use native PKG receipts, payloads, installer scripts, ownership transfer, or removed-PKG handover state.
Existing legacy receipt detection MAY continue only under its current conflict-prevention contract.

#### Scenario: Native PKG evidence is presented for transition

- **WHEN** a managed composition transition receives a native PKG receipt or removed handover artifact as provenance or custody evidence
- **THEN** Orchard SHALL ignore it for admission
- **AND** SHALL NOT weaken the managed composition verification or process fence
