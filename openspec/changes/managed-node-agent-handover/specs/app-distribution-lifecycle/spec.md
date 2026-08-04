## ADDED Requirements

### Requirement: App Node Agent Lifecycle Uses Managed Handover

Every managed Orchard.app lifecycle operation that hands over or mutates the Node Agent SHALL use the shared Managed Node Agent Handover required by `SPEC.md` §11.4.
The app lifecycle SHALL hold the shared Orchard.app/PKG exclusion boundary, prevent relaunch, and prove the exact outgoing Node Agent process instance exited before mutating the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root and before starting a replacement.
The wait SHALL be bounded, and unproven exit SHALL fail closed without mutation or replacement start.

#### Scenario: App update replaces a running Node Agent

- **WHEN** an app-owned update manages a running Node Agent
- **THEN** the update proves the exact outgoing instance exited before changing any protected lifecycle state and starts the replacement only after the required mutation completes

## MODIFIED Requirements

### Requirement: Lifecycle Updates Are Transactional

App-owned install and update SHALL preflight before stopping services and SHALL restore the prior app-owned payload, links, plists, role marker, and loaded-service state when a commit-phase failure occurs and restoration can be established safely.
If restoration cannot be established safely, the app lifecycle SHALL fail closed and SHALL report failure for the affected lifecycle role.
If Node Agent mutation or restoration state is uncertain, the app lifecycle SHALL NOT automatically restart the Node Agent.

#### Scenario: Update fails after mutation begins

- **WHEN** an app-owned update fails after one or more app-owned paths or launchd records have changed and safe restoration can be established
- **THEN** Orchard restores the complete prior app-owned state and reports whether rollback succeeded

#### Scenario: App restoration outcome is uncertain

- **WHEN** an app-owned lifecycle failure cannot establish a safe restored or mutated state
- **THEN** the operation fails closed and reports failure for the affected lifecycle role
- **AND** when the affected lifecycle includes the Node Agent, the operation does not automatically restart the Node Agent
