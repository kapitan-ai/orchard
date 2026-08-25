## Why

Orchard's durable documentation used `platform profile` as an umbrella term and `portable core` as an unqualified boundary name, so operating system support, deployment artifacts, runtime providers, and cross-host acceptance evidence were described with one word that could not distinguish them.
The same documentation stated that the signed `Orchard.app` DMG is the current native distribution, which reads as a promise of an available supported public binary before any release decision or credentialed release gate has completed.
The archived `remove-native-pkg-distribution` change is complete and owns the native PKG and managed handover removal decision only, so it is not the right record for this reconciliation.

## What Changes

- Name the portable Orchard control-plane core explicitly as the platform-neutral Shared, Controller, Node Agent, and portable CLI behavior plus provider-neutral contracts.
- Define platform, distribution, runtime-provider, and acceptance profiles as qualified, composable concepts, and keep host-lifecycle adapters and deployment artifacts out of the profile vocabulary.
- Keep the Apple Silicon macOS platform profile, the macOS native distribution profile, the macOS MLX Node runtime profile, and the mixed-platform acceptance profile distinct from one another.
- Keep the Linux Controller as a platform profile that uses operator-provided external Postgres and stays unsupported until its Milestone 8 acceptance gates pass.
- Describe the signed and notarized DMG containing `Orchard.app` as the approved macOS native distribution rather than an already available public binary.
- Permit the initial source-availability transition without representing source availability as public binary availability, support, or a licensing change.
- Keep macOS host-lifecycle, Orchard.app and DMG, and macOS MLX Node runtime validation in separate lanes, and keep Developer ID signing, notarization, stapling, and publication release-only.

SPEC.md impact: §§1.1, 1.2, 1.4, 1.5, 2, 4.1, 10, 11, and 14 adopt the qualified profile vocabulary, name the portable Orchard control-plane core, and separate source availability from supported public binary availability.
The §10 edit reassigns approved credential storage from the platform profile to the distribution profile without changing which secrets are stored or how.
Native PKG and managed handover remain removed, Orchard.app remains inside the DMG, and no legal licensing term changes.

## Capabilities

### Modified Capabilities

- `platform-profiles`: Renames the portable core boundary and the profile requirement, and defines platform, distribution, runtime-provider, and acceptance profiles as distinct qualified concepts.
- `packaging-deployment`: Scopes Apple distribution gates to the macOS native distribution profile, scopes payload selection to distribution profiles, and separates source availability from supported public binary availability.
- `portability-validation`: Names the portable Orchard control-plane core as the trigger for required Linux validation and splits the macOS contract lanes with release-only credentialed operations.
- `host-lifecycle-adapters`: Names the portable Orchard control-plane core as the boundary that host-lifecycle adapters sit outside of.
- `worker-runtime-providers`: Ties provider support review to a runtime-provider profile instead of an unqualified platform profile.

## Impact

- Durable documentation, decisions, and accepted specs use one qualified profile vocabulary that reviewers can apply without guessing which kind of profile is meant.
- Readers are not told that a supported public Orchard binary is available before a release decision and the credentialed release gates complete.
- The `app-distribution-lifecycle` purpose is requalified to the macOS native distribution profile without changing any of its requirements.
- No product code, test, or CI workflow behavior changes in this documentation reconciliation.
- No Orchard licensing term changes, and no `orchard_node_core` abstraction is introduced.
