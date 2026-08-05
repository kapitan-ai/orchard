## ADDED Requirements

### Requirement: Managed Node Agent Operations Share One Crash-Released Exclusion Boundary

Managed Orchard.app and PKG Node Agent lifecycle operations, managed recovery, and supported Node Agent start eligibility checks governed by `SPEC.md` §11.4 SHALL use one interoperable exclusive kernel advisory lock on `/Library/Application Support/Orchard/support/.app-lifecycle.lock`.
One privileged owner SHALL retain the same kernel lock ownership continuously, without ownership transfer or descriptor inheritance, from before relaunch prevention through exact outgoing-instance exit or proven absence, active activation and protected mutation, the applicable start decision, and terminal-state reporting.
Normal completion SHALL close the owning descriptor, and owner process death SHALL release ownership through the operating system.
Persistent transaction or rendezvous metadata SHALL NOT constitute exclusion ownership, authorize mutation or start, or independently block managed recovery.

#### Scenario: App and PKG operations contend

- **WHEN** an Orchard.app lifecycle operation and a PKG lifecycle operation attempt to enter active Managed Node Agent Handover concurrently
- **THEN** at most one privileged owner acquires the canonical lock
- **AND** the contending operation performs no active managed mutation and starts no Node Agent

#### Scenario: Handover owner dies

- **WHEN** the privileged owner dies while holding the canonical lock
- **THEN** the operating system releases kernel lock ownership
- **AND** any installed state left uncertain by the death remains stopped until a later managed recovery proves coherence

#### Scenario: Persistent recovery metadata survives owner death

- **WHEN** transaction or rendezvous metadata remains after its owner no longer holds the kernel lock
- **THEN** that metadata does not confer exclusion ownership or authorize mutation or start
- **AND** a later managed recovery may acquire the canonical lock and evaluate the metadata

### Requirement: Relaunch Prevention And Exact Exit Precede Active Mutation

A Managed Node Agent Handover SHALL prevent relaunch through verified launchd job-domain control such as successful `bootout` followed by proof that the job is unloaded.
Relaunch prevention SHALL NOT edit or delete the protected launchd plist before the proof gate.
While retaining the shared exclusion boundary, the owner SHALL establish either that the exact identified outgoing Node Agent process instance exited after managed shutdown or that no managed Node Agent instance is running before active payload activation or mutation of the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
Only proven exit or proven absence SHALL satisfy the gate, and process evidence SHALL distinguish the captured outgoing instance from a later or unrelated process rather than rely only on a reusable PID or service label.

#### Scenario: Managed replacement reaches the mutation gate

- **WHEN** the owner verifies launchd relaunch prevention, identifies the outgoing process instance, and proves that exact instance exited within the bound
- **THEN** the owner may activate or mutate protected lifecycle state
- **AND** it does so only while retaining the same canonical lock ownership

#### Scenario: No managed Node Agent instance is running

- **WHEN** the owner verifies launchd relaunch prevention and affirmatively proves that no managed Node Agent instance is running
- **THEN** the proof gate is satisfied without an outgoing instance
- **AND** the owner may proceed to active activation or mutation while retaining the canonical lock

#### Scenario: Relaunch prevention does not mutate the plist

- **WHEN** the owner prevents relaunch before proving exit or absence
- **THEN** it controls and verifies the launchd job domain without editing or deleting the protected launchd plist

### Requirement: Exit Waiting And Pre-Mutation Failure Are Bounded And Fail-Closed

The wait for exact outgoing-process exit or managed-process absence SHALL be bounded.
Failure to acquire or retain exclusion, prevent relaunch, identify exact process state, prove exact exit, or prove absence within the bound SHALL fail closed without active mutation or Node Agent start.
An established relaunch-prevention state SHALL NOT be deliberately reversed merely to restore automatic launch behavior after such failure.

#### Scenario: Outgoing process does not exit within the bound

- **WHEN** the exact outgoing Node Agent process instance has not been proven exited before the bounded wait expires
- **THEN** the lifecycle returns failure without activating or mutating protected lifecycle state
- **AND** it does not start a Node Agent

#### Scenario: Absence cannot be proven

- **WHEN** the owner can neither identify an outgoing process instance nor prove that no managed Node Agent instance is running
- **THEN** it returns failure without active mutation or Node Agent start

#### Scenario: Lock ownership cannot be retained

- **WHEN** the owner cannot prove that it retains the canonical kernel lock before terminal reporting
- **THEN** the operation fails closed and does not use persistent metadata as substitute ownership

### Requirement: Path-Specific Start Policies Follow Coherent Handover

A Node Agent start SHALL occur only after the proof gate succeeds and coherent installed state is established.
After coherent Orchard.app success, the app MAY restore prior loaded-service state for services still selected by the resulting role.
PKG SHALL leave role-selected services stopped after every fresh install and upgrade and SHALL NOT restore prior loaded-service state.
The supported later PKG start path SHALL be `orchardctl start`, which SHALL verify coherent installed state and handover eligibility under the shared exclusion boundary before starting the Node Agent.

#### Scenario: Orchard.app updates a previously loaded Node Agent

- **WHEN** Orchard.app completes a coherent update after proving exact exit or absence
- **THEN** it may restore the previously loaded Node Agent only if the resulting role still selects that service

#### Scenario: PKG upgrades a previously loaded Node Agent

- **WHEN** PKG completes a coherent upgrade after proving exact exit or absence
- **THEN** the Node Agent remains stopped regardless of its prior loaded state
- **AND** the operator must later use `orchardctl start`

#### Scenario: Later PKG start finds unresolved state

- **WHEN** `orchardctl start` cannot verify coherent installed state or satisfied handover eligibility under the shared exclusion boundary
- **THEN** it does not start the Node Agent and directs the operator to managed recovery

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
Managed recovery MAY reauthorize start only after proving exact outgoing-instance exit or managed-process absence and verifying or restoring coherent installed state.
After recovery, Orchard.app SHALL apply its prior-loaded-state policy and PKG SHALL retain its manual `orchardctl start` policy.
Blind or manual same-root launch while uncertainty remains SHALL be unsupported.

#### Scenario: Managed recovery reconciles an interrupted handover

- **WHEN** a later managed lifecycle acquires the canonical lock after an interrupted handover
- **THEN** it proves exit or absence and verifies or restores coherent installed state before reauthorizing any start

#### Scenario: Operator attempts blind same-root start during uncertainty

- **WHEN** unresolved handover uncertainty remains and an operator attempts direct binary launch or blind `launchctl` kickstart
- **THEN** Orchard does not treat that action as supported recovery or include it in the zero-overlap guarantee

### Requirement: Guarantee Scope And Peer Grant Store Lock Remain Narrow

The zero-overlap guarantee SHALL cover managed Orchard.app, PKG, managed recovery, and supported Node Agent start eligibility paths using the shared exclusion boundary.
Direct or manual Node Agent launches that bypass those paths SHALL remain unsupported and outside the guarantee.
The BEAM Peer Grant Store Lock SHALL remain scoped to one `Orchard.Node.BeamPeerGrantStore` install or load operation, including atomic publication when installing, and SHALL NOT become lifecycle exclusion or a Node Identity Root Lease.

#### Scenario: Peer Grant store operation completes

- **WHEN** one BEAM Peer Grant install or load operation finishes
- **THEN** its Store Lock scope ends without establishing Node Agent process-lifetime or lifecycle ownership

### Requirement: Historical Compatibility Uses Managed Shutdown

Controller `N` support for Node Agent versions `N` and `N-1` under `SPEC.md` §13.1 and §13.4 SHALL be made safe on each managed node through proven shutdown and serialized activation or replacement, not simultaneous use of one Node Identity Root.

#### Scenario: Managed node advances from a supported historical agent

- **WHEN** a managed upgrade replaces a supported `N-1` Node Agent with the bundled replacement
- **THEN** the historical process is proven exited before replacement activation or start
- **AND** the two versions do not overlap on the Node Identity Root
