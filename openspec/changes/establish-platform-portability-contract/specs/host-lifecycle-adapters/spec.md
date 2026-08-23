## ADDED Requirements

### Requirement: Lifecycle Authority Is External To The Managed Process
Managed Node Agent exclusion, fencing, replacement, and launch authorization SHALL be owned by a host lifecycle actor that remains independent of the Node Agent instance being managed.
The managed Node Agent MUST NOT be the sole authority that proves its own termination or replacement safety.
This requirement generalizes `SPEC.md` §§11.2 and 11.4 while preserving ADR 0018.

#### Scenario: Managed Node Agent must be replaced
- **WHEN** an authorized update or stop operation replaces or terminates a Node Agent
- **THEN** an external host lifecycle actor retains exclusion and verifies the exact managed instance outcome
- **AND** owner or managed-process death cannot create overlapping accepted instances

### Requirement: Platform-Neutral Managed Host Lifecycle
The managed-host lifecycle interface SHALL provide crash-released exclusion, independent observation of durable start policy, host-manager state, and managed-process state, exact-instance fencing to proven stopped state, and one provisional authorized launch.
Callers MUST NOT need launchd, systemd, container, shell-command, or platform process-identity vocabulary to use the interface correctly.
Unknown, multiple, unstable, or unverifiable process state SHALL fail closed.
This requirement generalizes the invariants in `SPEC.md` §11.4.

#### Scenario: Host manager reports inactive
- **WHEN** a host adapter reports that its managed unit is inactive but cannot prove the captured process instance absent or exited
- **THEN** the lifecycle interface does not report a coherent stopped state

#### Scenario: Provisional child is launched
- **WHEN** a lifecycle owner authorizes exactly one start attempt under retained exclusion
- **THEN** the adapter returns a non-reusable child identity
- **AND** the child cannot serve until portable lifecycle state records atomic acceptance

### Requirement: Platform Evidence Preserves Portable Outcomes
Lifecycle evidence SHALL record normalized exclusion, activation, process-observation, fence, and launch outcomes plus optional bounded platform-tagged diagnostic detail.
Portable lifecycle code MUST NOT branch on platform diagnostic detail.
Existing macOS lifecycle evidence SHALL remain readable and MUST NOT be rewritten solely to adopt the normalized schema.
This requirement changes `SPEC.md` §11.4 evidence vocabulary without weakening its retention or safety rules.

#### Scenario: Legacy macOS evidence is inspected
- **WHEN** Orchard reads an existing launchd-named lifecycle evidence record
- **THEN** it translates the record to normalized read semantics
- **AND** it preserves the original durable record unchanged

### Requirement: Platform Native Artifacts Are Isolated
Host adapters that require native platform code SHALL be built and validated only in compatible platform lanes and MUST NOT be unconditional compile dependencies of the portable umbrella.

#### Scenario: Linux portable compile excludes Darwin helper
- **WHEN** the portable umbrella compiles on Linux
- **THEN** Darwin lifecycle and terminal-custody sources are not compiled
- **AND** their absence does not remove platform-neutral Controller, Node Agent, Shared, or CLI modules
