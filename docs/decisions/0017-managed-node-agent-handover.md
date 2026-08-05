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

One privileged handover owner acquires the canonical lock and retains the same kernel lock ownership continuously, without transfer or descriptor inheritance, from before initial operation evidence and durable suppression through immediate pre-`bootout` observation, every captured-instance exit or affirmative absence, active activation and protected mutation, the applicable start decision, and terminal reporting.
Normal completion closes the owning descriptor.
Owner process death releases the lock through the operating system.
Contention performs no managed mutation or Node Agent start, and a later managed operation may retry after ownership is released.
Before changing managed start eligibility or any other protected active state, the owner durably records required handover or recovery evidence containing the operation identity and phase, the bound staging generation when applicable, prior active path and start policy as needed, and the intended mutation.
A no-start handover or recovery becomes terminal coherent only after installed-state verification, while any later managed start uses a distinct start-attempt identity and evidence record.
Missing, incomplete, or uncertain evidence denies start but never constitutes exclusion ownership or prevents a recovery owner from acquiring the canonical kernel lock.
Persistent metadata is recovery evidence and start-eligibility fencing, not exclusion ownership.

PKG uses stage-then-activate.
Apple Installer places authenticated and signed payload only into an inactive incoming staging root that a running Node Agent cannot resolve, load, or execute.
Before relaunch prevention or active mutation, the owner binds activation to one complete authenticated and signed staging generation in a unique namespace that concurrent or repeated installers cannot modify.
The bound generation remains immutable or equivalently identity-stable through atomic activation and is fully revalidated immediately before activation.
Initial invalidity fails before protected active lifecycle mutation, while any pre-activation identity mismatch fails before payload or installed-state activation and leaves start suppressed for recovery.
PKG `preinstall` does not stop the active Node Agent, prevent relaunch, or mutate active payload, launchd records, command links, role state, or the Node Identity Root.
After inert staging, PKG `postinstall` synchronously invokes one privileged handover owner for the complete active handover.
The package itself invokes that owner, so direct `/usr/sbin/installer -pkg ... -target /` remains safe without an external wrapper.

While retaining the shared lock, the owner first durably records initial operation evidence and establishes protected durable start suppression.
Under that suppression and immediately before `bootout`, the owner either captures non-reusable evidence for exactly one running outgoing instance and records it durably, or affirmatively proves no managed instance exists.
The captured identity must remain stable through `bootout`, and an additional, replacement, or identity-unstable process fails the gate.
The owner then prevents relaunch with verified launchd job-domain control such as `bootout` followed by proof that the job is unloaded.
Relaunch prevention does not mutate or delete the protected plist before the handover gate.
When an outgoing instance was captured, the owner waits for proof that every captured managed instance exited after managed shutdown.
Only captured-instance exit or affirmative absence proven under suppression immediately before `bootout` satisfies the gate, and an observation failure before `bootout` cannot become proven absence afterward.
The wait is bounded.
Failure to acquire or retain exclusion, validate and identity-stabilize applicable staging, record evidence, establish suppression, capture stable exact process evidence, prevent relaunch, prove every captured exit, or prove immediate pre-`bootout` absence fails closed without active mutation or Node Agent start.
Only after the gate succeeds may the owner activate the bound staged generation or mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.

Orchard.app may restore the prior loaded-service state after a coherent successful operation for services still selected by the installed role only through the managed start-attempt protocol.
After any post-mutation failure in app-owned install, update, or uninstall, Orchard.app always attempts complete rollback of prior app-owned payload, command links, launchd plists, role marker, and loaded-service state.
If required rollback cannot be completed or verified, the state is uncertain and the Node Agent remains stopped.

PKG never automatically starts role-selected services and never restores their prior loaded-service state after either fresh install or upgrade.
PKG leaves the protected Managed Node Agent Start Eligibility State suppressed even when the replacement plist uses `RunAtLoad` and `KeepAlive`.
Publishing or loading that plist cannot make the Node Agent launch-eligible.
The supported later PKG start path is `orchardctl start`.
Every Orchard.app restoration or `orchardctl start` operation acquires the shared exclusion boundary, verifies prior terminal coherent handover or recovery evidence and installed state, records distinct non-terminal start-attempt evidence, verifies the job remains unloaded, and creates one operation-bound one-shot authorization for the current lock owner and explicit bootstrap.
The same owner bootstraps and verifies the intended instance, then atomically marks the start attempt terminal coherent and enables durable eligibility for normal `RunAtLoad` and `KeepAlive` operation.
Failure or owner death before that atomic transition invalidates the one-shot authorization, keeps or restores suppression, and prevents a provisional Node Agent from continuing.
The managed launch gate enforces suppression across owner death, reboot, launchd domain reload, and `KeepAlive` retry.

Managed recovery reruns the applicable Orchard.app or PKG lifecycle while holding the same exclusion boundary.
A recovery owner may acquire the canonical lock despite missing, incomplete, or uncertain evidence and treats that evidence as recovery input rather than lock ownership.
It may permit a later managed start only after establishing suppression before final process observation, proving every captured outgoing-instance exit or affirmative absence under suppression immediately before `bootout`, verifying or restoring coherent installed state, and marking the handover or recovery evidence terminal coherent.
Blind or manual same-root launch while uncertainty remains is unsupported.
Direct or manual Node Agent launches that bypass the supported managed launch and start-eligibility path remain unsupported and outside the managed handover guarantee.

The BEAM Peer Grant Store Lock remains operation-scoped and does not become a lifecycle lock, Managed Node Agent Handover exclusion, or Node Identity Root Lease.
The Controller `N` compatibility window for Node Agent versions `N` and `N-1` is made safe on each managed node through managed shutdown and serialized replacement, not live coexistence.

## Non-goals

Live overlap between outgoing and replacement Node Agent processes is not supported.
A lifetime Node Identity Root Lease is not introduced.
Separate app and PKG lifecycle locks are not introduced.
A durable lock marker or session fence is not introduced as exclusion ownership, although durable recovery evidence and start-eligibility fencing are required.
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
A crashed owner cannot leave kernel lock ownership stale, and durable start suppression or crash-invalid one-shot authorization keeps any state left uncertain by that crash fail-closed across reboot and launchd retries until managed recovery proves coherence.
Future work may define a lifetime Node Identity Root Lease, but it must not silently broaden the BEAM Peer Grant Store Lock or replace the canonical handover boundary.

## SPEC.md impact

`SPEC.md` sections 11.2, 11.4, and 13.4 define reboot-safe start suppression beneath `RunAtLoad` and `KeepAlive`, authenticated single-generation PKG activation, the single-owner crash-released exclusion boundary, pre-`bootout` process capture, required durable recovery evidence, manual PKG start, unconditional Orchard.app rollback, managed recovery, and historical-version serialization.
