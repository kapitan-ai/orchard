## ADDED Requirements

### Requirement: App Node Agent Lifecycle Uses Managed Handover

Every managed Orchard.app lifecycle operation that hands over or mutates the Node Agent SHALL use the shared Managed Node Agent Handover required by `SPEC.md` §11.4.
One app-owned privileged owner SHALL retain the canonical kernel advisory lock continuously from initial evidence and durable suppression through immediate pre-`bootout` observation, every captured-instance exit or affirmative absence, protected mutation, the app start decision, and terminal reporting.
Before changing start eligibility or any other protected active state, the app SHALL durably record the required operation identity and phase, prior active path and start policy as needed, and intended mutation, and SHALL then establish durable start suppression.
Under that suppression and immediately before `bootout`, the app SHALL capture stable non-reusable evidence for exactly one running outgoing instance and durably add it to the operation record, or affirmatively prove that no managed instance exists.
An additional, replacement, or identity-unstable managed process SHALL fail the gate.
The app SHALL prevent relaunch through verified launchd job-domain control without first editing or deleting the protected plist and SHALL prove every captured-instance exit after `bootout`.
The wait SHALL be bounded, and failed final observation, unproven captured-instance exit, unproven absence, missing required evidence, or exclusion loss SHALL fail closed without protected mutation or Node Agent start.

#### Scenario: App update replaces a running Node Agent

- **WHEN** an app-owned update manages a running Node Agent
- **THEN** the same app-owned owner establishes suppression, captures stable exact process-instance evidence immediately before verified `bootout`, and proves every captured instance exited before changing protected lifecycle state
- **AND** after verifying coherent handover state it may restore the previously loaded Node Agent only through a distinct managed start attempt and only if the resulting role still selects that service

#### Scenario: App operation contends with another managed owner

- **WHEN** another managed path owns the canonical lifecycle lock
- **THEN** the app operation performs no protected mutation and starts no Node Agent

### Requirement: App Managed Recovery Uses The Same Boundary

An interrupted or uncertain app-owned handover SHALL be recovered only by rerunning the applicable app lifecycle under the shared exclusion boundary.
Missing, incomplete, or uncertain recovery evidence SHALL keep start eligibility suppressed but SHALL NOT prevent a recovery owner from acquiring the canonical kernel lock.
Recovery SHALL record or reconcile initial evidence, establish suppression before final process observation or protected reconciliation, prove every captured outgoing-instance exit or affirmative absence under suppression immediately before `bootout`, verify or restore coherent app-owned state, and mark handover or recovery evidence terminal coherent before permitting a later managed start.

#### Scenario: App recovers an interrupted transaction

- **WHEN** a later app lifecycle acquires the canonical lock and finds app transaction metadata from an interrupted owner
- **THEN** it treats the metadata as recovery input rather than exclusion ownership
- **AND** it records or reconciles initial evidence, establishes durable suppression before final observation, proves every captured-instance exit or affirmative absence under suppression immediately before `bootout`, and verifies coherent state before any distinct managed start attempt restores prior loaded state

## MODIFIED Requirements

### Requirement: Lifecycle Updates Are Transactional

App-owned install and update SHALL preflight before stopping services.
After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app SHALL attempt complete rollback of the prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
The app SHALL report whether rollback completed successfully.
If rollback cannot be completed or verified, the app lifecycle SHALL classify the installed state as uncertain, keep the protected Node Agent start eligibility suppressed across reboot and launchd retries, fail closed for the affected lifecycle role, and SHALL NOT start the Node Agent.
After successful rollback, any prior-loaded-state restoration SHALL use a distinct start-attempt evidence record, operation-bound one-shot authorization, explicit bootstrap, intended-instance verification, and atomic terminal coherent and enabled transition under the same canonical lock.
Failure or owner death before that atomic transition SHALL keep or restore suppression and prevent a provisional Node Agent from continuing.

#### Scenario: Update fails after mutation begins and rollback succeeds

- **WHEN** an app-owned update fails after one or more app-owned paths or launchd records changed
- **THEN** Orchard attempts full rollback unconditionally
- **AND** when rollback completes and is verified, Orchard restores the complete prior app-owned state including loaded-service state and reports successful rollback

#### Scenario: Required rollback fails or cannot be verified

- **WHEN** an app-owned lifecycle cannot complete or verify required rollback
- **THEN** the operation reports rollback failure and classifies the installed state as uncertain
- **AND** when the affected lifecycle includes the Node Agent, the operation leaves it stopped
