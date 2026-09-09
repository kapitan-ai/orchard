## ADDED Requirements

### Requirement: One Stable Helper Owns the Managed Host Fence

The Apple Silicon macOS host adapter SHALL expose one versioned privileged-helper protocol from the stable signed bootstrap for operation locking, durable launch suppression, Worker Provider spawn authorization and registration, one-shot Node Agent authorization, exact direct-process capture, stop, exit proof, and replacement detection.
Swift, Elixir, scripts, and tests SHALL consume that protocol rather than implement independent safety algorithms.
Managed activation SHALL NOT replace the helper or bootstrap.
The helper SHALL authenticate the installed caller code identity and role and SHALL authorize each command against exact Node ID, operation ID, transition generation, monotonic phase, executable identity, generation identity, and a fresh nonce.
Before the first side effect, it SHALL durably consume an operation-bound command ID and nonce bound to command kind and canonical arguments and SHALL record the result identity.
A duplicate command ID or nonce SHALL return the already recorded idempotent result when the canonical request matches or fail without mutation when it does not.
It SHALL reject replay across helper restart, stale phase, cross-role use, and any generic privileged spawn, signal, filesystem, pointer, or suppression mutation outside the closed versioned command set.

#### Scenario: Orchard requests managed host mutation

- **WHEN** any authorized Orchard surface requests activation, rollback, recovery, start, or stop for the managed profile
- **THEN** it SHALL use the same installed helper protocol and process-identity semantics

#### Scenario: Helper is unavailable or incompatible

- **WHEN** the exact verified helper cannot provide the required protocol
- **THEN** the operation SHALL fail before Controller drain or host mutation

#### Scenario: Unauthorized or replayed local request reaches the helper

- **WHEN** a caller has the wrong code identity or role, supplies a stale or mismatched binding, reuses a nonce, or requests a generic privileged mutation
- **THEN** the helper SHALL reject it without changing process, pointer, journal, suppression, or spawn-gate state

#### Scenario: Helper restarts after command consumption

- **WHEN** the helper restarts after durably consuming a command ID and nonce before, during, or after its first side effect and receives the command again
- **THEN** it SHALL reconcile the recorded result and return it idempotently or fail closed without repeating the mutation

### Requirement: General Launch Suppression Is Durable

The host adapter SHALL combine persistent launchd job-domain disablement with a stable launch-gate denial beneath `RunAtLoad` and `KeepAlive`.
It SHALL establish general suppression before process capture and SHALL preserve it across lifecycle-owner death, launchd retry, and host reboot until the exact managed terminal protocol enables one accepted child.
After an exact accepted Controller terminal result of `succeeded` or fully accepted `rolled_back`, the helper SHALL durably and idempotently replace transitional suppression with an exact active-generation launch policy bound to that terminal result, Node, generation, executable, and bootstrap.
Until the helper observes that terminal result and installs the policy, general suppression SHALL remain active.
Controller-terminal-active with host suppression still installed SHALL be an explicit recoverable state, and stable-bootstrap recovery SHALL retry only the exact bound policy installation.
The helper SHALL also durably reconcile the exact serving epoch established by that terminal result before the Node Agent may publish epoch-readiness or accept ordinary execution grants.
After installation, launchd restart SHALL be permitted only for that exact active generation.

#### Scenario: Lifecycle owner exits after suppression

- **WHEN** the initiating app or CLI exits or the host reboots after general suppression is durable
- **THEN** no ordinary managed Node Agent start SHALL succeed
- **AND** recovery SHALL observe suppression before interpreting journal state

### Requirement: One Public Launchd State Machine Owns the Node Agent Root

The profile-fixed system-domain launchd service label SHALL always name the stable bootstrap executable outside replaceable generations.
The stable bootstrap SHALL remain the launchd job root and SHALL `execve` the exact authorized generation's Node Agent in place without a shell, forked launcher, or change of launchd job identity.
In fully suppressed state, the helper SHALL keep both the label disabled and the stable launch gate denying starts.
For a one-shot provisional start, the helper SHALL first persist the exact unclaimed authorization while the label remains disabled, then enable and bootstrap only that label through the public launchd service-management interface.
The stable bootstrap SHALL atomically claim the authorization before it may `execve` the candidate, and the helper SHALL durably register the exact job-root identity and disable the label again while the provisional child continues running under stable-gate suppression.
A bootstrap invocation that cannot claim the one-shot SHALL exit without receiving Node identity or executing generation code.
Label enablement without the matching durable one-shot, a second claim, or any interrupted ordering SHALL leave the stable gate denying generation execution and SHALL be reconciled back to disabled state before recovery proceeds.
Only durable installation of the exact terminal active-generation launch policy SHALL both permit the stable gate to select that generation and leave the label enabled for ordinary launchd restart.
Stop SHALL use label-bound disablement and bootout, so provisional, exact-child-enabled, and active Node Agent roots remain controllable through the same launchd job authority after the in-place `execve`.

#### Scenario: Owner dies or host reboots during one-shot launch

- **WHEN** the lifecycle owner exits or the host reboots after any enable, bootstrap, claim, registration, or disable boundary
- **THEN** stable-bootstrap recovery SHALL read the durable gate and journal first, deny any second claim or ordinary generation start, restore label disablement for every nonterminal state, and resume or roll back only through the same transition generation

#### Scenario: Terminal active policy is installed

- **WHEN** the exact accepted Controller terminal result is observed and the matching active-generation launch policy is durably installed
- **THEN** the helper SHALL enable only the profile-fixed label and the stable bootstrap SHALL admit only the exact active generation on launchd start or restart

### Requirement: Worker Provider Process Shape Is Closed

The managed v1 MLX Worker Provider SHALL be one non-forking, non-daemonizing OS process that MAY use threads but SHALL NOT create descendants or launch another executable.
The managed Node Agent SHALL create only the exact pinned ERTS support-process set admitted by the Node Agent component and the helper-mediated Worker.
For OTP 29, the admitted ERTS set SHALL include the exact `erl_child_setup` executable created by ERTS.
Any profile `epmd` service SHALL be exact-pinned stable host infrastructure outside replaceable generations, not a generation child.
The stable launch gate SHALL record the exact Node Agent root, and the helper SHALL durably register every ERTS support-process PID, process-start identity, executable identity, generation identity, inherited-descriptor allowlist, and owning Node Agent before provisional or ordinary cluster authority is enabled.
An ERTS support process SHALL communicate only over its parent-private ERTS control pipe, SHALL receive no Node Certificate, BEAM Peer Grant, Worker channel capability, Controller request authority, or Runtime Endpoint, and SHALL exit on parent-pipe closure.
Any Erlang Port target, resolver helper, shell, library child, or direct spawn outside the exact admitted set SHALL be prohibited.
The Node Agent SHALL request every Worker Provider start through the stable helper.
The helper SHALL durably record an operation-bound pending spawn reservation and create a unique inherited reservation lock plus initialization-and-liveness gate before process creation.
The child SHALL hold the reservation lock for its lifetime, SHALL fail-exit on gate EOF before creating Worker Runtime state, and SHALL terminate on gate EOF after initialization so helper death removes the Worker.
The helper SHALL create the exact admitted executable without an intervening shell or persistent launcher by using public POSIX `fork`, identity drop, and `execve`, bind and durably record exact PID, process-start identity from `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`, executable identity from `proc_pidpath`, generation identity, execution epoch, and owning Node Agent, fsync that identity, and only then release initialization.
Before the Worker Provider image begins execution, the helper SHALL close every inherited descriptor except an explicit operation-bound and generation-bound allowlist containing only the reservation-lock, initialization-and-liveness-gate, and authenticated channel-capability descriptors.
Every helper control or listener, credential, directory, scratch, socket, and unrelated descriptor SHALL be `FD_CLOEXEC` or explicitly closed, and failure to prove that descriptor state SHALL block Worker Runtime initialization.
Recovery SHALL close the gate and acquire the reservation lock exclusively to prove that a pre-registration child exited even when no PID was committed.
After helper death in `bound`, `released`, serving, or terminal-pending state, the Worker SHALL fail-exit on liveness-gate EOF; the restarted helper SHALL preserve suppression, use the durable registry, acquire the reservation lock exclusively, and reconcile exact exit before any restart or pointer action.
For a recorded Worker child the helper SHALL use `waitpid`; for a registered Node Agent or ERTS support-process non-child it SHALL use the recorded `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)` start identity and `proc_pidpath` executable identity plus a live `kevent` `EVFILT_PROC` registration, exit observation, and post-exit identity recheck.
Only the original live helper parent SHALL reap its Worker child with `waitpid`; a restarted helper SHALL prove exit through liveness-gate EOF, exclusive reservation-lock acquisition, and any still-live `EVFILT_PROC` registration, and SHALL remain suppressed if that proof is incomplete.
The Worker Provider SHALL remain a Node Agent-local leaf without Node Certificates, BEAM Peer Grants, BEAM membership, Controller reachability, a TCP listener, or an independently schedulable Runtime Endpoint.
It SHALL run under a profile-fixed unprivileged Worker account name created and verified by the clean-host provisioning contract, and the composition SHALL NOT bind a machine-specific numeric UID.
That account's host-enforced filesystem policy SHALL deny the Node Identity Set, release-trust store, active pointer, managed journals, helper control endpoint, other generations, and shared mutable serving state.
For code and system resources, it SHALL permit read and execute access only to the exact admitted current-generation Worker executable, interpreter, dependency closure, and closed system-library, framework, device, and IPC resources bound by the qualified matrix.
For non-code data and mutable resources, it SHALL permit read-only admitted model inputs, write access only to generation-scoped scratch, and the authenticated generation-scoped local channel to its supervising Node Agent.
For each start, the helper SHALL mint a fresh channel capability, deliver the Worker copy only through an inherited descriptor and the Node Agent copy only through the authenticated helper protocol, and SHALL NOT expose it through argv, environment, logs, or shared files.
Both peers and every Worker Runtime request SHALL authenticate and bind Node, operation, transition generation, execution epoch, registered process identity, and request identity and SHALL reject replay and alternate peers.
The channel SHALL be one long-lived authenticated gRPC connection over a helper-reserved filesystem Unix-domain socket path in generation-scoped scratch, not an inherited connected socket.
The Worker SHALL bind that path under the dedicated account, the Node Agent SHALL connect and authenticate, and the helper SHALL then unlink the path so no new connection can attach.
Connection loss SHALL make the Worker unavailable and require helper-mediated restart rather than reopening the old path.
Process-table and executable scans MAY detect violations but SHALL NOT replace helper-owned registration.
Unrelated processes outside the managed launch domain SHALL remain untouched.

#### Scenario: Worker Provider attempts to create a descendant

- **WHEN** qualification or runtime evidence observes the Worker Provider fork, spawn, daemonize, or launch another executable
- **THEN** the provider SHALL violate the managed v1 process-shape contract
- **AND** activation SHALL fail closed with general suppression preserved

#### Scenario: Process-shape violation is observed during ordinary serving

- **WHEN** runtime evidence observes an admitted Worker create a descendant, daemonize, start another executable, or run under the wrong Worker identity outside a managed transition
- **THEN** the Node Agent SHALL immediately reject new Worker Runtime execution, the helper SHALL prevent new Worker initialization, terminate the violating registered process, establish and preserve general launch suppression, and report the exact active-generation fault to the Controller
- **AND** the Controller SHALL persist a managed-profile fault exclusion bound to that active generation before any later health or capacity update may make the Node schedulable
- **AND** unresolved Worker execution termination or allocation release SHALL additionally retain the existing `SPEC.md` §4.6.2 quarantine until its independent reconciliation completes
- **AND** heartbeat, portable Worker supervision or restart, health republishing, ordinary reconciliation, generic resume, and generic uncordon SHALL NOT clear the exclusion
- **AND** only an authenticated, audited, generation-checked managed repair that re-proves the exact process set, descriptor and filesystem closure, channel identities, and Worker readiness MAY clear it
- **AND** while Controller persistence cannot be obtained or verified, the host SHALL remain suppressed and locally reject execution

#### Scenario: BEAM generation attempts an unadmitted external process

- **WHEN** the Node Agent or its runtime attempts to create an external OS process outside the exact ERTS support set or helper-mediated Worker start
- **THEN** the managed v1 process-shape contract SHALL reject it and preserve suppression

#### Scenario: Registered process identity changes

- **WHEN** a registered process loses exact identity, reuses a PID, changes executable identity, or cannot be classified exactly
- **THEN** custody SHALL be uncertain and pointer activation SHALL be denied

#### Scenario: Helper or host fails during Worker spawn

- **WHEN** recovery observes a reservation in `reserved` or `spawned_blocked` state without a complete bound identity
- **THEN** it SHALL close the initialization gate, acquire the unique reservation lock exclusively to prove the child no longer holds it, reconcile the reservation, and preserve suppression before continuing

#### Scenario: Helper exits after Worker registration

- **WHEN** the helper exits after the Worker identity is bound in `released`, serving, or terminal-pending state
- **THEN** the Worker SHALL terminate on initialization-and-liveness-gate EOF and release its reservation lock
- **AND** the restarted helper SHALL preserve suppression and prove exit from the durable registry, exclusive lock acquisition, and any still-live exit registration before admitting restart or pointer mutation

#### Scenario: Stale process impersonates a Worker Runtime peer

- **WHEN** a process presents a stale capability, wrong execution epoch, wrong registered identity, replayed request identity, or alternate peer identity
- **THEN** the Worker Runtime channel SHALL reject it without executing work or exposing protected host state

### Requirement: No-New-Execution Point Is Proved Before Stop

Transition creation SHALL prevent every later allocation claim or new execution-grant issuance from committing.
The helper SHALL serialize durable local epoch closure against every in-progress final acceptance of a pre-fence grant, and closure SHALL prevent every later final acceptance in that epoch from committing.
After a fresh zero-active-allocation acknowledgement and durable general launch suppression, the helper SHALL atomically close the local Worker Provider spawn gate for the outgoing Node Agent.
The two-stage Controller execution-authority fence and closed local spawn gate SHALL establish the no-new-execution linearization point.
The helper SHALL then use its registered direct-process set as the exact set that must exit before pointer activation.

#### Scenario: Execution and spawn gates close authoritatively

- **WHEN** transition creation excludes new grant issuance, durable local epoch closure excludes later final acceptance, zero active allocations are acknowledged, general launch suppression is durable, and the helper closes Worker Provider spawning
- **THEN** the helper MAY record the no-new-execution point and exact registered process set

#### Scenario: Either authority cannot prove closure

- **WHEN** execution fencing, zero acknowledgement, launch suppression, spawn-gate closure, process registration, or process identity is incomplete or contradictory
- **THEN** the helper SHALL fail closed and preserve general suppression

### Requirement: Exit Proof Rejects Every Survivor and Replacement

After the no-new-execution point, the Node Agent SHALL close every Worker Runtime channel, and the helper SHALL terminate every registered Worker Provider and prove exact exit for each identity.
When the exact outgoing Node Agent has already exited, helper-proved generation-scoped socket removal and channel unconnectability SHALL satisfy the channel-closure obligation.
After provider exit, the helper SHALL remove every outgoing generation-scoped socket and prove that none remains connectable.
The helper SHALL then terminate the exact Node Agent root only through label-bound launchd job-domain disablement and bootout authority for the profile-fixed label so each registered ERTS support process exits through closure of its parent-private ERTS control pipe.
It SHALL NOT issue a bare-PID signal to the Node Agent root, SHALL prove root exit through its live `EVFILT_PROC` registration and post-exit identity recheck, and SHALL treat inability to exercise the exact launchd job authority as uncertainty that preserves suppression and blocks pointer activation.
The helper SHALL prove each registered ERTS support-process exit with a live `kevent` `EVFILT_PROC` registration plus post-exit identity recheck.
The helper SHALL NOT issue a bare-PID signal to a registered ERTS survivor after root exit because the PID could have been reused; a survivor or missing live registration SHALL be uncertainty, preserve suppression, and block pointer activation.
The helper SHALL prove no replacement root or observed unregistered generation process exists before pointer activation.

#### Scenario: Complete registered process set exits

- **WHEN** every registered Worker Provider, every registered ERTS support process, and the exact Node Agent root exit, all outgoing Worker Runtime channels are closed, all outgoing generation-scoped sockets are removed and unconnectable, and violation scans find no observed unregistered generation process or replacement root
- **THEN** the helper MAY issue the outgoing-fence evidence bound to the current operation

#### Scenario: Survivor or replacement is observed

- **WHEN** any registered process survives, a replacement root appears, a Worker Runtime channel remains usable, or an unregistered generation process is observed
- **THEN** the helper SHALL deny activation and preserve suppression

### Requirement: One-Shot and Host Arm Do Not Clear General Suppression

The helper SHALL permit one exact operation-bound provisional child to claim a one-shot while general suppression remains durable and the incoming Worker Provider spawn gate remains closed.
It SHALL persist a matching Controller host-arm token only as exact-child `host_armed_pending_controller_commit` evidence.
It SHALL NOT enter exact-child enabled state until the exact child consumes authenticated `controller_committed_pending_child_observation` evidence.
Only in exact-child enabled state MAY the helper open the incoming spawn gate for the exact child, generation, transition, and execution epoch while replacement and ordinary dispatch remain denied.
The exact child SHALL register the Worker through reserve-before-spawn, establish the authenticated channel, and acknowledge exact Worker identity, protocol compatibility, and a representative supported-model readiness or inference probe before the Controller's second terminal transaction may clear scheduler exclusion.
Node Agent or Worker exit, Worker readiness loss, or reboot before terminal success SHALL close the gate and preserve general suppression.

#### Scenario: Provisional child exits before acceptance

- **WHEN** the one-shot child exits or becomes unverifiable before exact-child enabled acknowledgement and the second terminal transaction
- **THEN** general suppression SHALL remain active
- **AND** launchd SHALL NOT create an ordinary replacement

#### Scenario: Exact child and Worker reach terminal readiness

- **WHEN** the exact enabled Node Agent and exact registered Worker prove the bound execution epoch, authenticated channel, protocol compatibility, and supported-model readiness and the Controller records terminal success
- **THEN** the helper SHALL durably and idempotently replace general suppression with the exact active-generation launch policy
- **AND** SHALL continue rejecting any stale, alternate-generation, or unbound replacement start

#### Scenario: Controller is terminal active while host suppression remains

- **WHEN** the Controller has accepted terminal `succeeded` or fully accepted `rolled_back` but the exact active-generation launch policy is not durably installed
- **THEN** the host SHALL remain suppressed and stable-bootstrap recovery SHALL idempotently retry only the policy bound to that exact terminal result, Node, generation, executable, and bootstrap
- **AND** no ordinary or alternate-generation restart SHALL be admitted before installation succeeds
