## MODIFIED Requirements

### Requirement: DMG Is App-Primary

Orchard's interactive DMG in `SPEC.md` §11.3 SHALL contain a real signed app as its install artifact and SHALL NOT require a native PKG artifact.
The existing all-in-one artifact SHALL contain `Orchard.app`.
The dedicated Node artifact SHALL contain `Orchard Node.app`.
This changes the named app requirement in `SPEC.md` §11.3 while retaining the app-primary DMG contract.

#### Scenario: Operator opens the DMG

- **WHEN** an operator mounts an Orchard DMG
- **THEN** the mounted image contains the verifiable app for its declared profile
- **AND** the embedded service payload can be inspected directly

### Requirement: App Owns A Root-Authorized Service Lifecycle

`Orchard.app` SHALL retain its role-aware install, update, uninstall, and status interface.
`Orchard Node.app` SHALL own an equivalent lifecycle constrained to the dedicated Node profile and its owned paths, commands, services, configuration, receipt, retained ownership record, and app-specific release-trust store.
System-root mutation SHALL require effective root privileges with effective user id 0.
The dedicated helper SHALL authenticate its caller and SHALL NOT treat signed code identity as sufficient permission for mutation.
Signed-app requests SHALL require a fresh `com.orchard.node.lifecycle.manage` Authorization Services authorization after administrator authentication and SHALL bind the operation, input digest, audit identity, helper nonce, and request sequence to one promptly expiring session.
Direct root CLI requests MAY originate only from the verified installed `orchard-node` executable with effective user id 0.
The helper SHALL reject authorization replay, arbitrary execution, Controller or database roles, customer CA administration, macOS system trust mutation, and unowned path or service requests.
It MAY expose one fixed app-specific release-trust operation that accepts only a monotonic registry update authorized by an already trusted unrevoked release root.
This changes `SPEC.md` §§11.1-11.4 by adding a separately owned Node-only lifecycle.

#### Scenario: Non-root system mutation is refused

- **WHEN** a non-root process requests app-owned install, update, repair, or uninstall against the system root
- **THEN** Orchard refuses before changing files, launchd state, receipts, or service state

#### Scenario: Relocated integration root is safe

- **WHEN** the lifecycle targets a non-system root for validation
- **THEN** every installed path and launchd effect is relocated or simulated
- **AND** the host's Orchard installation is unchanged

#### Scenario: Node helper receives broader authority

- **WHEN** a caller requests Controller installation, arbitrary execution, system trust mutation, or an unowned path
- **THEN** the helper rejects the request before mutation even when the caller can request local lifecycle operations

#### Scenario: Signed app has no administrator consent

- **WHEN** the genuine signed app requests a privileged operation without a fresh matching administrator authorization session
- **THEN** the helper refuses before mutation
- **AND** code identity does not substitute for authorization

### Requirement: Lifecycle Updates Are Transactional

For the existing `Orchard.app`, app-owned install and update SHALL retain their current preflight, snapshot, rollback, and prior loaded-service restoration behavior.
The dedicated Node profile SHALL enable initial real-system installation only after exact release and activation verification succeeds.
Initial installation SHALL establish serialized local custody, write a durable incomplete-operation marker before its first mutation, update the active receipt and retained ownership record atomically, restore verified pre-mutation state where possible, and remain stopped with an actionable repair status whenever completion or rollback is uncertain.
For the dedicated Node profile only, manual replacement SHALL first establish Controller cordon, completed drain, maintenance state, prevented restart, serialized local custody, and verified exit of the exact Node Agent and Worker Runtime processes.
The dedicated profile SHALL restore Node-owned bytes and records after a caught failure where possible.
It SHALL restore serving eligibility only after revalidating lifecycle certainty, retained identity and configuration, Release Activation Attestation, compatibility, admission, Peer Grant, production transport, runtime readiness, and Controller dispatch authority.
Incomplete or unverifiable rollback SHALL remain stopped and visibly require repair.
This narrowly changes `SPEC.md` §11.4 for dedicated-Node install and manual replacement and does not authorize managed source-baseline handover or overlapping processes sharing a Node Identity Root.

#### Scenario: Initial install is interrupted

- **WHEN** dedicated Node installation stops after its durable marker and before its active receipt commits
- **THEN** retry or status resolves the recorded transaction without adopting partial state
- **AND** serving remains disabled until completion is proven

#### Scenario: Update fails after mutation begins

- **WHEN** a dedicated Node update fails after one or more Node-owned paths or launchd records change
- **THEN** the lifecycle attempts to restore the complete prior Node-owned state and reports whether rollback succeeded
- **AND** serving remains disabled until the restart gate passes

#### Scenario: Node process exit cannot be verified

- **WHEN** update cannot prove Controller exclusion, restart suppression, or exact Node and Worker Runtime exit
- **THEN** replacement fails before payload mutation
- **AND** it does not start a second Node process

#### Scenario: Rollback restores withdrawn bytes

- **WHEN** prior Node bytes are restored but their activation authority is withdrawn or expired
- **THEN** the Node remains stopped with an actionable repair status

### Requirement: Orchard Preserves Inner-First App Signing

Orchard SHALL sign nested Mach-O libraries and executables with their required entitlements before signing app helpers, the main app executable, and the outer app bundle.
It SHALL verify the final bundle strictly before DMG assembly.
This SHALL apply to both `Orchard.app` and `Orchard Node.app`, with each profile's own identifiers, closure rules, and permitted entitlements.
This changes the named app scope in `SPEC.md` §§11.3-11.4 without changing inner-first signing or mounted verification.

#### Scenario: App is ready for the outer distribution layer

- **WHEN** Orchard hands either profile's app bundle to Amore
- **THEN** every nested Mach-O and the final app bundle have passed identity, hardened-runtime, entitlement, closure, and signature verification for that build mode

## ADDED Requirements

### Requirement: Dedicated Node Repair Uses A Distinct Ownership Gate

The dedicated lifecycle SHALL retain a root-owned `config/lifecycle-ownership.json` outside replaceable payload bytes.
It SHALL bind profile, installed app and payload identity, Node ID when present, service UID and GID, owned paths, receipt generation, last completed transaction, and retained-state disposition.
Ordinary update SHALL require an intact active receipt and exact owned-path verification.
Repair MAY enter from an intact active receipt or matching retained ownership record only when signed app identity, fixed profile, service identity, installation root, Node Identity Root, and non-secret ownership facts agree.
Repair SHALL be diagnostic first and MAY restore only verified Node-owned executable, service, command, configuration, and receipt state.
It SHALL NOT infer custody from retained Node identity alone, reissue identity, redeem enrollment, accept partial TLS, mutate customer or system trust, or restore serving because bytes were restored.
Before mutating runtime-affecting state, repair SHALL suppress restart, acquire serialized local custody, and verify exact Node Agent and Worker Runtime exit.
When the Controller is reachable, mutating repair SHALL also require Controller maintenance exclusion.
When the Controller is unreachable, repair MAY change verified local Node-owned state only while launchd remains disabled and SHALL record `remote coordination pending`; it SHALL NOT restart or restore eligibility until Controller state is reconciled.
When neither receipt nor retained ownership evidence proves custody, repair SHALL stop before mutation and require an explicit Controller decommission plus an owner-approved forensic or fresh-host path.
Default removal SHALL update and retain the ownership record without granting cluster trust or serving authority.

#### Scenario: Receipt is damaged but retained ownership agrees

- **WHEN** repair finds a damaged active receipt and an intact retained ownership record whose app, profile, service, root, and identity facts agree
- **THEN** it may restore only verified dedicated Node lifecycle state
- **AND** serving remains disabled until every restart gate passes

#### Scenario: Retained identity is the only evidence

- **WHEN** Node identity exists but the active receipt and retained ownership record are missing or invalid
- **THEN** repair refuses mutation
- **AND** it does not adopt the identity or installation
