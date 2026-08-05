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
- Make PKG delivery stage one complete authenticated and signed generation inertly before one postinstall-invoked owner performs active activation.
- Establish durable suppression before final process observation, then capture stable non-reusable exact outgoing-process evidence or affirmatively prove absence immediately before `bootout` and require every captured-instance exit before active mutation or start.
- Require durable handover, recovery, and start-attempt evidence with terminal coherent marking only after the applicable verification.
- Preserve PKG manual start through reboot-safe suppression and crash-invalid one-shot authorization beneath launchd `RunAtLoad` and `KeepAlive`.
- Preserve Orchard.app's unconditional rollback attempt and loaded-state restoration obligations.
- Define managed recovery after timeout, owner death, missing or incomplete evidence, or uncertain state.
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

One privileged owner acquires the lock and retains the same kernel lock ownership continuously from before initial operation evidence and durable suppression through immediate pre-`bootout` observation, every captured-instance exit or affirmative absence, active activation and protected mutation, the applicable start decision, and terminal-state reporting.
Ownership does not transfer between `preinstall`, Apple Installer, `postinstall`, a helper, or any child process.
The owner prevents lock descriptor inheritance by subprocesses and the replacement service.
Normal completion releases ownership by closing the descriptor.
Owner process death releases ownership through the operating system.
Contention performs no managed mutation and starts no Node Agent.
A later managed operation may retry after kernel ownership is released.

Before changing Managed Node Agent Start Eligibility State or any other protected active state, the owner durably records required handover or recovery evidence containing the operation identity and phase, the bound staging generation when applicable, prior active path and start policy as needed, and the intended mutation.
The evidence must survive owner death and reboot.
A no-start handover or recovery becomes terminal coherent only after installed-state verification, and a later managed start uses a distinct start-attempt identity and evidence record.
Missing, incomplete, or uncertain evidence denies start but never constitutes exclusion ownership or prevents a later managed recovery owner from acquiring the kernel lock.
Persistent metadata is recovery evidence and start-eligibility fencing, not an independent authority to mutate or start.
The BEAM Peer Grant Store Lock remains scoped to one `Orchard.Node.BeamPeerGrantStore` install or load operation, including atomic publication when installing, and is not reused or broadened for lifecycle exclusion.

## PKG Stage-Then-Activate Topology

Apple Installer places authenticated and signed PKG content only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute.
Inert staging is not active installation mutation and may occur before the shared lifecycle lock is acquired while the current Node Agent continues running.
Before relaunch prevention or active mutation, the owner binds activation to exactly one staging generation in a unique per-generation namespace and verifies its identity, completeness, integrity, trust, and intended installation target.
The bound generation is an immutable or equivalently identity-stable snapshot that concurrent or repeated installers cannot replace or modify through activation.
Immediately before atomic activation, the owner revalidates its bound pathname or descriptor identity, manifest, signature, complete file set, content integrity, trust, and target.
Initial discovery of partial, stale, mixed-generation, untrusted, ambiguous, replaced, modified, or missing staged content fails before any protected active Node Agent lifecycle mutation.
Any bound-generation mismatch found by immediate pre-activation revalidation fails before payload or installed-state activation and leaves start suppressed for recovery.

PKG `preinstall` may perform non-active preflight and prepare the incoming staging destination.
It does not stop the active Node Agent, prevent its relaunch, or mutate active payload, launchd records, command links, role state, or the Node Identity Root.

After Apple Installer finishes staging, PKG `postinstall` synchronously invokes one privileged handover owner.
That owner acquires the canonical lock and performs the entire active handover before returning the terminal result to `postinstall`.
The package invokes the owner itself, so direct `/usr/sbin/installer -pkg ... -target /` remains supported without an external Orchard wrapper.

## Active Handover Ordering

After active preflight succeeds and while one owner retains the shared exclusion boundary, the handover follows this ordering:

1. For PKG, validate and bind exactly one complete authenticated and signed staging generation in an immutable or equivalently identity-stable unique namespace before relaunch prevention or active mutation.
2. Durably record the required operation identity, phase, staging generation when applicable, prior active path and start policy as needed, and intended mutation before changing start eligibility or any other protected active state.
3. Establish protected durable start suppression.
4. Under that suppression and immediately before `bootout`, observe managed Node Agent process state.
5. If exactly one outgoing instance is running, capture non-reusable evidence identifying that exact process instance, durably add it to the operation record, and verify identity stability through `bootout`; otherwise, affirmatively prove at that point that no managed instance exists.
6. Fail closed if an additional, replacement, or identity-unstable managed process appears.
7. Prevent relaunch through verified launchd job-domain control such as successful `bootout` followed by proof that the job is unloaded, without first editing or deleting the protected launchd plist.
8. When an outgoing instance was captured, request managed shutdown through the job-domain operation and wait for proof that every captured managed instance exited.
9. Fail closed if every captured-instance exit or affirmative absence under suppression immediately before `bootout` is not proven within the bounded wait, and never reinterpret failed observation as later absence.
10. Immediately before atomic activation, fully revalidate the bound immutable or identity-stable staging generation.
11. Only after the proof gate and generation revalidation succeed, activate the bound staged generation and mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root as required.
12. Verify the resulting active installed state and mark the no-start handover or recovery evidence terminal coherent with its path-specific no-start outcome.
13. Apply any allowed Orchard.app loaded-state restoration through the separate managed start-attempt protocol, while PKG remains suppressed until a later `orchardctl start`.
14. Report the terminal result while still holding the boundary, then release the boundary, with owner death providing abnormal crash release.

Process-instance evidence must distinguish the captured outgoing instance from a later or unrelated process rather than rely only on a reusable numeric PID or service label.
Absence evidence must distinguish an affirmatively proven-absent managed Node Agent under suppression immediately before `bootout` from one the lifecycle merely failed to observe.
The protected Managed Node Agent Start Eligibility State must be enforced by the managed launch path before Node Agent execution and survive owner death, reboot, launchd domain reload, and `KeepAlive` retry.
The concrete process identity representation, helper language, executable location, incoming staging pathname, and durable evidence schema remain implementation choices subject to those proofs.

## Start Policies

After a coherent successful Orchard.app install or update, Orchard.app may restore services that were previously loaded and remain selected by the resulting role only through the managed start-attempt protocol.
After a required successful Orchard.app rollback, restoration uses the same protocol.

PKG leaves all role-selected services stopped and start-suppressed after every successful fresh install and upgrade.
PKG does not automatically start services and does not restore the prior loaded-service state.
The supported later PKG start path is `orchardctl start`.
Every Orchard.app restoration or `orchardctl start` operation acquires the shared exclusion boundary, verifies prior terminal coherent handover or recovery evidence and coherent installed state, records distinct non-terminal start-attempt evidence, and verifies that the launchd job remains unloaded before changing eligibility.
The owner creates operation-bound one-shot authorization valid only for the current start identity, the current canonical lock owner, and one explicit bootstrap.
The same owner bootstraps the job, verifies the intended Node Agent instance started from coherent active state, and only then atomically marks the start attempt terminal coherent and enables durable eligibility for normal `RunAtLoad` and `KeepAlive` operation.
Failure or owner death before that atomic transition invalidates the one-shot authorization, keeps or restores suppression, and prevents a provisional Node Agent from continuing.
Publishing or loading a `RunAtLoad` and `KeepAlive` plist does not itself authorize Node Agent execution.
Missing, incomplete, or uncertain evidence leaves start eligibility suppressed.

## Failure And Managed Recovery

Failure to acquire or retain exclusion, prevent relaunch, prove exact exit, or prove absence occurs before active mutation and Node Agent start.
If relaunch prevention was established, a failed operation does not deliberately reverse it merely to restore automatic launch behavior.

After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app unconditionally attempts complete rollback of the prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
The app reports whether rollback completed successfully.
If required rollback cannot be completed or verified, the state is uncertain and the Node Agent remains stopped.
PKG gains no transactional rollback promise, and uncertain PKG activation or installed state also remains stopped.

Managed recovery reruns the applicable Orchard.app or PKG lifecycle under the same exclusion boundary.
A recovery owner may acquire the canonical lock despite missing, incomplete, or uncertain evidence and treats that evidence as recovery input rather than exclusion ownership.
It records or reconciles initial recovery evidence, establishes durable suppression before final process observation or protected reconciliation, proves every captured outgoing-instance exit or affirmative absence under suppression immediately before `bootout`, verifies or restores coherent installed state, and marks the handover or recovery evidence terminal coherent before permitting the applicable later managed start.
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
Durable recovery evidence and start-eligibility fencing are nevertheless required to survive reboot and deny unsafe launch, while the live kernel lock remains the sole exclusion owner and an available recovery owner may always acquire it.

### External Installer Wrapper

An `orchardctl` or installer wrapper could own the lock around `/usr/sbin/installer`, but direct installer invocation would bypass it.
A wrapper may remain a convenience but cannot be required for correctness.

### Long-Lived Coordinator Across Installer Phases

A coordinator spanning `preinstall`, Apple Installer payload placement, and `postinstall` could retain a live lock, but it lacks an authoritative transaction-lifetime signal if Installer aborts before `postinstall`.
Timeout release could race ongoing Installer mutation, while indefinite retention would create an availability failure.
This topology was rejected for the active payload interval.

### Inert Staging Plus One Postinstall-Owned Active Handover

The selected topology lets Apple Installer place authenticated and signed content into a root that the running Node Agent cannot use, then invokes one privileged owner to validate and bind one complete immutable or equivalently identity-stable generation in a unique namespace for the active activation interval.
It preserves direct installer support, one crash-released lock owner, zero active overlap, and a bounded recovery surface without introducing a lifetime lease or durable exclusion marker.
The trade-off is additional staging storage and an explicit activation helper or coordinator request after payload placement.

## Verification Strategy

Verification must exercise public Orchard.app, direct `/usr/sbin/installer`, `postinstall`-owned handover, managed recovery, and `orchardctl start` paths rather than only an isolated lock helper.
Coverage must prove that concurrent Orchard.app, PKG, recovery, and start attempts cannot cross the shared boundary.
Coverage must prove that `preinstall` leaves the active Node Agent and active lifecycle state unchanged and that the incoming staging root is never resolved, loaded, or executed by a running Node Agent.
Coverage must prove that one owner retains the same lock without transfer or descriptor inheritance through pre-`bootout` observation, captured-instance exit or proven absence, activation, protected mutation, start policy, and terminal reporting.
Coverage must exercise contention, owner crash, installer abort, repeated install, exact-instance ambiguity, unprovable absence, bounded timeout, activation uncertainty, and missing, incomplete, uncertain, or surviving evidence without treating evidence as ownership.
Coverage must prove initial evidence and suppression precede final process observation, non-reusable process-instance capture or affirmative absence occurs under suppression immediately before verified `bootout`, every captured-instance exit follows `bootout`, and protected plist mutation occurs only after the proof gate.
Coverage must cover an outgoing instance exiting and a `KeepAlive` replacement attempt around suppression, and must reject additional, replacement, or identity-unstable managed processes.
Coverage must prove activation uses a unique immutable or equivalently identity-stable generation, revalidates it immediately before atomic activation, and rejects partial, stale, mixed-generation, untrusted, ambiguous, replaced, modified, or missing staged content, including concurrent repeated-installer mutation attempts.
Coverage must prove suppression survives owner death, reboot, launchd domain reload, and `KeepAlive` retry, and that plist publication alone never authorizes launch.
Coverage must prove PKG never auto-starts after fresh install or upgrade and that later `orchardctl start` acquires the lock, records distinct start-attempt evidence, creates one crash-invalid operation-bound authorization, explicitly bootstraps and verifies the intended instance, and only then atomically records terminal coherent start evidence with durable enabled eligibility.
Coverage must exercise owner death and reboot after one-shot authorization but before bootstrap and after bootstrap but before the atomic terminal transition.
Coverage must prove Orchard.app always attempts full rollback after post-mutation failure, restores prior loaded state when rollback succeeds, and leaves the Node Agent stopped when rollback cannot be completed or verified.
Coverage must prove managed recovery is the only supported path from uncertainty to renewed start eligibility.
Coverage must confirm the BEAM Peer Grant Store Lock remains operation-scoped and rolling `N`/`N-1` safety uses serialized replacement.
