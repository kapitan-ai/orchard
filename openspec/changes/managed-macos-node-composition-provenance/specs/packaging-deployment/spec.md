## ADDED Requirements

### Requirement: Node Subtree Assembly Requires Purpose-Bound Admission

App assembly SHALL embed a managed Node subtree only when the verifier returns `admitted` for purpose `assemble_node_subtree`, the exact app-build stage, and the target managed profile.
The admitted subtree SHALL contain only final signed generation bytes and SHALL remain byte-identical through embedding.
Assembly admission SHALL NOT authorize installation, activation, rollback, start, scheduling, delivery, or publication.

#### Scenario: Admitted subtree is embedded

- **WHEN** the closed signed Node subtree has a matching assembly-purpose decision
- **THEN** app assembly MAY embed those exact bytes

#### Scenario: Assembly decision is used for activation

- **WHEN** lifecycle code receives an assembly-purpose decision as activation authority
- **THEN** it SHALL reject the decision

### Requirement: App and DMG Identity Follow the Existing Signing Pipeline

Nested generation code SHALL be signed before its component manifests and composition lock are sealed.
The app SHALL then sign stable helpers, the main executable, and the outer app in the existing inner-to-outer order and verify the complete final app tree.
DMG assembly, notarization, stapling, mounting, and nested verification SHALL then be mandatory before final candidate identity is accepted.

#### Scenario: Final app is verified

- **WHEN** the embedded Node subtree remains exact and all app signing and verification gates pass
- **THEN** Orchard SHALL record the complete final app-tree identity including signatures and `CodeResources`

#### Scenario: DMG mutates the nested app

- **WHEN** mounted-DMG verification observes a changed nested byte, signature, entitlement, subtree, or app identity
- **THEN** Orchard SHALL reject the DMG and every dependent activation decision

### Requirement: Candidate Manifest Seals Final Required Identities

The Candidate Manifest SHALL be sealed only after every required artifact has final verified identity.
It SHALL bind Product Version, exact commit, final app tree, managed Node subtree, composition lock, stable-bootstrap identity, target profile, and mandatory final DMG identity.
The composition lock SHALL NOT reference the later Candidate Manifest.

#### Scenario: Candidate Manifest is sealed

- **WHEN** every required app and DMG identity is final and verified
- **THEN** release governance MAY canonically serialize and digest the manifest
- **AND** activation authorization MAY bind that exact manifest digest

#### Scenario: Manifest is sealed before final artifact verification

- **WHEN** a required signing, notarization, stapling, mounting, or verification step remains
- **THEN** the Candidate Manifest SHALL remain unsealed and ineligible for activation authorization

### Requirement: Stable Bootstrap Is Outside the Replaceable Generation

The app SHALL carry the stable signed lifecycle, launch-gate, recovery, active-pointer, and privileged-helper bootstrap outside the managed Node generation subtree.
Managed composition activation SHALL NOT replace or update that bootstrap, its launchd plist, launch label, pointer path, or trust policy.
Before Controller transition creation, the installed bootstrap SHALL mount and verify the mandatory DMG and final app, require the embedded bootstrap identity to equal the installed bootstrap identity, and import only the admitted Node subtree into a new immutable generation.
It SHALL NOT install or replace `Orchard.app` through the generic app lifecycle.

#### Scenario: Candidate requires another bootstrap

- **WHEN** the candidate's exact bootstrap or helper requirement does not match the installed verified bootstrap
- **THEN** activation SHALL fail before Controller drain or host mutation

#### Scenario: Verified candidate is staged

- **WHEN** the mandatory DMG, mounted final app, Candidate Manifest, embedded bootstrap, and admitted Node subtree all match
- **THEN** the installed bootstrap MAY import only that Node subtree into a new immutable candidate generation before Controller transition creation

### Requirement: Composition Inputs Are Not Standalone Distributions

Component archives, manifests, generation directories, composition locks, verifier decisions, and build attestations SHALL be assembly inputs or evidence only.
They SHALL NOT expose an independent supported installation, update, publication, or distribution path.

#### Scenario: Operator has a component archive without governed app evidence

- **WHEN** a valid component archive or composition lock is presented outside the final app and Candidate Manifest binding
- **THEN** Orchard SHALL NOT treat it as installable or supported

### Requirement: Native PKG Remains Outside Managed Delivery

Managed composition provisioning, activation, rollback, recovery, and verification SHALL NOT use native PKG payloads, receipts, installer scripts, ownership transfer, or removed handover state as authority.
Existing legacy receipt detection MAY continue only under its current conflict-prevention contract.

#### Scenario: Native PKG evidence is presented

- **WHEN** a managed transition receives a native PKG receipt or removed handover artifact as provenance or custody evidence
- **THEN** Orchard SHALL reject it as managed-profile authority
