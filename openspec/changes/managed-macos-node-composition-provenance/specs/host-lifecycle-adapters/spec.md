## ADDED Requirements

### Requirement: One Helper Protocol Owns the Managed Launch-Domain Fence

The Apple Silicon macOS host adapter SHALL expose one versioned privileged-helper protocol for operation locking, durable launch suppression, exact process capture, stop, exit proof, and replacement detection for the supported managed launch domain.
Swift, Elixir, scripts, and tests SHALL consume that protocol rather than implement independent safety algorithms.

#### Scenario: Any Orchard surface requests a managed stop fence

- **WHEN** the app, CLI, or another authorized Orchard surface requests managed composition activation
- **THEN** it SHALL use the same helper protocol and process-identity semantics

#### Scenario: Helper protocol is unavailable or incompatible

- **WHEN** the installed helper cannot provide the required protocol version or safety operation
- **THEN** host mutation SHALL fail before activation

### Requirement: Launch Suppression Is Durable Across Failure and Reboot

The host adapter SHALL establish managed launch suppression before stopping the outgoing process set.
Suppression SHALL survive lifecycle-process failure and host reboot until a verified start or authorized repair clears it.
Failure to prove suppression SHALL be a hard transition failure.

#### Scenario: Lifecycle process crashes after suppression

- **WHEN** the initiating app or CLI exits after durable suppression is recorded
- **THEN** the managed launch domain SHALL remain unable to start a process
- **AND** recovery SHALL observe suppression before interpreting journal state

### Requirement: Process Custody Uses Exact Identity and Rejects Replacement

The host adapter SHALL capture each managed process with PID, process-start identity, executable identity, and supported managed launch-domain membership.
It SHALL stop only captured identities, prove their exit, and reject PID reuse, executable replacement, or a newly launched managed process.
Unrelated processes SHALL remain untouched.

#### Scenario: Captured process exits without replacement

- **WHEN** every exact captured managed identity exits and repeated observation finds no process in the managed launch domain
- **THEN** the host adapter MAY return an outgoing-fence proof

#### Scenario: PID is reused or executable changes

- **WHEN** an observed PID no longer matches the captured start or executable identity
- **THEN** the host adapter SHALL treat custody as uncertain
- **AND** SHALL NOT signal the mismatched process as though it were the captured process

### Requirement: Zero-Overlap Guarantee Is Limited to the Supported Launch Domain

The v1 host adapter SHALL guarantee no process overlap only for processes launched through the profile's supported managed launch domain.
It SHALL NOT claim to fence arbitrary manual processes or external supervisors.

#### Scenario: Unsupported external process path exists

- **WHEN** an operator starts equivalent binaries outside the managed launch domain
- **THEN** Orchard SHALL NOT represent them as covered by the v1 zero-overlap guarantee
- **AND** profile qualification SHALL document the supported launch boundary precisely
