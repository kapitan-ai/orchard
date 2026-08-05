## ADDED Requirements

### Requirement: Managed Node Agent Operations Share One Crash-Released Exclusion Boundary

Managed Orchard.app and PKG Node Agent lifecycle operations, managed recovery, and supported Node Agent start eligibility checks governed by `SPEC.md` §11.4 SHALL use one interoperable exclusive kernel advisory lock on `/Library/Application Support/Orchard/support/.app-lifecycle.lock`.
One privileged owner SHALL retain the same kernel lock ownership continuously, without ownership transfer or descriptor inheritance, from before initial operation evidence and durable suppression through immediate pre-`bootout` observation, every captured-instance exit or affirmative absence, active activation and protected mutation, the applicable start decision, and terminal-state reporting.
Normal completion SHALL close the owning descriptor, and owner process death SHALL release ownership through the operating system.
Before changing Managed Node Agent Start Eligibility State or any other protected active state, the owner SHALL durably record required handover or recovery evidence containing the operation identity and phase, the bound staging generation when applicable, prior active path and start policy as needed, and the intended mutation.
A no-start handover or recovery SHALL become terminal coherent only after resulting active installed state is verified, and a later managed start SHALL use a distinct start-attempt identity and evidence record.
Missing, incomplete, or uncertain evidence SHALL deny start but SHALL NOT constitute exclusion ownership, authorize mutation or start, or prevent a managed recovery owner from acquiring the canonical lock.

#### Scenario: App and PKG operations contend

- **WHEN** an Orchard.app lifecycle operation and a PKG lifecycle operation attempt to enter active Managed Node Agent Handover concurrently
- **THEN** at most one privileged owner acquires the canonical lock
- **AND** the contending operation performs no active managed mutation and starts no Node Agent

#### Scenario: Handover owner dies

- **WHEN** the privileged owner dies while holding the canonical lock
- **THEN** the operating system releases kernel lock ownership
- **AND** any installed state left uncertain by the death remains stopped until a later managed recovery proves coherence

#### Scenario: Required recovery evidence survives owner death

- **WHEN** required recovery evidence remains after its owner no longer holds the kernel lock
- **THEN** missing, incomplete, uncertain, or non-terminal evidence denies Node Agent start without conferring exclusion ownership
- **AND** a later managed recovery may acquire the canonical lock and evaluate or reconcile the evidence

#### Scenario: Required evidence brackets protected mutation

- **WHEN** an owner is ready to change start eligibility or another protected active state
- **THEN** durable evidence already identifies the operation, phase, staging generation when applicable, prior active path and start policy as needed, and intended mutation
- **AND** the owner does not mark a no-start handover or recovery terminal coherent until it verifies the resulting active installed state and records the no-start outcome

### Requirement: Relaunch Prevention And Exact Exit Precede Active Mutation

While retaining the shared exclusion boundary, a Managed Node Agent Handover SHALL durably record initial operation evidence and establish protected durable start suppression before final process observation.
Under that suppression and immediately before `bootout`, the owner SHALL either capture non-reusable evidence identifying exactly one running outgoing instance and durably add it to the operation record, or affirmatively prove that no managed instance exists.
The captured identity SHALL remain stable through `bootout`, and an additional, replacement, or identity-unstable managed process SHALL fail the gate.
The handover SHALL then prevent relaunch through verified launchd job-domain control such as successful `bootout` followed by proof that the job is unloaded.
Relaunch prevention SHALL NOT edit or delete the protected launchd plist before the proof gate.
When an outgoing instance was captured, the owner SHALL wait after `bootout` for proof that every captured managed instance exited before active payload activation or mutation of the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
Only every captured-instance exit or affirmative absence proven under suppression immediately before `bootout` SHALL satisfy the gate, and failed observation SHALL NOT be reinterpreted as later absence.

#### Scenario: Managed replacement reaches the mutation gate

- **WHEN** the owner establishes suppression, captures stable non-reusable outgoing process-instance evidence immediately before `bootout`, verifies relaunch prevention, and proves every captured instance exited within the bound
- **THEN** the owner may activate or mutate protected lifecycle state
- **AND** it does so only while retaining the same canonical lock ownership

#### Scenario: No managed Node Agent instance is running

- **WHEN** the owner affirmatively proves under suppression immediately before `bootout` that no managed Node Agent instance is running and then verifies relaunch prevention
- **THEN** the proof gate is satisfied without an outgoing instance
- **AND** the owner may proceed to active activation or mutation while retaining the canonical lock

#### Scenario: Relaunch prevention does not mutate the plist

- **WHEN** the owner has captured exact instance evidence or affirmative absence and then prevents relaunch
- **THEN** it controls and verifies the launchd job domain without editing or deleting the protected launchd plist

#### Scenario: KeepAlive races outgoing exit around suppression

- **WHEN** an outgoing instance exits after initial evidence is recorded but before suppression becomes effective and `KeepAlive` starts a replacement
- **THEN** the owner does not reuse stale process evidence and final observation under durable suppression captures the replacement as the exact outgoing instance
- **AND** if it cannot stably capture exactly one instance or prove absence under suppression immediately before `bootout`, the gate fails closed

### Requirement: Exit Waiting And Pre-Mutation Failure Are Bounded And Fail-Closed

Immediate pre-`bootout` process observation and the post-`bootout` wait for every captured outgoing-process exit SHALL be bounded.
Failure to acquire or retain exclusion, record required evidence, establish durable suppression, observe stable exact process state under suppression immediately before `bootout`, prevent relaunch, prove every captured-instance exit, or prove affirmative absence at that observation SHALL fail closed without active mutation or Node Agent start.
An established relaunch-prevention state SHALL NOT be deliberately reversed merely to restore automatic launch behavior after such failure.

#### Scenario: Outgoing process does not exit within the bound

- **WHEN** the exact outgoing Node Agent process instance has not been proven exited before the bounded wait expires
- **THEN** the lifecycle returns failure without activating or mutating protected lifecycle state
- **AND** it does not start a Node Agent

#### Scenario: Absence cannot be proven

- **WHEN** the owner can neither capture one stable outgoing process instance nor affirmatively prove under suppression immediately before `bootout` that no managed Node Agent instance is running
- **THEN** it returns failure without active mutation or Node Agent start and does not use post-`bootout` non-observation as absence

#### Scenario: Lock ownership cannot be retained

- **WHEN** the owner cannot prove that it retains the canonical kernel lock before terminal reporting
- **THEN** the operation fails closed and does not use persistent metadata as substitute ownership

### Requirement: Protected Start Eligibility Enforces Path-Specific Start Policies

The managed Node Agent launch path SHALL check a protected durable Start Eligibility State before Node Agent execution.
Suppression SHALL survive handover-owner death, reboot, launchd job-domain reload, and `KeepAlive` retry, and publishing or loading a `RunAtLoad` and `KeepAlive` plist SHALL NOT authorize launch.
A Node Agent start SHALL occur only through a managed start attempt after the proof gate succeeds and prior terminal coherent handover or recovery evidence and coherent installed state are verified.
Each managed start attempt SHALL record a distinct non-terminal start identity and evidence record and verify the launchd job remains unloaded before changing eligibility.
The current canonical lock owner SHALL create operation-bound one-shot authorization valid only for that start identity, owner, and one explicit bootstrap, then bootstrap and verify the intended Node Agent instance from coherent active state.
Only after verification SHALL the owner atomically mark the start attempt terminal coherent and enable durable eligibility for normal `RunAtLoad` and `KeepAlive` operation.
Failure or owner death before that atomic transition SHALL invalidate authorization, keep or restore suppression, and prevent a provisional Node Agent from continuing.
After coherent Orchard.app success or successful required rollback, the app MAY restore prior loaded-service state for services still selected by the resulting role only through this protocol.
PKG SHALL leave role-selected services stopped and start-suppressed after every fresh install and upgrade and SHALL NOT restore prior loaded-service state.
The supported later PKG start path SHALL be `orchardctl start` using this protocol.

#### Scenario: Orchard.app updates a previously loaded Node Agent

- **WHEN** Orchard.app completes a coherent update after proving every captured-instance exit or affirmative absence under suppression immediately before `bootout`
- **THEN** it may restore the previously loaded Node Agent only through a distinct managed start attempt and only if the resulting role still selects that service

#### Scenario: PKG upgrades a previously loaded Node Agent

- **WHEN** PKG completes a coherent upgrade after proving every captured-instance exit or affirmative absence under suppression immediately before `bootout`
- **THEN** the Node Agent remains stopped regardless of its prior loaded state
- **AND** the operator must later use `orchardctl start`

#### Scenario: Later PKG start finds unresolved state

- **WHEN** `orchardctl start` finds missing, incomplete, uncertain, or non-terminal evidence or cannot verify coherent installed state under the shared exclusion boundary
- **THEN** it leaves start eligibility suppressed, does not bootstrap the Node Agent, and directs the operator to managed recovery

#### Scenario: Suppressed service encounters launchd restart stimuli

- **WHEN** the Node Agent is suppressed and the owner dies, the host reboots, launchd reloads the job domain, or `KeepAlive` retries the job
- **THEN** the managed launch path denies Node Agent execution
- **AND** plist publication or loading does not change eligibility

#### Scenario: Eligible later PKG start is deliberate

- **WHEN** `orchardctl start` acquires the canonical lock and verifies prior terminal coherent evidence, coherent installed state, and an unloaded job
- **THEN** it records distinct non-terminal start-attempt evidence, creates one operation-bound authorization, bootstraps and verifies the intended instance, and only then atomically records terminal coherent start evidence with durable enabled eligibility
- **AND** it retains the canonical lock through terminal reporting

#### Scenario: Start owner dies after one-shot authorization

- **WHEN** the start owner dies after creating one-shot authorization but before the atomic terminal coherent and enabled transition
- **THEN** the authorization becomes invalid, durable eligibility remains or returns suppressed, and any provisional Node Agent cannot continue
- **AND** reboot, job-domain reload, or `KeepAlive` retry cannot consume the interrupted authorization

### Requirement: App Rollback Is Mandatory And Uncertain State Remains Stopped

After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app SHALL attempt complete rollback of the prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
The app SHALL report whether required rollback completed successfully.
If rollback cannot be completed or verified, the state SHALL be classified as uncertain and the Node Agent SHALL remain stopped.
PKG SHALL honor the same uncertain-state fail-closed rule without gaining a transactional rollback guarantee.

#### Scenario: Required app rollback succeeds

- **WHEN** Orchard.app encounters a failure after mutation begins and completes and verifies full rollback
- **THEN** it restores the prior app-owned state including prior loaded-service state
- **AND** it reports the original failure and successful rollback outcome

#### Scenario: Required app rollback cannot be verified

- **WHEN** Orchard.app cannot complete or verify required rollback
- **THEN** it classifies the installed state as uncertain, reports rollback failure, and does not start the Node Agent

#### Scenario: PKG activation state is uncertain

- **WHEN** PKG cannot establish whether active activation or protected mutation reached a coherent state
- **THEN** it returns failure and leaves the Node Agent stopped without claiming transactional restoration

### Requirement: Managed Recovery Reestablishes Start Eligibility

Recovery after timeout, owner death, or uncertain state SHALL rerun the applicable Orchard.app or PKG managed lifecycle under the same shared exclusion boundary.
Missing, incomplete, or uncertain evidence SHALL keep start eligibility suppressed but SHALL NOT prevent a managed recovery owner from acquiring the canonical lock.
Managed recovery SHALL record or reconcile initial evidence, establish durable suppression before final process observation or protected reconciliation, prove every captured outgoing-instance exit or affirmative absence under suppression immediately before `bootout`, verify or restore coherent installed state, and mark the handover or recovery evidence terminal coherent before permitting a later managed start.
After recovery, Orchard.app SHALL apply its managed start-attempt restoration policy and PKG SHALL retain its manual `orchardctl start` policy.
Blind or manual same-root launch while uncertainty remains SHALL be unsupported.

#### Scenario: Managed recovery reconciles an interrupted handover

- **WHEN** a later managed lifecycle acquires the canonical lock after an interrupted handover
- **THEN** it records or reconciles initial evidence, establishes durable suppression before final observation, proves every captured-instance exit or affirmative absence under suppression immediately before `bootout`, verifies or restores coherent installed state, and marks handover or recovery evidence terminal coherent before permitting a later managed start

#### Scenario: Operator attempts blind same-root start during uncertainty

- **WHEN** unresolved handover uncertainty remains and an operator attempts direct binary launch or blind `launchctl` kickstart
- **THEN** Orchard does not treat that action as supported recovery or include it in the zero-overlap guarantee

### Requirement: Guarantee Scope And Peer Grant Store Lock Remain Narrow

The zero-overlap guarantee SHALL cover managed Orchard.app, PKG, managed recovery, and supported Node Agent start eligibility paths using the shared exclusion boundary.
Direct or manual Node Agent launches that bypass the protected managed launch and start-eligibility paths SHALL remain unsupported and outside the guarantee.
The BEAM Peer Grant Store Lock SHALL remain scoped to one `Orchard.Node.BeamPeerGrantStore` install or load operation, including atomic publication when installing, and SHALL NOT become lifecycle exclusion or a Node Identity Root Lease.

#### Scenario: Peer Grant store operation completes

- **WHEN** one BEAM Peer Grant install or load operation finishes
- **THEN** its Store Lock scope ends without establishing Node Agent process-lifetime or lifecycle ownership

### Requirement: Historical Compatibility Uses Managed Shutdown

Controller `N` support for Node Agent versions `N` and `N-1` under `SPEC.md` §13.1 and §13.4 SHALL be made safe on each managed node through proven shutdown and serialized activation or replacement, not simultaneous use of one Node Identity Root.

#### Scenario: Managed node advances from a supported historical agent

- **WHEN** a managed upgrade replaces a supported `N-1` Node Agent with the bundled replacement
- **THEN** durable suppression precedes stable non-reusable capture of the historical process immediately before `bootout`, and every captured instance is proven exited before replacement activation or start
- **AND** the two versions do not overlap on the Node Identity Root
