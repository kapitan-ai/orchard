# Managed Node Agent handover uses zero process overlap

## Status

Accepted.

Owner decision recorded 2026-08-04 for issue #158 and reconciled 2026-08-05.

## Context

`SPEC.md` section 11.4 gives Orchard.app and PKG compatible installed paths, launchd labels, role values, and retained-state semantics.
`SPEC.md` sections 13.1 and 13.4 require Controller version `N` to support Node Agent versions `N` and `N-1` during rolling node upgrades.
That compatibility window does not make concurrent historical and replacement Node Agent processes safe when both can use one Node Identity Root.
The Node Identity Root contains the Node private key, Node Certificate, enrolled trust state, and stored BEAM Peer Grants, so concurrent access can cross identity, authorization, and lifecycle mutation boundaries.

ADR 0012 requires the Node to store each plaintext BEAM Peer Grant atomically in its owner-only identity root.
ADR 0012 does not define a BEAM Peer Grant storage lock or make one responsible for Node Agent lifecycle ownership.
The current `Orchard.Node.BeamPeerGrantStore` uses an operation-scoped BEAM Peer Grant Store Lock to serialize one grant install or load operation, including atomic publication when installing.
That store lock ends with the store operation and cannot provide complete Managed Node Agent Handover exclusion.

Apple Installer runs separate `preinstall` and `postinstall` processes with payload placement between them.
No package-script file descriptor can therefore own one kernel lock continuously across direct active-path payload replacement.
Direct `/usr/sbin/installer` must remain supported without an Orchard-specific outer wrapper.

## Decision

Managed Orchard.app and PKG Node Agent lifecycle mutations use one shared exclusion boundary at `/Library/Application Support/Orchard/support/.app-lifecycle.lock`.
The boundary uses one interoperable exclusive kernel advisory lock protocol.
Every Managed Node Agent Handover uses zero process overlap.

One privileged handover owner acquires the canonical lock and retains the same kernel lock ownership continuously, without transfer or descriptor inheritance, from before relaunch prevention through exact outgoing-instance exit or proven absence, active activation and protected mutation, the applicable start decision, and terminal reporting.
Normal completion closes the owning descriptor.
Owner process death releases the lock through the operating system.
Contention performs no managed mutation or Node Agent start, and a later managed operation may retry after ownership is released.
Persistent transaction or rendezvous metadata may support diagnosis and recovery, but it never constitutes exclusion ownership or independently authorizes or blocks lifecycle work.

PKG uses stage-then-activate.
Apple Installer places signed payload only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute.
PKG `preinstall` does not stop the active Node Agent, prevent relaunch, or mutate active payload, launchd records, command links, role state, or the Node Identity Root.
After inert staging, PKG `postinstall` synchronously invokes one privileged handover owner for the complete active handover.
The package itself invokes that owner, so direct `/usr/sbin/installer -pkg ... -target /` remains safe without an external wrapper.

The owner prevents relaunch with verified launchd job-domain control such as `bootout` followed by proof that the job is unloaded.
Relaunch prevention does not mutate or delete the protected plist before the handover gate.
While retaining the shared lock, the owner proves either that the exact identified outgoing Node Agent process instance exited after managed shutdown or that no managed Node Agent instance is running.
Only proven exit or proven absence satisfies the gate, and the wait is bounded.
Failure to acquire or retain exclusion, prevent relaunch, prove exact exit, or prove absence fails closed without active mutation or Node Agent start.
Only after the gate succeeds may the owner activate staged content or mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.

Orchard.app may restore the prior loaded-service state after a coherent successful operation for services still selected by the installed role.
After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app always attempts complete rollback of prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
If required rollback cannot be completed or verified, the state is uncertain and the Node Agent remains stopped.

PKG never automatically starts role-selected services and never restores their prior loaded-service state after either fresh install or upgrade.
The supported later PKG start path is `orchardctl start`, which must verify coherent installed state and handover eligibility under the shared exclusion boundary before starting the Node Agent.

Managed recovery reruns the applicable Orchard.app or PKG lifecycle while holding the same exclusion boundary.
It may reauthorize start only after proving exact outgoing-instance exit or managed-process absence and verifying or restoring coherent installed state.
Blind or manual same-root launch while uncertainty remains is unsupported.
Direct or manual Node Agent launches that bypass supported managed lifecycle and start eligibility remain outside the managed handover guarantee.

The BEAM Peer Grant Store Lock remains operation-scoped and does not become a lifecycle lock, Managed Node Agent Handover exclusion, or Node Identity Root Lease.
The Controller `N` compatibility window for Node Agent versions `N` and `N-1` is made safe on each managed node through managed shutdown and serialized replacement, not live coexistence.

## Non-goals

Live overlap between outgoing and replacement Node Agent processes is not supported.
A lifetime Node Identity Root Lease is not introduced.
Separate app and PKG lifecycle locks are not introduced.
A durable lock marker or session fence is not introduced as exclusion ownership.
Node Identity Root schema migration, root migration, or deletion is not introduced.
Transactional PKG rollback is not introduced.
An external installer wrapper is not required for correctness.
Automatic Node Agent restart after uncertain state is not introduced.
Support for blind or manual same-root launch during uncertainty is not introduced.

## Consequences

Managed Node Agent updates incur a bounded per-node interruption during the active handover.
PKG can stage signed inert content while the current Node Agent remains active, then incurs interruption only when the postinstall-owned active handover begins.
PKG fresh installs and upgrades remain stopped until the operator uses `orchardctl start`.
Orchard.app retains its complete rollback and loaded-state restoration obligations.
A crashed owner cannot leave kernel lock ownership stale, and any state left uncertain by that crash remains fail-closed until managed recovery proves coherence.
Future work may define a lifetime Node Identity Root Lease, but it must not silently broaden the BEAM Peer Grant Store Lock or replace the canonical handover boundary.

## SPEC.md impact

`SPEC.md` sections 11.4 and 13.4 define stage-then-activate PKG behavior, the single-owner crash-released exclusion boundary, exact outgoing-process exit proof, manual PKG start, unconditional Orchard.app rollback, managed recovery, and historical-version serialization.
