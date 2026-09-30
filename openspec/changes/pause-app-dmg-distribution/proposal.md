## Why

The accountable product owner has paused distributable `Orchard.app` and DMG builds and releases until he explicitly lifts the pause.
Current work focuses on source-development installation, but the repository still presents app and DMG assembly, signing, notarization, and publication as live paths, and CI still assembles an app bundle and a DMG image on packaging changes.
A pause that lives only in conversation can be bypassed by habit or by an agent following the current runbooks, so it needs one reviewable, fail-closed control in the repository.

## What Changes

- Add one committed Distribution Pause Control, `packaging/distribution-control`, whose only accepted resuming value is `state=active`.
  It is committed as `state=paused`; a missing, unreadable, symlinked, duplicated, or malformed control fails closed as paused.
- Guard every entrypoint that produces or signs `Orchard.app` or produces, notarizes, staples, or publishes a DMG: `scripts/build-app.sh`, `scripts/sign-app.sh`, and `scripts/build-dmg.sh`.
  While paused they refuse before any build, signing, image, or network step, with a dedicated exit status and a message that names the control and the re-enable procedure.
  `--help` remains available.
  No environment variable, flag, or tool substitution resumes distribution.
- Split the CI macOS packaging lane.
  The retained packaging-contract lane keeps payload, payload-signing-contract, Swift format/build/unit/coverage, relocated-root app service lifecycle, and packaged `orchardctl` checks.
  A new app-and-DMG assembly lane runs `scripts/test-build-app.sh`, `scripts/test-app-signing.sh`, and `scripts/test-build-dmg.sh` only when packaging is affected and the committed control is active.
  While paused it is skipped, and the required aggregate gate treats it as inapplicable rather than failed.
- Add guard regression tests that use temporary fixture trees and fake tools, never real app or DMG assembly, plus CI routing and aggregate-gate cases for the paused lane.
- Reconcile `SPEC.md`, `AGENTS.md`, `docs/tooling.md`, `docs/process.md`, `docs/local-dev.md`, `docs/operator-journey.md`, `docs/README.md`, `docs/architecture.md`, `README.md`, `SECURITY.md`, and the packaging runbooks so source development is the current active installation path and native app/DMG distribution is explicitly paused, not removed and not promised.
- Preserve all product code, the Swift app package, payload tooling, signing and verification scripts, dormant assembly tests, and the approved `Orchard.app`-inside-DMG design for the macOS native distribution profile.
  Nothing is deleted.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `packaging-deployment`: adds the committed, fail-closed Distribution Pause requirement, its source-development-first posture, and its approval-gated re-enable rule.
- `portability-validation`: separates the retained packaging-contract lane from the paused app-and-DMG assembly lane and requires the aggregate gate to treat a paused assembly lane as inapplicable.

## Impact

- `SPEC.md` impact: amends §1 status prose, §1.4, adds §11.0 Distribution Pause, and qualifies the Milestone 0 and Milestone 8 app/DMG acceptance bullets so that paused assembly evidence is suspended rather than regressed.
  The approved macOS native distribution profile design is unchanged.
- Code: `packaging/distribution-control`, `scripts/lib/distribution-control.sh`, guards in three distribution entrypoints, `scripts/ci/resolve-app-distribution-lane.sh`, the required-validation workflow, the aggregate-gate evaluator, and their tests.
- Validation: the `Required Orchard validation gate` check name, branch protection, and workflow triggers are unchanged; no workflow-level `paths-ignore` is introduced.
- Resuming distribution requires a reviewed pull request that sets `state=active` with the accountable product owner's explicit approval, and it re-enables the dormant assembly lane automatically.
