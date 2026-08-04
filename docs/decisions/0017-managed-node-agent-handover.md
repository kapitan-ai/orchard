# Managed Node Agent handover uses zero process overlap

## Status

Accepted.

Owner decision recorded 2026-08-04 for issue #158.

## Context

`SPEC.md` section 11.4 gives Orchard.app and PKG compatible installed paths, launchd labels, role values, and retained-state semantics, but before this decision it did not define their shared process-handover boundary.
`SPEC.md` sections 13.1 and 13.4 require Controller version `N` to support Node Agent versions `N` and `N-1` during rolling node upgrades.
That compatibility window does not make concurrent historical and replacement Node Agent processes safe when both can use one Node Identity Root.
The Node Identity Root contains the Node private key, Node Certificate, enrolled trust state, and stored BEAM Peer Grants, so concurrent access can cross identity, authorization, and lifecycle mutation boundaries.
ADR 0012 fixes per-Controller grant custody and atomic Node-local grant storage without establishing lifetime ownership of the Node Identity Root.
`Orchard.Node.BeamPeerGrantStore` holds its store lock only for one install or load operation, so that lock is not a lifecycle lock either.

## Decision

Managed Orchard.app and PKG Node Agent lifecycle mutations use one shared exclusion boundary.
Every Managed Node Agent Handover uses zero process overlap for the complete handover.
The lifecycle prevents launchd relaunch before requesting managed shutdown.
Before mutating the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root, the lifecycle proves either that the exact identified outgoing Node Agent process instance has exited or that no managed Node Agent instance is running.
Satisfaction of that same handover proof gate, through either branch, precedes replacement start.
The wait for exit proof is bounded.
Failure to acquire the shared exclusion boundary, prevent relaunch, or prove within the bound either that the identified outgoing instance exited or that no managed Node Agent instance is running fails closed without mutation or replacement start; affirmative proof of absence satisfies the gate, while ambiguous or unproven absence remains fail-closed.
If mutation or restoration state is uncertain, the lifecycle fails closed without automatically restarting the Node Agent.
Direct or manual Node Agent launches using the same Node Identity Root are unsupported and remain outside the managed handover guarantee.
Existing BEAM Peer Grant storage locks remain operation-scoped and do not become lifecycle locks.
The Controller `N` compatibility window for Node Agent versions `N` and `N-1` is made safe on each managed node through managed shutdown and serialized replacement, not live coexistence.

## Non-goals

Live overlap between outgoing and replacement Node Agent processes is not supported.
A lifetime Node Identity Root Lease is reserved for later work and is not introduced here.
Dual legacy and current lifecycle locks are not introduced.
Node Identity Root schema migration, root migration, or deletion is not introduced.
Automatic repair is not introduced.
Transactional PKG rollback is not introduced.
Automatic Node Agent restart after uncertain mutation is not introduced.

## Consequences

Managed Node Agent updates incur a bounded per-node interruption while exit is proven and replacement state is installed.
The existing Orchard.app receipt refusal and restoration obligations remain in force, while uncertain mutation fails closed without automatic Node Agent restart.
PKG delivery must honor the same exclusion and handover ordering without claiming transactional rollback.
Future work may define a Node Identity Root Lease, but it must not silently broaden the operation-scoped BEAM Peer Grant storage locks.

## SPEC.md impact

`SPEC.md` sections 11.4 and 13.4 now define the managed zero-overlap boundary, the handover gate satisfied by exact outgoing-process exit proof or proven absence of any managed Node Agent instance, bounded fail-closed behavior, and historical-version serialization.
