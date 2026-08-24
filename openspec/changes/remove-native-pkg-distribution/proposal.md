## Why

Orchard's active contract still described native PKG as a supported parallel distribution path and specified an extensive Managed Node Agent zero-overlap handover protocol across app, package, recovery, start, and stop paths.
The implemented and validated current distribution is the signed `Orchard.app` DMG, while the PKG and handover claims exceeded current behavior and created direct `SPEC.md` drift.

## What Changes

- Make the signed and notarized DMG containing `Orchard.app` the only current native macOS distribution channel.
- Remove native PKG from supported release artifacts, operator workflows, validation gates, offline install flows, upgrade procedures, and platform-profile acceptance.
- Delete native PKG scripts, assets, dedicated tests, and active documentation while retaining the legacy receipt blocker required to prevent app takeover of an existing installation.
- Supersede ADR 0018 and remove its Managed Node Agent Handover, zero-overlap, shared lifecycle exclusion, durable start-eligibility, one-shot launch authorization, provisional-child, inert-PKG-staging, and recovery protocol from the current contract.
- Preserve the app-owned root-authorized lifecycle, transactional rollback, retained state, signing, DMG verification, source development, supported APIs, and Controller `N` to Node Agent `N`/`N-1` compatibility.
- Require any future native package, additional distribution channel, or managed replacement protocol to begin with a fresh accepted OpenSpec proposal and a separate implementing pull request.

SPEC.md impact: §§1.4, 2.4-2.5, 11, 13.3-13.4, and the roadmap remove native PKG and ADR 0018 handover requirements while retaining Orchard.app/DMG, app lifecycle safety, source development, APIs, and rolling-version compatibility.

## Capabilities

### Modified Capabilities

- `packaging-deployment`: Makes Orchard.app/DMG the current macOS distribution, withdraws native PKG support, and requires fresh approval for future channels.
- `app-distribution-lifecycle`: Removes parallel-PKG compatibility and receipt ownership from the active app lifecycle contract while preserving app and DMG behavior.
- `host-lifecycle-adapters`: Removes the implied zero-overlap replacement protocol and requires a fresh proposal for any future managed handover.
- `platform-profiles`: Removes PKG and managed handover from the preserved macOS profile acceptance set.

## Impact

- Operators and contributors are directed only to the Orchard.app/DMG distribution path.
- Source-development commands, public APIs, Operator APIs, Admin APIs, Runtime Endpoint contracts, and wire compatibility remain unchanged.
- Historical records and the app's legacy receipt blocker do not establish an active PKG distribution path.
- Orchard makes no current zero-overlap managed Node Agent replacement guarantee.
- Sequential node upgrades remain cordon, drain, app-owned update, version and health verification, and uncordon operations.
- Historical archives and the preserved body of superseded ADR 0018 remain available as context without current authority.
