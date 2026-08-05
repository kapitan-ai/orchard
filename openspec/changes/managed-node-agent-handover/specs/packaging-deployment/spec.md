## ADDED Requirements

### Requirement: PKG Uses Inactive Staging Before Managed Activation

Every PKG lifecycle operation that hands over or mutates the Node Agent SHALL use stage-then-activate under the shared Managed Node Agent Handover required by `SPEC.md` §11.4.
Apple Installer SHALL place signed payload only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute.
PKG `preinstall` SHALL NOT stop the active Node Agent, prevent relaunch, or mutate active payload, launchd records, command links, role state, or the Node Identity Root.
After staging, PKG `postinstall` SHALL synchronously invoke one privileged owner that acquires the canonical kernel advisory lock and retains the same ownership continuously through the complete active handover and terminal reporting.
Direct `/usr/sbin/installer -pkg ... -target /` SHALL enter this package-owned handover path without requiring an external Orchard wrapper.

#### Scenario: Direct installer stages and activates an upgrade

- **WHEN** an operator invokes `/usr/sbin/installer` directly for a supported PKG upgrade
- **THEN** Apple Installer stages signed payload only in the inactive incoming root while the active Node Agent installation remains untouched
- **AND** `postinstall` invokes one privileged owner for the complete active handover

#### Scenario: Installer stops before postinstall

- **WHEN** Apple Installer aborts after inert staging but before `postinstall` invokes the handover owner
- **THEN** no active Node Agent lifecycle state has been mutated by the staged payload
- **AND** no external wrapper or durable metadata is treated as exclusion ownership

### Requirement: PKG Active Handover Uses One Continuously Owned Boundary

The PKG handover owner SHALL retain the canonical lock without transfer or descriptor inheritance from before verified launchd relaunch prevention through exact outgoing-instance exit or proven absence, staged payload activation, protected lifecycle mutation, the PKG no-start decision, and terminal reporting.
Only after verified job-domain relaunch prevention and exact exit or proven absence SHALL the owner activate staged payload or mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
The wait SHALL be bounded, and an unproven exit, unproven absence, exclusion loss, or activation uncertainty SHALL fail closed without Node Agent start.

#### Scenario: PKG upgrade replaces a running Node Agent

- **WHEN** `postinstall` invokes the owner for a running Node Agent
- **THEN** the same owner verifies launchd `bootout`, proves the exact outgoing instance exited, and only then activates staged content
- **AND** it retains the canonical lock through terminal reporting

#### Scenario: PKG owner dies during activation

- **WHEN** the privileged owner dies after relaunch prevention or active mutation begins
- **THEN** the operating system releases kernel lock ownership
- **AND** the Node Agent remains stopped until managed PKG recovery proves coherent installed state

### Requirement: PKG Preserves Manual Start After Every Install

PKG SHALL leave all role-selected services stopped after every successful fresh install and upgrade.
PKG SHALL NOT automatically start services and SHALL NOT restore prior loaded-service state.
The supported later start path SHALL be `orchardctl start`.
Before starting the Node Agent, `orchardctl start` SHALL use the shared exclusion boundary to verify coherent installed state and satisfied handover eligibility.

#### Scenario: Fresh PKG install succeeds

- **WHEN** a fresh PKG install completes successfully
- **THEN** role-selected services remain stopped until the operator runs `orchardctl start`

#### Scenario: Running-service PKG upgrade succeeds

- **WHEN** a PKG upgrade began with the Node Agent loaded and completes coherently
- **THEN** the replacement remains stopped and prior loaded state is not restored
- **AND** the operator must later run `orchardctl start`

#### Scenario: Later start finds unresolved handover state

- **WHEN** `orchardctl start` cannot verify coherent installed state or handover eligibility
- **THEN** it does not start the Node Agent and directs the operator to rerun managed PKG recovery

### Requirement: PKG Failure And Recovery Do Not Claim Transactional Rollback

PKG SHALL honor the shared exclusion, exact-exit, zero-overlap, and uncertain-state fail-closed requirements without claiming transactional rollback.
Managed PKG recovery SHALL rerun the applicable package lifecycle under the same shared exclusion boundary and MAY reauthorize later `orchardctl start` only after proving exact outgoing-instance exit or managed-process absence and verifying or restoring coherent installed state.
Persistent transaction or rendezvous metadata MAY support recovery but SHALL NOT constitute exclusion ownership or independently block recovery.

#### Scenario: PKG activation state is uncertain

- **WHEN** a PKG lifecycle operation cannot establish whether active activation or protected mutation reached a coherent state
- **THEN** the operation fails without starting the Node Agent and without claiming that the prior installation was transactionally restored

#### Scenario: Operator reruns PKG after uncertain failure

- **WHEN** the operator reruns the applicable PKG lifecycle after a failed or interrupted handover
- **THEN** the new privileged owner acquires the canonical lock and reconciles process and installed state before later start eligibility is restored
- **AND** successful recovery still leaves services stopped until `orchardctl start`
