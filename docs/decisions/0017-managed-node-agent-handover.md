# Managed Node Agent handover uses zero process overlap

## Status

Accepted.

Owner decision recorded 2026-08-04 for issue #158.

## Context

`SPEC.md` section 11.4 gives Orchard.app and PKG compatible installed paths, launchd labels, role values, and retained-state semantics, but it does not yet define their shared process-handover boundary.
`SPEC.md` sections 13.1 and 13.4 require Controller version `N` to support Node Agent versions `N` and `N-1` during rolling node upgrades.
That compatibility window does not make concurrent historical and replacement Node Agent processes safe when both can use one Node Identity Root.
The Node Identity Root contains the Node private key, Node Certificate, enrolled trust state, and stored BEAM Peer Grants, so concurrent access can cross identity, authorization, and lifecycle mutation boundaries.
ADR 0012 keeps BEAM Peer Grant storage locks scoped to individual store operations and does not establish lifetime ownership of the Node Identity Root.

## Decision

Managed Orchard.app and PKG Node Agent lifecycle mutations use one shared exclusion boundary.
Every Managed Node Agent Handover uses zero process overlap for the complete handover.
The lifecycle prevents launchd relaunch before requesting managed shutdown.
The lifecycle identifies the exact outgoing Node Agent process instance and proves that instance has exited before mutating the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
The same exit proof precedes replacement start.
The wait for exit proof is bounded.
Failure to acquire the shared exclusion boundary, prevent relaunch, identify the outgoing instance, or prove exit within the bound fails closed without mutation or replacement start.
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

`SPEC.md` sections 11.4 and 13.4 now define the managed zero-overlap boundary, exact outgoing-process exit proof, bounded fail-closed behavior, and historical-version serialization.
