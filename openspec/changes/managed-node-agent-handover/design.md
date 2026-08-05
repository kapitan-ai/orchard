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

- Define one crash-released exclusion boundary used by owner-side managed Orchard.app, PKG, recovery, and Node Agent start-attempt paths, and keep the child-side managed launch gate outside it.
- Establish zero managed process overlap across every active handover.
- Make PKG delivery stage one complete authenticated and signed generation inertly before one postinstall-invoked owner performs active activation.
- Establish durable suppression before final process observation, then capture stable non-reusable exact outgoing-process evidence or affirmatively prove absence immediately before `bootout` and require every captured-instance exit before active mutation or start.
- Require durable handover, recovery, and start-attempt evidence with terminal coherent marking only after the applicable verification.
- Preserve PKG manual start through reboot-safe Node Agent suppression, combining persistent launchd job-domain disablement with launch-gate denial, and crash-invalid one-shot authorization beneath launchd `RunAtLoad` and `KeepAlive`.
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

`SPEC.md` §11.2, §11.4, and §13.4 hold the normative contract and ADR 0017 holds the decision kernel.
The sections below cover only the mechanics, state model, risks, and verification those documents imply.

## Lifecycle State Model

Five dimensions are observed and mutated independently. Conflating any two of them is the main source of unreachable or unsafe transitions.

| Dimension | Values | Changed by |
|---|---|---|
| Launchd plist presence | present, absent | payload activation during install, upgrade, or uninstall |
| Launchd job load state | loaded, unloaded | job-domain control by the lock-holding owner, and by launchd itself at boot and domain reload |
| Managed Node Agent process | running, proven absent, unknown | observation under suppression immediately before `bootout` |
| Start eligibility | `suppressed`, `one_shot_pending`, `enabled` | owner-side start attempts and handover suppression only |
| Canonical lock ownership | held by one owner, free | acquisition, descriptor close, owner death |

macOS bootstraps plists in `/Library/LaunchDaemons` at boot, so publishing a plist cannot leave load state durably false.
Durable suppression therefore has two parts: persistent launchd job-domain disablement, which keeps a suppressed Node Agent job from bootstrapping at reboot or domain reload, and child-side launch-gate denial as defense in depth if something bootstraps it anyway.
For the same reason a start attempt cannot treat an unloaded job as a precondition it merely checks; it verifies or establishes that state while holding the lock.
An `unknown` process observation is never coerced into `proven absent`.
Eligibility, one-shot authorization, and the managed launch gate apply only to the Node Agent; other role-selected services are simply left stopped by PKG and use normal launchd start behavior.

## Shared Exclusion Boundary

The canonical boundary is one interoperable exclusive kernel advisory lock on `/Library/Application Support/Orchard/support/.app-lifecycle.lock`.
Owner-side paths contend on it: managed Orchard.app and PKG lifecycle operations that can hand over or mutate the Node Agent, managed recovery, and start attempts including Orchard.app restoration and `orchardctl start`.
Ownership cannot transfer between `preinstall`, Apple Installer, `postinstall`, a helper, or any child process, so the owner must also prevent descriptor inheritance by subprocesses and by the replacement service.
Normal completion closes the descriptor, owner death releases through the operating system, contention performs no managed mutation and starts no Node Agent, and a later operation retries once ownership is free.

The child-side managed launch gate is deliberately outside this boundary.
It runs inside the launched Node Agent service while its own start owner still holds the lock, so acquiring or waiting on that lock would deadlock the very start it gates.
The gate therefore only reads durable eligibility and atomically consumes a matching single-consumer one-shot authorization: no lock, no inherited descriptor, no replay of a consumed authorization, and no durable enablement of its own.

Durable evidence is what survives owner death, and it must also survive reboot.
It is recovery input and launch fencing only.
It can deny a start, but it can never confer exclusion ownership and must never block a recovery owner from acquiring the kernel lock; otherwise one crashed owner would leave the host permanently unrecoverable.
The BEAM Peer Grant Store Lock remains scoped to one `Orchard.Node.BeamPeerGrantStore` install or load operation, including atomic publication when installing, and is not reused or broadened for lifecycle exclusion.

## PKG Stage-Then-Activate Topology

Apple Installer runs `preinstall`, places payload, and runs `postinstall` as separate processes, so no package script can hold one descriptor across active payload replacement.
The topology works around that by keeping Installer's writes inert: authenticated and signed content goes only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute, which is not active mutation and needs no lock.
`preinstall` is limited to non-active preflight and staging preparation; it does not stop the Node Agent, prevent relaunch, or touch active payload, launchd records, command links, role state, or the Node Identity Root.
`postinstall` then synchronously invokes one privileged handover owner that acquires the canonical lock, performs the entire active handover, and returns a terminal result.
Because the package invokes that owner itself, direct `/usr/sbin/installer -pkg ... -target /` stays supported with no external Orchard wrapper.

Activation binds to exactly one complete generation in a unique per-generation namespace, verified for identity, completeness, integrity, trust, and intended target, and immutable or equivalently identity-stable through atomic activation so concurrent or repeated installers cannot swap it underneath the owner.
Binding alone is not enough against a racing installer, so the owner fully revalidates the bound pathname or descriptor identity, manifest, signature, file set, content integrity, trust, and target immediately before activation.
Initially invalid content fails before any protected active mutation; a mismatch found at revalidation fails before payload or installed-state activation and leaves start suppressed for recovery.

## Active Handover Ordering

After active preflight succeeds and while one owner retains the shared exclusion boundary, the handover follows this ordering:

1. For PKG, validate and bind exactly one complete authenticated and signed staging generation in an immutable or equivalently identity-stable unique namespace before relaunch prevention or active mutation.
2. Durably record the required operation identity, phase, staging generation when applicable, prior active path and start policy as needed, and intended mutation before changing start eligibility or any other protected active state.
3. Establish protected durable start suppression: set eligibility to `suppressed`, invalidate any outstanding one-shot authorization, and apply persistent launchd job-domain disablement.
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
The protected Managed Node Agent Start Eligibility State must be enforced by the child-side managed launch path before Node Agent execution and survive owner death, reboot, launchd domain reload, and `KeepAlive` retry.
The concrete process identity representation, helper language, executable location, incoming staging pathname, job-domain disablement mechanism, one-shot authorization representation, and durable evidence schema remain implementation choices subject to those proofs.

## Start Attempt Ordering

A managed start attempt is a separate operation from the handover that preceded it, with its own identity and evidence record. While holding the canonical lock:

1. Verify prior terminal coherent handover or recovery evidence and coherent installed state; leave suppression in place and stop here if either is missing, incomplete, uncertain, or non-terminal.
2. Record distinct non-terminal start-attempt evidence.
3. With eligibility still `suppressed`, verify or establish the unloaded, not-running precondition: `bootout` a loaded job and prove it unloaded with no managed Node Agent process running; continue if the job is already unloaded with no managed process; otherwise fail closed with suppression retained.
4. Lift persistent job-domain disablement for exactly one explicit bootstrap, create operation-bound single-consumer one-shot authorization bound to this start identity, this lock owner, and that bootstrap, and record eligibility as `one_shot_pending`.
5. Bootstrap the job while retaining the lock; the child-side gate consumes the authorization exactly once and starts only the intended instance.
6. Verify that exact instance, then atomically mark the start attempt terminal coherent and enable durable eligibility for normal `RunAtLoad` and `KeepAlive` operation.

Step 3 exists because launchd, not Orchard, decides load state at boot and domain reload, so a start attempt after reboot would otherwise face a permanently unsatisfiable precondition.
Steps 4 through 6 are the crash fence: any failure or owner death before the atomic transition in step 6 invalidates the authorization and keeps or restores suppression with job-domain disablement, so no provisional Node Agent survives and no later `KeepAlive` retry, reload, or reboot can consume the interrupted authorization.

Orchard.app may restore previously loaded services still selected by the resulting role through this same protocol after coherent success or successful required rollback.
PKG never auto-starts and never restores prior loaded-service state, leaving `orchardctl start` as the supported later path.

## Failure And Managed Recovery

Every failure to acquire or retain exclusion, prevent relaunch, prove exact exit, or prove absence lands before active mutation and before any Node Agent start.
An established relaunch-prevention state is not deliberately reversed just to restore automatic launch behavior after such a failure.

Orchard.app unconditionally attempts complete rollback after any post-mutation failure and reports rollback success separately from the triggering failure; PKG gains no transactional rollback promise.
Either way, state that cannot be completed or verified is uncertain, and uncertain state stays stopped.

Managed recovery is the only supported route from uncertainty back to start eligibility.
It reruns the applicable Orchard.app or PKG lifecycle under the same boundary, and it must be able to acquire the lock even when evidence is missing, incomplete, or uncertain — otherwise the fencing that protects against a crashed owner would itself become the permanent failure.
Recovery records or reconciles initial evidence, reestablishes suppression before final process observation or protected reconciliation, proves every captured outgoing-instance exit or affirmative absence under suppression immediately before `bootout`, verifies or restores coherent installed state, and marks evidence terminal coherent before any later managed start.
Blind `launchctl` kickstart, direct binary launch, and manual same-root start during uncertainty remain unsupported and outside the zero-overlap guarantee, as do any direct launches that bypass the managed launch gate and owner-side start-attempt paths.

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
Coverage must prove suppression survives owner death, reboot, launchd domain reload, and `KeepAlive` retry through both persistent job-domain disablement and launch-gate denial, and that plist publication alone never authorizes launch.
Coverage must prove the child-side launch gate acquires, waits on, and inherits no canonical lock descriptor, succeeds while its own start owner holds the lock, denies a suppressed state or an absent authorization, refuses to replay a consumed authorization, and never enables durable eligibility itself.
Coverage must prove a start attempt after a reboot or job-domain reload that left the suppressed job loaded verifies or establishes an unloaded job with no managed Node Agent process before authorizing, and fails closed when it can prove neither.
Coverage must prove a second start attempt during an in-flight one contends on the lock without creating authorization or mutating eligibility.
Coverage must prove eligibility, one-shot authorization, and the launch gate apply only to the Node Agent and that other role-selected services use normal supported launchd start behavior.
Coverage must prove PKG never auto-starts after fresh install or upgrade and that later `orchardctl start` acquires the lock, records distinct start-attempt evidence, creates one crash-invalid operation-bound authorization, explicitly bootstraps and verifies the intended instance, and only then atomically records terminal coherent start evidence with durable enabled eligibility.
Coverage must exercise owner death and reboot after one-shot authorization but before bootstrap and after bootstrap but before the atomic terminal transition.
Coverage must prove Orchard.app always attempts full rollback after post-mutation failure, restores prior loaded state when rollback succeeds, and leaves the Node Agent stopped when rollback cannot be completed or verified.
Coverage must prove managed recovery is the only supported path from uncertainty to renewed start eligibility.
Coverage must confirm the BEAM Peer Grant Store Lock remains operation-scoped and rolling `N`/`N-1` safety uses serialized replacement.
