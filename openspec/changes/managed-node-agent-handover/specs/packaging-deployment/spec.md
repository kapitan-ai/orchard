## ADDED Requirements

### Requirement: PKG Node Agent Lifecycle Uses Managed Handover

Every PKG lifecycle operation that hands over or mutates the Node Agent SHALL use the shared Managed Node Agent Handover required by `SPEC.md` §11.4.
The PKG lifecycle SHALL hold the shared Orchard.app/PKG exclusion boundary, prevent relaunch, and prove the exact outgoing Node Agent process instance exited before mutating the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root and before starting a replacement.
The wait SHALL be bounded, and unproven exit SHALL fail closed without mutation or replacement start.

#### Scenario: PKG upgrade replaces a running Node Agent

- **WHEN** a supported PKG upgrade manages a running Node Agent
- **THEN** the upgrade proves the exact outgoing instance exited before changing any protected lifecycle state and starts the replacement only after the required mutation completes

### Requirement: PKG Failure Semantics Do Not Claim Transactional Rollback

PKG SHALL honor the shared exclusion, exact-exit, zero-overlap, and uncertain-state fail-closed requirements without claiming transactional rollback.
If mutation or restoration state is uncertain, PKG SHALL NOT automatically restart the Node Agent.

#### Scenario: PKG post-mutation state is uncertain

- **WHEN** a PKG lifecycle operation cannot establish a safe mutated or restored state
- **THEN** the operation fails without automatically restarting the Node Agent and without claiming that the prior installation was transactionally restored
