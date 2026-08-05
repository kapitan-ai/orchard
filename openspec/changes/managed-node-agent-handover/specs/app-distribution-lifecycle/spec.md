## ADDED Requirements

### Requirement: App Node Agent Lifecycle Uses Managed Handover

Every managed Orchard.app lifecycle operation that hands over or mutates the Node Agent SHALL use the shared Managed Node Agent Handover required by `SPEC.md` §11.4.
One app-owned privileged owner SHALL retain the canonical kernel advisory lock continuously through verified launchd relaunch prevention, exact outgoing-instance exit or proven absence, protected mutation, the app start decision, and terminal reporting.
The app SHALL prevent relaunch through verified launchd job-domain control without first editing or deleting the protected plist.
The wait SHALL be bounded, and unproven exit, unproven absence, or exclusion loss SHALL fail closed without protected mutation or Node Agent start.

#### Scenario: App update replaces a running Node Agent

- **WHEN** an app-owned update manages a running Node Agent
- **THEN** the same app-owned owner proves the exact outgoing instance exited before changing protected lifecycle state
- **AND** after coherent success it may restore the previously loaded Node Agent only if the resulting role still selects that service

#### Scenario: App operation contends with another managed owner

- **WHEN** another managed path owns the canonical lifecycle lock
- **THEN** the app operation performs no protected mutation and starts no Node Agent

### Requirement: App Managed Recovery Uses The Same Boundary

An interrupted or uncertain app-owned handover SHALL be recovered only by rerunning the applicable app lifecycle under the shared exclusion boundary.
Recovery MAY reauthorize a Node Agent start only after proving exact outgoing-instance exit or managed-process absence and verifying or restoring coherent app-owned state.

#### Scenario: App recovers an interrupted transaction

- **WHEN** a later app lifecycle acquires the canonical lock and finds app transaction metadata from an interrupted owner
- **THEN** it treats the metadata as recovery input rather than exclusion ownership
- **AND** it proves process absence and coherent state before applying prior-loaded-state restoration

## MODIFIED Requirements

### Requirement: Lifecycle Updates Are Transactional

App-owned install and update SHALL preflight before stopping services.
After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app SHALL attempt complete rollback of the prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
The app SHALL report whether rollback completed successfully.
If rollback cannot be completed or verified, the app lifecycle SHALL classify the installed state as uncertain, fail closed for the affected lifecycle role, and SHALL NOT start the Node Agent.

#### Scenario: Update fails after mutation begins and rollback succeeds

- **WHEN** an app-owned update fails after one or more app-owned paths or launchd records changed
- **THEN** Orchard attempts full rollback unconditionally
- **AND** when rollback completes and is verified, Orchard restores the complete prior app-owned state including loaded-service state and reports successful rollback

#### Scenario: Required rollback fails or cannot be verified

- **WHEN** an app-owned lifecycle cannot complete or verify required rollback
- **THEN** the operation reports rollback failure and classifies the installed state as uncertain
- **AND** when the affected lifecycle includes the Node Agent, the operation leaves it stopped
