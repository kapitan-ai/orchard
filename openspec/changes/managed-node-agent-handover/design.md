## Context

`SPEC.md` §11.4 requires Orchard.app and PKG to remain compatible managed lifecycle paths for the same installed roles, paths, launchd labels, and retained state.
`SPEC.md` §13.1 requires Controller version `N` to support Node Agent versions `N` and `N-1`, while §13.4 makes that historical compatibility safe through Managed Node Agent Handover rather than simultaneous access to one Node Identity Root.
ADR 0017 records the selected zero-overlap and stage-then-activate decision.

The Node Identity Root contains the Node private key, Node Certificate, enrolled trust state, and stored BEAM Peer Grants.
An outgoing Node Agent and its replacement must not overlap while using that identity-bearing state.
ADR 0012 requires atomic Peer Grant storage but does not define lifecycle locking.
The current `Orchard.Node.BeamPeerGrantStore` uses an operation-scoped BEAM Peer Grant Store Lock for one install or load operation, including atomic publication when installing, and that lock does not establish lifecycle ownership of the root.

Orchard.app already owns a transactional lifecycle that stages payload, snapshots managed state, uses `/Library/Application Support/Orchard/support/.app-lifecycle.lock`, attempts rollback after ordinary commit failures, and restores the prior loaded-service set.
PKG remains a parallel privileged installer that supports direct `/usr/sbin/installer`, leaves services stopped after successful install or upgrade, and does not promise transactional rollback.
Apple Installer runs `preinstall`, places package payload, and then runs `postinstall` as separate processes.
A lock descriptor held by either script therefore cannot span direct active-path payload replacement without unsafe ownership transfer or inheritance.

## Goals

- Define one crash-released exclusion boundary used by managed Orchard.app, PKG, recovery, and Node Agent start eligibility paths.
- Establish zero managed process overlap across every active handover.
- Make PKG delivery stage signed content inertly before one postinstall-invoked owner performs active activation.
- Require proven exit of the exact outgoing process instance, or proven absence of any managed Node Agent instance, before active mutation or start.
- Preserve PKG manual start and Orchard.app's unconditional rollback attempt and loaded-state restoration obligations.
- Define managed recovery after timeout, owner death, or uncertain state.
- Keep the BEAM Peer Grant Store Lock operation-scoped and distinct from lifecycle exclusion.

## Non-Goals

- Live overlap between outgoing and replacement Node Agent processes.
- A lifetime Node Identity Root Lease.
- Separate Orchard.app and PKG lifecycle locks.
- A durable lock marker or session fence as exclusion ownership.
- Node Identity Root schema migration, root migration, or deletion.
- Transactional PKG rollback.
- An external installer wrapper required for correctness.
- Automatic Node Agent restart after uncertain state.
- Support for blind or manual same-root launch while uncertainty remains.

## Shared Exclusion Boundary

The canonical boundary is one interoperable exclusive kernel advisory lock on `/Library/Application Support/Orchard/support/.app-lifecycle.lock`.
Every managed Orchard.app or PKG operation that can hand over or mutate the Node Agent, every managed recovery, and every supported Node Agent start eligibility check uses that same boundary.

One privileged owner acquires the lock and retains the same kernel lock ownership continuously from before relaunch prevention through exact outgoing-instance exit or proven absence, active activation and protected mutation, the applicable start decision, and terminal-state reporting.
Ownership does not transfer between `preinstall`, Apple Installer, `postinstall`, a helper, or any child process.
The owner prevents lock descriptor inheritance by subprocesses and the replacement service.
Normal completion releases ownership by closing the descriptor.
Owner process death releases ownership through the operating system.
Contention performs no managed mutation and starts no Node Agent.
A later managed operation may retry after kernel ownership is released.

Persistent transaction or rendezvous metadata may record phase, diagnosis, and recovery inputs.
Its existence never constitutes exclusion ownership, never authorizes mutation or start, and never blocks a later managed recovery solely because a record remains.
The BEAM Peer Grant Store Lock remains scoped to one `Orchard.Node.BeamPeerGrantStore` install or load operation, including atomic publication when installing, and is not reused or broadened for lifecycle exclusion.

## PKG Stage-Then-Activate Topology

Apple Installer places signed PKG content only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute.
Inert staging is not active installation mutation and may occur before the shared lifecycle lock is acquired while the current Node Agent continues running.
The staged payload remains subject to signature, ownership, path, and integrity validation before activation.

PKG `preinstall` may perform non-active preflight and prepare the incoming staging destination.
It does not stop the active Node Agent, prevent its relaunch, or mutate active payload, launchd records, command links, role state, or the Node Identity Root.

After Apple Installer finishes staging, PKG `postinstall` synchronously invokes one privileged handover owner.
That owner acquires the canonical lock and performs the entire active handover before returning the terminal result to `postinstall`.
The package invokes the owner itself, so direct `/usr/sbin/installer -pkg ... -target /` remains supported without an external Orchard wrapper.

## Active Handover Ordering

After active preflight succeeds and while one owner retains the shared exclusion boundary, the handover follows this ordering:

1. Record only the path-specific inputs needed for start policy and recovery.
2. Prevent Node Agent relaunch through verified launchd job-domain control such as successful `bootout` followed by proof that the job is unloaded.
3. Do not edit or delete the protected launchd plist as the means of relaunch prevention before the proof gate.
4. Identify the exact outgoing Node Agent process instance, or affirmatively prove that no managed Node Agent instance is running.
5. When an outgoing instance was identified, request managed shutdown and wait for proof that the identified instance exited.
6. Fail closed if neither exact-instance exit nor managed-process absence is proven within the bounded wait.
7. Only after the proof gate succeeds, activate staged content and mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root as required.
8. Apply the Orchard.app or PKG start policy only after coherent installed state is established.
9. Report the terminal result while still holding the boundary.
10. Release the boundary after terminal reporting, with owner death providing abnormal crash release.

Process-instance evidence must distinguish the captured outgoing instance from a later or unrelated process rather than rely only on a reusable numeric PID or service label.
Absence evidence must distinguish a proven-absent managed Node Agent from one the lifecycle merely failed to observe.
The concrete process identity representation, helper language, executable location, incoming staging pathname, and metadata schema remain implementation choices subject to those proofs.

## Start Policies

After a coherent successful Orchard.app install or update, Orchard.app may restore the prior loaded-service state for services still selected by the resulting role.
After a required successful Orchard.app rollback, restoration includes the prior loaded-service state.

PKG leaves all role-selected services stopped after every successful fresh install and upgrade.
PKG does not automatically start services and does not restore the prior loaded-service state.
The supported later PKG start path is `orchardctl start`.
Before starting the Node Agent, `orchardctl start` uses the shared exclusion boundary to verify coherent installed state and satisfied handover eligibility.

## Failure And Managed Recovery

Failure to acquire or retain exclusion, prevent relaunch, prove exact exit, or prove absence occurs before active mutation and Node Agent start.
If relaunch prevention was established, a failed operation does not deliberately reverse it merely to restore automatic launch behavior.

After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app unconditionally attempts complete rollback of the prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
The app reports whether rollback completed successfully.
If required rollback cannot be completed or verified, the state is uncertain and the Node Agent remains stopped.
PKG gains no transactional rollback promise, and uncertain PKG activation or installed state also remains stopped.

Managed recovery reruns the applicable Orchard.app or PKG lifecycle under the same exclusion boundary.
It may reauthorize start only after proving exact outgoing-instance exit or managed-process absence and verifying or restoring coherent installed state.
After recovery, Orchard.app applies its prior-loaded-state policy and PKG still requires the later supported `orchardctl start` path.
Blind `launchctl` kickstart, direct binary launch, or manual same-root start while uncertainty remains is unsupported.

## Guarantee Boundary

The zero-overlap guarantee covers managed Orchard.app, PKG, managed recovery, and supported Node Agent start eligibility paths using the shared exclusion boundary.
Direct or manual Node Agent launches that bypass those paths remain unsupported and outside the guarantee.

Controller `N` compatibility with Node Agent versions `N` and `N-1` supports rolling managed upgrades across nodes.
On each managed node, safety comes from shutting down and proving exit of the historical process before activating or starting its replacement, not from running both versions concurrently.

## Alternatives And Trade-Offs

### Live Historical And Replacement Overlap

Running Node Agent `N-1` and `N` concurrently was rejected because protocol compatibility does not establish safe concurrent ownership of one Node Identity Root.
It would require a materially broader identity-state concurrency protocol.

### Lifetime Node Identity Root Lease

A process-lifetime lease was deferred because it introduces runtime ownership, renewal, fencing, and recovery semantics beyond issue #158.
The current handover needs lifecycle exclusion, not a new permanent runtime lease.

### Separate App And PKG Locks

Dual locks were rejected because independent app and PKG ownership cannot exclude cross-path races.
All managed paths must contend on one canonical lock and interoperable protocol.

### Durable Lock Or Session Fence

A durable marker or per-phase session fence was rejected as exclusion ownership because owner death creates stale-state validation and unsafe reclamation questions.
Persistent metadata remains useful only for diagnosis and managed recovery while the live kernel lock remains the sole exclusion owner.

### External Installer Wrapper

An `orchardctl` or installer wrapper could own the lock around `/usr/sbin/installer`, but direct installer invocation would bypass it.
A wrapper may remain a convenience but cannot be required for correctness.

### Long-Lived Coordinator Across Installer Phases

A coordinator spanning `preinstall`, Apple Installer payload placement, and `postinstall` could retain a live lock, but it lacks an authoritative transaction-lifetime signal if Installer aborts before `postinstall`.
Timeout release could race ongoing Installer mutation, while indefinite retention would create an availability failure.
This topology was rejected for the active payload interval.

### Inert Staging Plus One Postinstall-Owned Active Handover

The selected topology lets Apple Installer place signed content into a root that the running Node Agent cannot use, then invokes one privileged owner for the complete active activation interval.
It preserves direct installer support, one crash-released lock owner, zero active overlap, and a bounded recovery surface without introducing a lifetime lease or durable exclusion marker.
The trade-off is additional staging storage and an explicit activation helper or coordinator request after payload placement.

## Verification Strategy

Verification must exercise public Orchard.app, direct `/usr/sbin/installer`, `postinstall`-owned handover, managed recovery, and `orchardctl start` paths rather than only an isolated lock helper.
Coverage must prove that concurrent Orchard.app, PKG, recovery, and start attempts cannot cross the shared boundary.
Coverage must prove that `preinstall` leaves the active Node Agent and active lifecycle state unchanged and that the incoming staging root is never resolved, loaded, or executed by a running Node Agent.
Coverage must prove that one owner retains the same lock without transfer or descriptor inheritance through relaunch prevention, exact exit or absence proof, activation, protected mutation, start policy, and terminal reporting.
Coverage must exercise contention, owner crash, installer abort, repeated install, exact-instance ambiguity, unprovable absence, bounded timeout, activation uncertainty, and persistent metadata that survives without becoming ownership.
Coverage must prove verified `bootout` precedes exit proof without protected plist mutation.
Coverage must prove PKG never auto-starts after fresh install or upgrade and that later `orchardctl start` rejects incoherent or unresolved state.
Coverage must prove Orchard.app always attempts full rollback after post-mutation failure, restores prior loaded state when rollback succeeds, and leaves the Node Agent stopped when rollback cannot be completed or verified.
Coverage must prove managed recovery is the only supported path from uncertainty to renewed start eligibility.
Coverage must confirm the BEAM Peer Grant Store Lock remains operation-scoped and rolling `N`/`N-1` safety uses serialized replacement.
