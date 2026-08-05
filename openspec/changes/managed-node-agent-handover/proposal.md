## Why

`SPEC.md` §11.4 and §13.4 and ADR 0017 establish the zero-overlap contract for managed Node Agent replacement.
Orchard.app and PKG both manage the same launchd service, installed state, and Node Identity Root, so active handover needs one shared exclusion and recovery contract.
Without that contract, outgoing and replacement Node Agent processes could overlap on identity-bearing state even though Controller `N` supports Node Agent versions `N` and `N-1`.
Apple Installer also separates package scripts from payload placement, so PKG needs inert staging before one continuously owned active handover.

## What Changes

- Define one canonical crash-released Managed Lifecycle Exclusion Boundary shared by Orchard.app, PKG, managed recovery, and Node Agent start eligibility paths.
- Require one privileged owner to retain the same kernel advisory lock continuously, without ownership transfer or descriptor inheritance, through relaunch prevention, exact exit or proven absence, active mutation, start policy, and terminal reporting.
- Require PKG to stage signed payload only in an inactive incoming root, keep `preinstall` from stopping or mutating the active Node Agent installation, and have `postinstall` synchronously invoke the active handover owner.
- Preserve direct `/usr/sbin/installer` support without an external wrapper.
- Preserve manual `orchardctl start` after every successful PKG fresh install and upgrade, with no PKG automatic start or prior-loaded-state restoration.
- Preserve Orchard.app's unconditional full rollback attempt after post-mutation failure and classify incomplete or unverifiable rollback as uncertain and stopped.
- Define managed recovery under the same exclusion boundary before a later start can be reauthorized.
- Define launchd relaunch prevention as verified job-domain control rather than protected plist mutation.
- Define the BEAM Peer Grant Store Lock as operation-scoped and distinct from lifecycle exclusion.
- Preserve Controller `N` and Node Agent `N-1` safety through managed shutdown rather than live coexistence.

## Capabilities

### New Capabilities

- `managed-node-agent-handover`: Defines inert PKG staging, the single-owner exclusion boundary, exact outgoing-process exit proof, zero-overlap ordering, path-specific start policy, managed recovery, fail-closed behavior, and guarantee limits.

### Modified Capabilities

- `app-distribution-lifecycle`: Requires managed Orchard.app Node Agent lifecycle operations to use the shared handover contract while preserving unconditional rollback and prior-loaded-state restoration obligations.
- `packaging-deployment`: Requires stage-then-activate PKG Node Agent lifecycle operations to use the shared handover contract while preserving direct installer support, manual start, and non-transactional PKG failure semantics.

## Impact

- SPEC.md impact: this change updates §11.4 and §13.4 with stage-then-activate PKG delivery, single-owner crash-released exclusion, manual PKG start, unconditional Orchard.app rollback, managed recovery, and historical-version serialization.
- Domain impact: the glossary defines Managed Lifecycle Exclusion Boundary, Inactive Incoming Staging Root, Managed Node Agent Recovery, and BEAM Peer Grant Store Lock, and refines Managed Node Agent Handover.
- Decision impact: ADR 0017 records the accepted stage-then-activate and single-owner design and corrects ADR 0012 attribution.
- Packaging impact: implementation must move Installer-managed payload out of active paths, make `postinstall` invoke one privileged active handover owner, and keep `preinstall` non-disruptive.
- Availability impact: PKG staging does not interrupt the running Node Agent, active handover incurs a bounded interruption, and successful PKG installs remain stopped until `orchardctl start`.
- Recovery impact: timeout, owner death, and uncertain state require the applicable managed lifecycle to reestablish coherence under the shared exclusion boundary.
- Security impact: the handover protects identity-bearing Node state from concurrent managed process use without broadening the BEAM Peer Grant Store Lock into lifecycle ownership.
