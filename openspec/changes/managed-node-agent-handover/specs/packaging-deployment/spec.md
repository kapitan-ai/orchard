## ADDED Requirements

### Requirement: PKG Uses Inactive Staging Before Managed Activation

Every PKG lifecycle operation that hands over or mutates the Node Agent SHALL use stage-then-activate under the shared Managed Node Agent Handover required by `SPEC.md` §11.4.
Apple Installer SHALL place authenticated and signed payload only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute.
Before relaunch prevention or active mutation, the handover owner SHALL bind activation to exactly one complete staging generation in a unique per-generation namespace and verify its identity, completeness, integrity, trust, and intended installation target.
The bound generation SHALL remain immutable or equivalently identity-stable against concurrent or repeated installers through atomic activation.
Immediately before atomic activation, the owner SHALL revalidate the bound pathname or descriptor identity, manifest, signature, complete file set, content integrity, trust, and target.
Initial discovery of partial, stale, mixed-generation, untrusted, ambiguous, replaced, modified, or missing staged content SHALL fail before any protected active Node Agent lifecycle mutation.
Any mismatch detected by immediate pre-activation revalidation SHALL fail before payload or installed-state activation and SHALL leave start eligibility suppressed for managed recovery.
PKG `preinstall` SHALL NOT stop the active Node Agent, prevent relaunch, or mutate active payload, launchd records, command links, role state, or the Node Identity Root.
After staging, PKG `postinstall` SHALL synchronously invoke one privileged owner that acquires the canonical kernel advisory lock and retains the same ownership continuously through the complete active handover and terminal reporting.
Direct `/usr/sbin/installer -pkg ... -target /` SHALL enter this package-owned handover path without requiring an external Orchard wrapper.

#### Scenario: Direct installer stages and activates an upgrade

- **WHEN** an operator invokes `/usr/sbin/installer` directly for a supported PKG upgrade
- **THEN** Apple Installer stages authenticated and signed payload only in the inactive incoming root while the active Node Agent installation remains untouched
- **AND** `postinstall` invokes one privileged owner that validates and binds exactly one complete generation in a unique immutable or equivalently identity-stable namespace for the active handover

#### Scenario: Installer stops before postinstall

- **WHEN** Apple Installer aborts after inert staging but before `postinstall` invokes the handover owner
- **THEN** no active Node Agent lifecycle state has been mutated by the staged payload
- **AND** no external wrapper or durable metadata is treated as exclusion ownership

#### Scenario: Staging generation is not uniquely valid

- **WHEN** staged content is partial, stale, mixed across generations, untrusted, ambiguous, replaced, modified, or missing at initial validation or immediate pre-activation revalidation
- **THEN** initial invalidity fails before protected active lifecycle mutation, while a later revalidation mismatch fails before payload or installed-state activation and leaves start suppressed
- **AND** no invalid staged content becomes active or alters the bound generation

#### Scenario: Repeated installer races a bound generation

- **WHEN** a concurrent or repeated installer attempts to replace, modify, mix, or remove content after one owner binds a generation
- **THEN** the unique immutable or equivalently identity-stable generation prevents the change or immediate pre-activation revalidation detects it
- **AND** the owner does not activate changed content or mutate active payload state

### Requirement: PKG Active Handover Uses One Continuously Owned Boundary

The PKG handover owner SHALL retain the canonical lock without transfer or descriptor inheritance from initial operation evidence and durable suppression through immediate pre-`bootout` observation, every captured-instance exit or affirmative absence, bound staging-generation activation, protected lifecycle mutation, the PKG no-start decision, and terminal reporting.
Before changing start eligibility or any other protected active state, the owner SHALL durably record the operation identity and phase, bound staging generation, prior active path and start policy as needed, and intended mutation, and SHALL then establish durable start suppression.
Under that suppression and immediately before `bootout`, the owner SHALL capture non-reusable evidence for exactly one stable running outgoing instance and durably add it to the operation record, or affirmatively prove no managed instance exists.
An additional, replacement, or identity-unstable managed process SHALL fail the gate.
The owner SHALL perform verified job-domain relaunch prevention and, when an outgoing instance was captured, wait for proof that every captured instance exited after `bootout`.
Immediately before atomic activation, the owner SHALL fully revalidate the immutable or equivalently identity-stable bound generation.
Only after every captured-instance exit or affirmative absence under suppression immediately before `bootout` and successful generation revalidation SHALL the owner activate the bound staging generation or mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
The wait SHALL be bounded, and failed final observation, unproven captured-instance exit, unproven absence, exclusion loss, generation identity change, or activation uncertainty SHALL fail closed without Node Agent start.

#### Scenario: PKG upgrade replaces a running Node Agent

- **WHEN** `postinstall` invokes the owner for a running Node Agent
- **THEN** the same owner establishes suppression, captures stable non-reusable exact process-instance evidence immediately before verified launchd `bootout`, proves every captured instance exited, revalidates the bound generation, and only then activates it
- **AND** it retains the canonical lock through terminal reporting

#### Scenario: PKG owner dies during activation

- **WHEN** the privileged owner dies after relaunch prevention or active mutation begins
- **THEN** the operating system releases kernel lock ownership
- **AND** durable start suppression survives owner death and reboot until managed PKG recovery proves coherent installed state and marks required evidence terminal coherent

### Requirement: PKG Preserves Manual Start After Every Install

PKG SHALL leave all role-selected services stopped and protected start eligibility suppressed after every successful fresh install and upgrade.
PKG SHALL NOT automatically start services and SHALL NOT restore prior loaded-service state.
Suppression SHALL survive owner death, reboot, launchd job-domain reload, and `KeepAlive` retry, and publishing or loading a `RunAtLoad` and `KeepAlive` plist SHALL NOT authorize launch.
The supported later start path SHALL be `orchardctl start`.
Before starting the Node Agent, `orchardctl start` SHALL acquire the canonical lock, verify prior terminal coherent PKG handover or recovery evidence and coherent installed state, record distinct non-terminal start-attempt evidence, and verify the launchd job remains unloaded.
It SHALL create operation-bound one-shot authorization valid only for the current start identity, current lock owner, and one explicit bootstrap, then bootstrap and verify the intended Node Agent instance.
Only after verification SHALL it atomically mark the start attempt terminal coherent and enable durable eligibility for normal `RunAtLoad` and `KeepAlive` operation.
Failure or owner death before that transition SHALL invalidate authorization, keep or restore suppression, and prevent a provisional Node Agent from continuing.

#### Scenario: Fresh PKG install succeeds

- **WHEN** a fresh PKG install completes successfully and publishes the `RunAtLoad` and `KeepAlive` plist
- **THEN** role-selected services remain stopped and the Node Agent remains start-suppressed until the operator runs `orchardctl start`
- **AND** reboot, launchd domain reload, or `KeepAlive` retry does not bypass suppression

#### Scenario: Running-service PKG upgrade succeeds

- **WHEN** a PKG upgrade began with the Node Agent loaded and completes coherently
- **THEN** the replacement remains stopped and prior loaded state is not restored
- **AND** the operator must later run `orchardctl start`

#### Scenario: Later start finds unresolved handover state

- **WHEN** `orchardctl start` finds missing, incomplete, uncertain, or non-terminal prior handover or recovery evidence or cannot verify coherent installed state
- **THEN** it leaves start eligibility suppressed, does not create one-shot authorization or bootstrap the Node Agent, and directs the operator to rerun managed PKG recovery

### Requirement: PKG Failure And Recovery Do Not Claim Transactional Rollback

PKG SHALL honor the shared exclusion, exact-exit, zero-overlap, and uncertain-state fail-closed requirements without claiming transactional rollback.
Managed PKG recovery SHALL rerun the applicable package lifecycle under the same shared exclusion boundary, record or reconcile initial evidence, establish suppression before final process observation or protected reconciliation, prove every captured outgoing-instance exit or affirmative absence under suppression immediately before `bootout`, verify or restore coherent installed state, and mark handover or recovery evidence terminal coherent before permitting later `orchardctl start`.
Missing, incomplete, or uncertain required recovery evidence SHALL deny start but SHALL NOT constitute exclusion ownership or prevent a recovery owner from acquiring the canonical lock.

#### Scenario: PKG activation state is uncertain

- **WHEN** a PKG lifecycle operation cannot establish whether active activation or protected mutation reached a coherent state
- **THEN** the operation fails without starting the Node Agent and without claiming that the prior installation was transactionally restored

#### Scenario: Operator reruns PKG after uncertain failure

- **WHEN** the operator reruns the applicable PKG lifecycle after a failed or interrupted handover
- **THEN** the new privileged owner acquires the canonical lock, records or reconciles evidence, establishes suppression before final process observation, and reconciles process and installed state before permitting a distinct later managed start attempt
- **AND** successful recovery still leaves services stopped until `orchardctl start`
