## Why

Orchard's active contract still described native PKG as a supported parallel distribution path and specified an extensive Managed Node Agent zero-overlap handover protocol across app, package, recovery, start, and stop paths.
The implemented and validated native distribution design is the signed `Orchard.app` DMG, while the PKG and handover claims exceeded current behavior and created direct `SPEC.md` drift.

## What Changes

- Keep the signed and notarized DMG containing `Orchard.app` as the approved macOS native distribution profile.
- Distinguish source availability from public binary availability and support, with public binaries gated by an explicit release decision and completed release gates.
- Remove native PKG from supported release artifacts, operator workflows, validation gates, offline install flows, upgrade procedures, and macOS native distribution profile acceptance.
- Delete native PKG scripts, assets, and PKG-only tests while retaining payload wrapper and payload signing regression coverage for the scripts and wrappers that remain.
- Retain the legacy receipt blocker as a normative `SPEC.md` §11.4 requirement so it cannot be dropped without a contract change, and move installer-independent operator documentation into `packaging/README.md`.
- Supersede ADR 0018 and remove its Managed Node Agent Handover, zero-overlap, shared lifecycle exclusion, durable start-eligibility, one-shot launch authorization, provisional-child, inert-PKG-staging, and recovery protocol from the current contract.
- Preserve the app-owned root-authorized lifecycle, transactional rollback, retained state, signing, DMG verification, source development, supported APIs, and Controller `N` to Node Agent `N`/`N-1` compatibility.
- Require any future native package, additional distribution channel, or managed replacement protocol to begin with a fresh accepted OpenSpec proposal and a separate implementing pull request.

SPEC.md impact: §§1.4, 2.4-2.5, 11, 13.3-13.4, and the roadmap remove native PKG and ADR 0018 handover requirements while retaining Orchard.app/DMG, app lifecycle safety, source development, APIs, and rolling-version compatibility.

## Capabilities

### Modified Capabilities

- `packaging-deployment`: Keeps Orchard.app/DMG as the approved macOS native distribution, distinguishes source availability from public binary support, withdraws native PKG support, and requires fresh approval for future channels.
- `app-distribution-lifecycle`: Removes parallel-PKG compatibility from the active app lifecycle contract, keeps the legacy receipt takeover blocker as its own normative requirement, and preserves app and DMG behavior.
- `host-lifecycle-adapters`: Removes the implied zero-overlap replacement protocol and requires a fresh proposal for any future managed handover.
- `platform-profiles`: Removes PKG and managed handover from the preserved macOS native distribution profile acceptance set.
- `portability-validation`: Qualifies separate macOS host-lifecycle, Orchard.app/DMG, MLX, and credentialed release evidence while preserving the future Linux portable lane.

## Impact

- Operators and contributors are directed only to the Orchard.app/DMG distribution path.
- Source-development commands, public APIs, Operator APIs, Admin APIs, Runtime Endpoint contracts, and wire compatibility remain unchanged.
- Historical records and the app's legacy receipt blocker do not establish an active PKG distribution path.
- Orchard makes no current zero-overlap managed Node Agent replacement guarantee.
- Sequential node upgrades remain cordon, drain, app-owned update, version and health verification, and uncordon operations.
- Historical archives and the preserved body of superseded ADR 0018 remain available as context without current authority.
