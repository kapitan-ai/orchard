## ADDED Requirements

### Requirement: One Stable Helper Owns the Managed Host Fence

The Apple Silicon macOS host adapter SHALL expose one versioned privileged-helper protocol from the stable signed bootstrap for operation locking, durable launch suppression, one-shot authorization, kernel-backed process containment, exact capture, stop, exit proof, and replacement detection.
Swift, Elixir, scripts, and tests SHALL consume that protocol rather than implement independent safety algorithms.
Managed activation SHALL NOT replace the helper or bootstrap.

#### Scenario: Orchard requests managed host mutation

- **WHEN** any authorized Orchard surface requests activation, rollback, recovery, start, or stop for the managed profile
- **THEN** it SHALL use the same installed helper protocol and process-identity semantics

#### Scenario: Helper is unavailable or incompatible

- **WHEN** the exact verified helper cannot provide the required protocol
- **THEN** the operation SHALL fail before Controller drain or host mutation

### Requirement: General Launch Suppression Is Durable

The host adapter SHALL combine persistent launchd job-domain disablement with a stable launch-gate denial beneath `RunAtLoad` and `KeepAlive`.
It SHALL establish general suppression before process capture and SHALL preserve it across lifecycle-owner death, launchd retry, and host reboot until the exact managed terminal protocol enables one accepted child.

#### Scenario: Lifecycle owner exits after suppression

- **WHEN** the initiating app or CLI exits or the host reboots after general suppression is durable
- **THEN** no ordinary managed Node Agent start SHALL succeed
- **AND** recovery SHALL observe suppression before interpreting journal state

### Requirement: Process Fence Uses Authoritative Managed Containment

Before a baseline or candidate generation first starts, the stable bootstrap SHALL place its Node Agent and every descendant into a supported public macOS kernel-backed Managed Process Containment.
Containment membership SHALL survive reparenting, SHALL NOT be escapable by generation code, and SHALL be authoritatively enumerable by the helper.
The host adapter SHALL identify each member by exact PID, process-start identity, executable identity, generation identity, and containment identity.
Process-table and executable scans MAY detect violations but SHALL NOT establish complete membership or the no-new-child proof.
Unrelated processes outside that containment SHALL remain untouched.

#### Scenario: Worker Provider has nested descendants

- **WHEN** the outgoing Node Agent supervises a Worker Provider that has one or more nested children
- **THEN** every descendant SHALL remain in the authoritative Managed Process Containment before activation may continue

#### Scenario: Process is reparented or identity changes

- **WHEN** a process running generation code is outside containment, loses exact identity, reuses a PID, changes executable identity, or cannot be classified exactly
- **THEN** custody SHALL be uncertain and pointer activation SHALL be denied

### Requirement: No-New-Child Point Is Proved Before Stop

After general suppression, the helper SHALL ask the authoritative containment to atomically close against new descendants and SHALL record that successful close as the no-new-child linearization point.
The helper SHALL then enumerate the complete closed membership and terminate or freeze it through the same supported containment authority.
If the host lacks a supported public macOS primitive that proves these properties, managed activation SHALL remain blocked and the profile SHALL remain unsupported.

#### Scenario: Containment closes authoritatively

- **WHEN** the kernel-backed containment atomically closes membership against new descendants and returns its complete exact membership
- **THEN** the helper MAY record the no-new-child point

#### Scenario: Containment cannot prove closure

- **WHEN** containment close fails, membership is incomplete, a member escapes, an external generation process exists, or the public primitive cannot prove the contract
- **THEN** the helper SHALL fail closed and preserve general suppression

### Requirement: Exit Proof Rejects Every Survivor and Replacement

After the no-new-child point, the helper SHALL terminate every member of the complete closed containment and prove exact exit for each identity.
It SHALL then prove the containment is empty and no replacement launchd root or process running outgoing-generation code exists before pointer activation.

#### Scenario: Complete closure exits

- **WHEN** every authoritative containment member exits, the containment is empty, and violation scans find no external generation process or replacement root
- **THEN** the helper MAY issue the outgoing-fence evidence bound to the current operation

#### Scenario: Survivor or replacement is observed

- **WHEN** any captured, reparented, generation-member, replacement-root, or replacement-descendant process remains or appears
- **THEN** the helper SHALL deny activation and preserve suppression

### Requirement: One-Shot and Host Arm Do Not Clear General Suppression

The helper SHALL permit one exact operation-bound provisional child to claim a one-shot while general suppression remains durable.
It SHALL persist a matching Controller host-arm token only as exact-child `host_armed_pending_controller_commit` evidence.
It SHALL NOT change general suppression into exact-child enabled state until the exact child consumes authenticated `controller_committed_pending_child_observation` evidence.
That enabled state SHALL continue to deny replacement and ordinary dispatch until the Controller's second terminal transaction clears scheduler exclusion.

#### Scenario: Provisional child exits before acceptance

- **WHEN** the one-shot child exits or becomes unverifiable before exact-child enabled acknowledgement and the second terminal transaction
- **THEN** general suppression SHALL remain active
- **AND** launchd SHALL NOT create an ordinary replacement
