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

Orchard adopts zero-overlap Managed Node Agent Handover: inert signed PKG staging followed by one privileged activation owner that holds a crash-released kernel advisory lock continuously through the active interval.
`SPEC.md` §11.2, §11.4, and §13.4 hold the normative protocol, ordering, proof obligations, and fail-closed rules.
This record fixes only the decision kernel and why each part was chosen over the alternatives below.

1. **One shared exclusion boundary over one protocol.** Every owner-side managed Orchard.app, PKG, recovery, start, and stop path — `orchardctl stop` included — contends on one interoperable exclusive kernel advisory lock at `/Library/Application Support/Orchard/support/.app-lifecycle.lock`. Ownership is never transferred or inherited; normal completion closes the descriptor and owner death releases it through the operating system, so no owner can leave stale exclusion behind. Eligibility is the authoritative fence and launchd load state is only operational control, so no supported path can stop or start the Node Agent outside the protocol and leave the fence stale.
2. **Zero process overlap, enforced by one shared process fence.** One owner holds that lock continuously from initial durable evidence and start suppression, through immediate pre-`bootout` capture of the exact outgoing instance or proven absence and every captured-instance exit, through activation and protected mutation, to terminal reporting. Because handover, managed stop, start-precondition establishment, and recovery all shut the same job down, that ordering is a single Managed Node Agent Process Fence they each satisfy rather than four restatements that can drift: observe under suppression immediately before shutdown, capture the exact stable instance or record affirmative absence, reject additional, replacement, unstable, or unknown state, then prove unload and every captured exit. A look taken after shutdown never becomes pre-shutdown absence. An outgoing Node Agent and its replacement never share the Node Identity Root, so protocol compatibility never has to carry concurrent identity-state safety.
3. **Inert staging, then one `postinstall`-owned activation.** Apple Installer writes authenticated signed payload only into an inactive incoming staging root, `preinstall` leaves the running Node Agent and active state untouched, and `postinstall` synchronously invokes the single active-handover owner. Because the package invokes that owner itself, direct `/usr/sbin/installer -pkg ... -target /` stays safe with no external Orchard wrapper, which no lock-holding-script topology could offer across Installer's separate script processes.
4. **Evidence fences launch but never owns exclusion.** One shared durable schema covers all four owner-side operation kinds — `handover`, `managed_recovery`, `start_attempt`, `managed_stop` — so no path can be unclassified and silently exempt from recording before it mutates. Records gate later launch eligibility across owner death and reboot. Denial is scoped to the kind an operation actually requires, so a terminal coherent stopped record never blocks a later start; a stop needs no prior coherent evidence because it only moves toward the fail-closed state; and an interrupted non-terminal record is a reconciliation obligation the next lock-holding owner supersedes in its own initial evidence, not a trigger for full payload recovery. Missing, incomplete, or uncertain evidence denies start only; it never confers exclusion ownership and never blocks a recovery owner from acquiring the lock, so the system cannot deadlock on its own metadata.
5. **Owner-side authorization is split from the child-side launch gate.** Owner-side paths hold the lock while inspecting or mutating eligibility, job-domain disablement, and one-shot authorization. The managed launch gate runs inside the launched service, takes no lock and inherits no descriptor, and decides per state: `enabled` permits normal operation, `suppressed` denies, `one_shot_pending` permits only an atomic claim of a matching authorization. Without that split the gate would contend for a lock its own start owner is holding and no managed start could complete.
6. **Matching is observable without the lock, and one atomic commit is the serving linearization point.** Because the gate is barred from the lock, the crash fence cannot rest on owner liveness inferred from it. The authorization therefore carries components the gate can check directly — attempt identity, exact non-reusable owner process identity, per-bootstrap nonce, launchd label, expected generation and executable identity, eligibility generation, claim state — and requires the recorded owner instance to be observably live. A claimed child records its own exact identity and runs provisional: no cluster identity, no serving. The owner's single atomic commit of terminal coherent plus `enabled` plus acceptance bound to that exact child is the only point at which it may serve, so observed owner loss triggers a fresh authoritative read rather than an immediate exit — otherwise the normal path, where the owner exits right after committing, would race every time. Incomplete, torn, or stale state is non-acceptance. This is what makes a mid-attempt owner death safe with no live actor to re-apply disablement; owner death after the commit is ordinary and leaves the instance valid.
7. **Suppression is Node Agent-only and reboot-durable.** Durable suppression pairs persistent launchd job-domain disablement with launch-gate denial beneath `RunAtLoad` and `KeepAlive`, so a suppressed job neither bootstraps at reboot nor executes if bootstrapped anyway. Other role-selected services are simply left stopped by PKG and use normal launchd start behavior; no eligibility fencing is invented for them.
8. **A start attempt is defined only from `suppressed`, and every entry state has a path.** A managed stop always lands the system back in `suppressed` with disablement applied, so the routine stop-then-start cycle is well defined. A start request on `enabled` with one verified healthy exact instance is an idempotent success rather than a new attempt; any other `enabled` combination, and any `one_shot_pending` not owned by the exact live recorded owner, normalizes through managed recovery to `suppressed` before a distinct attempt runs. From `suppressed` the precondition is total over both independent dimensions — nothing is minted or bootstrapped until the job is proven unloaded **and** the managed process proven absent — because an earlier stop or handover whose exit proof failed can leave an unloaded job with a live orphan, and bootstrapping there would put a second Node Agent on the live Node Identity Root.
9. **Path-specific start policy.** PKG never auto-starts and never restores prior loaded state, leaving `orchardctl start` as the supported later path. Orchard.app may restore prior loaded-service state only through the same managed start-attempt protocol, after coherent success or verified rollback; unverifiable rollback is uncertain and stays stopped.
10. **The BEAM Peer Grant Store Lock stays operation-scoped.** It serializes one `Orchard.Node.BeamPeerGrantStore` install or load operation, including atomic publication, and never becomes lifecycle exclusion or a Node Identity Root Lease.

## Rejected alternatives

**Live historical and replacement overlap.** Running Node Agent `N-1` and `N` concurrently was rejected because §13.1 protocol compatibility does not establish safe concurrent ownership of one Node Identity Root; it would require a materially broader identity-state concurrency protocol.

**A lifetime Node Identity Root Lease.** A process-lifetime lease was deferred because it adds runtime ownership, renewal, fencing, and recovery semantics beyond this decision. The handover needs lifecycle exclusion, not a new permanent runtime lease.

**Separate Orchard.app and PKG locks.** Independent per-path ownership cannot exclude cross-path races; all managed paths must contend on one canonical lock and protocol.

**A durable lock marker or session fence as ownership.** Rejected because owner death turns a durable marker into stale state with unsafe reclamation questions. Durable evidence is still required, but only as recovery input and launch fencing while the live kernel lock remains the sole exclusion owner.

**An external installer wrapper.** A wrapper could hold the lock around `/usr/sbin/installer`, but direct installer invocation would bypass it. A wrapper may remain a convenience and cannot be required for correctness.

**A coordinator spanning the whole installer transaction.** A process holding the lock across `preinstall`, payload placement, and `postinstall` has no authoritative transaction-lifetime signal when Installer aborts early: timeout release races ongoing Installer mutation, and indefinite retention becomes an availability failure.

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

`SPEC.md` sections 11.2, 11.4, and 13.4 define the orthogonal lifecycle state model, reboot-safe Node Agent start suppression through persistent launchd job-domain disablement beneath `RunAtLoad` and `KeepAlive`, the owner-side and child-side split of the exclusion boundary, the shared Managed Node Agent Process Fence, the lock-held managed stop protocol, per-entry-state start dispatch, the total start precondition over load and process state, the observable one-shot matching predicate, the provisional child phase and its atomic acceptance linearization point, authenticated single-generation PKG activation, the single-owner crash-released lock, required durable recovery evidence, manual PKG start, unconditional Orchard.app rollback, managed recovery, and historical-version serialization.
