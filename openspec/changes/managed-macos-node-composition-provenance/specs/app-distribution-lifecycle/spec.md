## ADDED Requirements

### Requirement: Managed Composition Activation Requires Verified Preconditions

Before mutating live host state, the app lifecycle SHALL require admitted incoming and rollback compositions, compatible retained identity schema, a fresh Controller maintenance and drain acknowledgement, and an available supported host process fence.
Failure of any precondition SHALL leave the active composition and local service state unchanged.

#### Scenario: Preconditions pass

- **WHEN** incoming and rollback verification, retained-schema compatibility, Controller acknowledgement, and process-fence availability all pass
- **THEN** the lifecycle MAY acquire the host operation lock and begin the managed activation journal

#### Scenario: A precondition is missing or stale

- **WHEN** any required verifier decision, compatibility result, Controller acknowledgement, or process-fence capability is absent, rejected, stale, or ambiguous
- **THEN** the lifecycle SHALL stop before host mutation

### Requirement: Managed Activation Uses a Versioned Durable Journal

The lifecycle SHALL use a managed-composition journal schema that records operation identity, old and new composition-lock digests, rollback target, Node Identity Root identity, Controller acknowledgement, verifier evidence digests, helper protocol version, and monotonic state.
The lifecycle SHALL durably record each state before acknowledging its corresponding external mutation.
Code that does not understand the managed-composition journal schema SHALL refuse recovery and preserve launch suppression.

#### Scenario: Lifecycle resumes a known journal

- **WHEN** the lifecycle reads a valid supported managed-composition journal after interruption
- **THEN** it SHALL re-verify observed host, composition, process, identity, and Controller state before choosing the next allowed transition

#### Scenario: Lifecycle encounters unknown or contradictory journal state

- **WHEN** the journal schema is unsupported, evidence is incomplete, or observed state contradicts the journal
- **THEN** the lifecycle SHALL mark or preserve the operation as uncertain
- **AND** SHALL NOT auto-start a service

### Requirement: Activation and Start Are Separate Phases

The lifecycle SHALL stop and fence the outgoing managed process set before changing active bytes.
After atomic activation and post-activation verification, it SHALL commit `activated_stopped` while durable launch suppression remains active.
Starting the incoming composition SHALL be a separate verified operation.

#### Scenario: Incoming bytes activate successfully

- **WHEN** the outgoing fence is proven and staged incoming bytes pass activation and post-activation verification
- **THEN** the lifecycle SHALL record `activated_stopped`
- **AND** SHALL NOT start the incoming composition as an implicit consequence of byte activation

#### Scenario: Start succeeds locally

- **WHEN** an explicit start launches the admitted composition and the process reports the expected composition, Node identity, compatibility, and local health
- **THEN** the lifecycle SHALL record `started_pending_controller`
- **AND** Controller maintenance SHALL remain until explicit uncordon

### Requirement: Managed Transition Has No Managed-Process Overlap

The lifecycle SHALL require proof that every captured outgoing managed process exited and that no replacement managed process appeared before activating or starting incoming bytes.
The incoming managed process SHALL start only after the outgoing no-process proof is complete.

#### Scenario: Replacement process appears

- **WHEN** a managed process appears after outgoing capture and before explicit incoming start
- **THEN** the lifecycle SHALL fail the transition
- **AND** SHALL keep launch suppression active and the Node stopped

#### Scenario: Transition reaches incoming start

- **WHEN** the lifecycle starts the incoming managed process
- **THEN** its evidence SHALL prove a stopped interval with no process in the supported managed launch domain

### Requirement: Rollback Restores Verified Bytes Without Automatic Restart

Rollback SHALL restore only a verifier-admitted composition that remains compatible with current retained identity state.
Successful byte restoration SHALL commit `rollback_restored_stopped` while launch suppression and Controller maintenance remain active.
Rollback SHALL NOT restart or uncordon the Node automatically.

#### Scenario: Compatible rollback bytes are restored

- **WHEN** rollback verification and retained-schema compatibility pass and the old bytes are restored exactly
- **THEN** the lifecycle SHALL leave the restored composition stopped in `rollback_restored_stopped`
- **AND** SHALL require a separate verified start

#### Scenario: Rollback compatibility is uncertain

- **WHEN** rollback bytes, identity schema, process custody, or journal state cannot be verified
- **THEN** the lifecycle SHALL leave the Node stopped and launch-suppressed
- **AND** SHALL NOT infer that restoring any available bytes is safe

### Requirement: Uncertainty Remains Stopped and Unschedulable

Any uncertain activation, start, recovery, rollback, journal, verification, compatibility, or custody result SHALL retain launch suppression and Controller maintenance.
Recovery SHALL NOT infer schedulability from local process health or infer safe start from restored bytes.

#### Scenario: Host reboots during a transition

- **WHEN** the host restarts with a nonterminal or uncertain managed-composition journal
- **THEN** the managed launch domain SHALL remain suppressed
- **AND** the Node SHALL remain in Controller maintenance until authorized recovery completes
