## Context

`SPEC.md` §11.4 requires Orchard.app and PKG to remain compatible managed lifecycle paths for the same installed roles, paths, launchd labels, and retained state.
`SPEC.md` §13.1 requires Controller version `N` to support Node Agent versions `N` and `N-1`, while §13.4 now makes that historical compatibility safe through Managed Node Agent Handover rather than simultaneous access to one Node Identity Root.
ADR 0017 records the owner-approved decision and is not reopened by this change.

The Node Identity Root contains the Node private key, Node Certificate, enrolled trust state, and stored BEAM Peer Grants.
An outgoing Node Agent and its replacement must not overlap while using that identity-bearing state.
The existing BEAM Peer Grant storage locks serialize individual store operations only; they do not establish lifecycle ownership of the root.

Orchard.app already has transactional restoration obligations.
PKG remains a parallel privileged installer but does not promise transactional rollback.
The paths therefore share handover exclusion and ordering without pretending their broader failure-recovery semantics are identical.

## Goals

- Define one exclusion boundary used by managed Orchard.app and PKG Node Agent lifecycle operations.
- Establish zero managed process overlap across the complete handover.
- Require proven exit of the exact outgoing process instance, or proven absence of any managed Node Agent instance, before relevant mutation or replacement start.
- Bound the exit wait and fail closed when safety cannot be proven.
- Preserve app restoration, PKG compatibility, and historical Node Agent support without broadening this change.

## Non-Goals

- Live overlap between outgoing and replacement Node Agent processes.
- A lifetime Node Identity Root Lease.
- Dual legacy and current lifecycle locks.
- Node Identity Root schema migration, root migration, or deletion.
- Automatic repair.
- Transactional PKG rollback.
- Automatic Node Agent restart after uncertain mutation.
- Support for direct or manual Node Agent launches that use the same Node Identity Root.

## Shared Exclusion Boundary

Every managed Orchard.app or PKG lifecycle operation that can hand over or mutate the Node Agent acquires the same lifecycle exclusion boundary before entering its managed shutdown and mutation sequence.
The boundary excludes the other managed path for the complete handover, including shutdown proof, managed mutation, and the replacement-start decision.
Failure to acquire or retain the boundary fails closed without managed mutation or replacement start.

The exclusion boundary is a lifecycle primitive distinct from the existing BEAM Peer Grant storage locks.
Those storage locks remain scoped to individual Peer Grant operations and must not be reused or silently broadened into lifetime Node Identity Root ownership.
A possible Node Identity Root Lease remains reserved for future work.

## Handover Ordering

After successful preflight and while holding the shared exclusion boundary, a managed handover follows this ordering:

1. Prevent launchd from relaunching the managed Node Agent.
2. Identify the exact outgoing Node Agent process instance, or affirmatively prove that no managed Node Agent instance is running.
3. When an outgoing instance was identified, request managed shutdown and wait for proof that the identified instance exited.
4. Fail closed if neither exact-instance exit nor absence of any managed Node Agent instance is proven within the bounded wait.
5. Only after the handover gate is satisfied through either proof branch, mutate the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root as required by the lifecycle operation.
6. Start the replacement only after the handover gate was satisfied and required mutation completed.
7. Release the shared exclusion boundary only after the operation reaches a safe terminal state.

The implementation must use process-instance evidence strong enough to distinguish the captured outgoing instance from a later or unrelated process, and absence evidence strong enough to distinguish a proven-absent managed Node Agent from one it merely failed to observe.
This design does not select the concrete macOS process-identity representation; implementation and tests must demonstrate that the proof applies to the exact outgoing instance rather than only a reusable numeric process identifier or service label, and that ambiguous absence is treated as an unproven exit.

## Failure Semantics

Failure to prevent relaunch, or to prove within the bound either that the exact identified outgoing instance exited or that no managed Node Agent instance is running, occurs before managed mutation and replacement start.
The lifecycle returns failure without starting a replacement; when relaunch prevention was established, it remains in the fail-closed state rather than being deliberately reversed by the failed operation.

After mutation begins, Orchard.app retains its existing obligation to restore the prior app-owned payload, command links, launchd plists, role marker, and loaded-service state when restoration can be established safely.
If mutation or restoration state is uncertain, both Orchard.app and PKG fail closed and do not automatically restart the Node Agent.
The PKG path must honor the same exclusion and ordering but gains no transactional rollback promise from this change.

## Guarantee Boundary

The zero-overlap guarantee covers managed Orchard.app and PKG lifecycle operations using their shared exclusion boundary.
Direct or manual Node Agent launches using the same Node Identity Root remain unsupported and outside the guarantee.
This change does not introduce a second mechanism to coordinate unsupported launches.

Controller `N` compatibility with Node Agent versions `N` and `N-1` supports rolling managed upgrades across nodes.
On each managed node, safety comes from shutting down and proving exit of the historical process before starting its replacement, not from running both versions concurrently.

## Verification Strategy

Future verification should exercise the public managed lifecycle paths rather than only an isolated lock helper.
Coverage must show that concurrent Orchard.app and PKG attempts cannot cross the shared boundary; launchd relaunch is disabled before shutdown; exact-instance exit proof or proven absence of any managed Node Agent instance gates every listed mutation and replacement start; bounded timeout, ambiguous evidence, and ambiguous absence leave state unmutated and stopped; uncertain post-mutation state does not trigger automatic restart; and the app restoration contract remains intact when restoration is proven.

Cross-path acceptance must also preserve the unsupported status of direct/manual same-root launches, the operation scope of BEAM Peer Grant storage locks, and rolling `N`/`N-1` safety through serialized managed replacement.
