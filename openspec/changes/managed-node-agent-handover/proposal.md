## Why

`SPEC.md` §11.4 and §13.4 and ADR 0017 establish the owner-approved zero-overlap contract for managed Node Agent replacement.
Orchard.app and PKG both manage the same launchd service, installed state, and Node Identity Root, so their lifecycle operations need one collaborator-reviewable change package before implementation begins.
Without a shared handover boundary, an outgoing and replacement Node Agent could overlap on one identity-bearing root even though Controller `N` supports Node Agent versions `N` and `N-1`.

## What Changes

- Define one Managed Node Agent Handover contract shared by managed Orchard.app and PKG lifecycle operations.
- Require the lifecycle to prevent relaunch, identify the exact outgoing Node Agent process instance, and prove that instance exited before mutating the Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root.
- Require bounded waiting and fail-closed behavior when exclusion, relaunch prevention, process identification, exit proof, mutation, or restoration cannot be established safely.
- Permit replacement start only after exit proof succeeds and required managed mutation completes.
- Preserve direct or manual same-root launches as unsupported, BEAM Peer Grant locks as operation-scoped, and Controller `N`/Node Agent `N-1` safety through managed shutdown rather than live coexistence.
- Record future implementation and verification work without changing product code, tests, scripts, dependencies, generated files, or release notes in this change.

## Capabilities

### New Capabilities

- `managed-node-agent-handover`: Defines the shared exclusion boundary, exact outgoing-process exit proof, zero-overlap ordering, bounded fail-closed behavior, and guarantee limits for managed Node Agent lifecycle replacement.

### Modified Capabilities

- `app-distribution-lifecycle`: Requires managed Orchard.app Node Agent lifecycle operations to use the shared handover contract while preserving the existing app restoration obligations.
- `packaging-deployment`: Requires PKG Node Agent lifecycle operations to use the same shared handover contract without claiming transactional PKG rollback.

## Impact

- SPEC.md impact: the preserved draft updates §11.4 and §13.4 with the managed zero-overlap boundary and historical-version serialization.
- Domain impact: the preserved glossary defines Node Identity Root, Managed Node Agent Handover, and the reserved future Node Identity Root Lease term.
- Decision impact: ADR 0017 records the accepted owner decision and its explicit non-goals.
- Packaging impact: future Orchard.app and PKG implementation must share lifecycle exclusion and handover ordering across their current service-management paths.
- Availability impact: a managed node incurs a bounded interruption during shutdown proof and replacement; an unproven or uncertain state remains stopped rather than risking overlap.
- Security impact: the handover protects identity-bearing Node state from concurrent managed process use; it does not broaden BEAM Peer Grant storage locks into lifecycle locks.
