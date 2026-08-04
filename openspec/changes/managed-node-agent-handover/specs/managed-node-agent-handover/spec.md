## ADDED Requirements

### Requirement: Managed Node Agent Operations Share One Exclusion Boundary

Managed Orchard.app and PKG Node Agent lifecycle operations governed by `SPEC.md` §11.4 SHALL use one shared lifecycle exclusion boundary for the complete Managed Node Agent Handover.
The boundary SHALL exclude the other managed path through outgoing-process exit proof, required managed mutation, and the replacement-start decision.
Failure to acquire or retain the boundary SHALL fail closed without managed mutation or replacement start.

#### Scenario: App and PKG operations contend

- **WHEN** an Orchard.app lifecycle operation and a PKG lifecycle operation attempt to hand over the managed Node Agent concurrently
- **THEN** at most one operation enters the handover and the other performs no managed mutation and does not start a replacement Node Agent

### Requirement: Exact Outgoing Process Exit Precedes Mutation And Replacement

A Managed Node Agent Handover SHALL prevent launchd relaunch, identify the exact outgoing Node Agent process instance, request managed shutdown, and prove that identified instance exited before mutating the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
The replacement Node Agent SHALL start only after that exit proof succeeds and the required managed mutation completes.
Process exit evidence SHALL distinguish the identified outgoing instance from a later or unrelated process rather than relying only on a reusable numeric process identifier or service label.

#### Scenario: Managed replacement succeeds

- **WHEN** the lifecycle prevents relaunch, identifies the outgoing process instance, and proves that exact instance exited within the bound
- **THEN** the lifecycle may perform the required managed mutation and start the replacement only after mutation completes

#### Scenario: Exit proof is not exact

- **WHEN** the lifecycle can observe only a reusable process identifier or service label and cannot prove that the exact captured outgoing instance exited
- **THEN** it performs no listed mutation and does not start a replacement Node Agent

### Requirement: Exit Waiting Is Bounded And Fail-Closed

The wait for exact outgoing-process exit proof SHALL be bounded.
Failure to prevent relaunch, identify the outgoing instance, prove its exit within the bound, or maintain the shared exclusion boundary SHALL fail closed without managed mutation or replacement start.

#### Scenario: Outgoing process does not exit within the bound

- **WHEN** the exact outgoing Node Agent process instance has not been proven exited before the bounded wait expires
- **THEN** the lifecycle returns failure without mutating the payload, plist, command symlink, role marker, or Node Identity Root and without starting a replacement

### Requirement: Uncertain Mutation Or Restoration Does Not Restart Automatically

If managed mutation or restoration state is uncertain, the lifecycle SHALL fail closed and SHALL NOT automatically restart the Node Agent.
Orchard.app SHALL retain its existing restoration obligations when restoration can be established safely; this requirement SHALL NOT create a transactional PKG rollback guarantee.

#### Scenario: Post-mutation state is uncertain

- **WHEN** a managed lifecycle operation cannot establish whether required mutation or restoration reached a safe state
- **THEN** it returns failure and leaves the Node Agent without an automatic managed restart

### Requirement: Guarantee Scope Remains Managed And Narrow

The zero-overlap guarantee SHALL cover managed Orchard.app and PKG lifecycle operations using the shared exclusion boundary.
Direct or manual Node Agent launches using the same Node Identity Root SHALL remain unsupported and outside the guarantee.
BEAM Peer Grant storage locks SHALL remain operation-scoped and SHALL NOT become lifecycle locks or a Node Identity Root Lease.

#### Scenario: Direct same-root process bypasses managed lifecycle

- **WHEN** an operator launches a Node Agent directly against the same Node Identity Root outside Orchard.app or PKG lifecycle management
- **THEN** Orchard does not claim that the Managed Node Agent Handover guarantee coordinates or makes that launch safe

### Requirement: Historical Compatibility Uses Managed Shutdown

Controller `N` support for Node Agent versions `N` and `N-1` under `SPEC.md` §13.1 and §13.4 SHALL be made safe on each managed node through proven shutdown and serialized replacement, not simultaneous use of one Node Identity Root.

#### Scenario: Managed node advances from a supported historical agent

- **WHEN** a managed upgrade replaces a supported `N-1` Node Agent with the bundled replacement
- **THEN** the historical process is proven exited before the replacement starts and the two versions do not overlap on the Node Identity Root
