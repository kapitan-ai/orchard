## Context

See `proposal.md` for motivation.
Today the repository has three entrypoints that form or ship the macOS native distribution:

- `scripts/build-app.sh` assembles `Orchard.app` from a staged payload with a release Swift build.
- `scripts/sign-app.sh` signs an assembled app ad hoc or with a Developer ID identity.
- `scripts/build-dmg.sh` verifies an app, drives Amore to assemble and optionally notarize a DMG, validates stapling, and optionally publishes a draft release.

Their integration tests, `scripts/test-build-app.sh`, `scripts/test-app-signing.sh`, and `scripts/test-build-dmg.sh`, build real app bundles and a real disk image from fixture payloads.
The required-validation workflow runs them inside the single `packaging-validation` job, alongside checks that never form an app or DMG: payload staging and payload-signing contracts, Swift format/build/unit/coverage, the relocated-root app service lifecycle, and packaged `orchardctl` checks.
The workflow has one required check, `Required Orchard validation gate`, backed by `scripts/ci/evaluate-required-validation.sh`, which demands `success` from selected lanes and `skipped` from unselected ones.
There are no release or publication workflows, tags, or Makefile targets for app or DMG distribution.

## Goals / Non-Goals

**Goals:**

- One committed control decides whether app/DMG distribution is active, and every affected entrypoint and CI lane reads it.
- The control fails closed and cannot be overridden from the environment.
- Source-install, payload, lifecycle, signing-contract, macOS native-helper, portable, conformance, MLX, and OpenSpec validation keep running unchanged.
- Resuming is a one-line reviewed change that also re-enables the dormant CI lane.

**Non-Goals:**

- Deleting or refactoring the Swift app package, payload tooling, signing or verification scripts, or dormant tests.
- Guarding payload staging or payload signing. These produce the distribution-neutral payload contract, not `Orchard.app` or a DMG, and their credential-free contract tests depend on running them with fake tools.
  Without the guarded app assembly step there is no supported way to turn a payload into an installable artifact.
- Guarding read-only verifiers such as `scripts/verify-app-signing.sh` and `scripts/verify-payload-signing.sh`.
- Changing branch protection, the required check name, workflow triggers, or adding workflow-level path filtering.
- Recording who may approve inside code. Approval is enforced by pull-request review, not by the script.

## Decisions

### A committed key/value file under `packaging/`

`packaging/distribution-control` holds comments and exactly one `state=` line.
It lives beside the artifacts it governs, so the existing classifier already routes a change to it into the packaging lanes.
Alternatives considered: a `Makefile` or `mise.toml` variable (not read by the shell entrypoints and routed to every lane), a repository variable in GitHub settings (not reviewable in a pull request and invisible to local runs), and an environment variable default (an override by construction).

### Fail-closed parsing in one shared shell library

`scripts/lib/distribution-control.sh` resolves the control relative to the repository that contains the calling script, never from the environment.
It accepts distribution as active only for a regular, non-symlink, readable file with exactly one `state=active` line after comments and blank lines are ignored.
Everything else resolves to paused with a stated reason.
The library is Bash 3.2 compatible because the entrypoints run under `/bin/bash` on macOS.

### Refuse after argument parsing, before any validation or tool use

Each entrypoint keeps its existing argument loop, so `--help` exits successfully and unknown options still exit with usage status `64`.
The guard runs immediately after the loop and before input checks, tool discovery, temporary directories, or builds.
A paused refusal exits with status `78` (`EX_CONFIG`), which none of the three entrypoints uses for another failure.
`build-dmg.sh --dry-run` is also refused: it rehearses the credentialed release path and requires an already assembled app, so it is not a useful read-only surface during the pause.

### Tests use copied fixture trees, not overrides

`scripts/test-distribution-control.sh` copies the guarded entrypoints and the library into temporary fixture repositories with fixture control files, and prepends fake `swift`, `ditto`, `codesign`, `hdiutil`, `amore`, `xcrun`, `jq`, `plutil`, and `shasum` tools that record any invocation.
It proves refusal, no tool invocation, and no output for the committed paused state and for every fail-closed control shape, proves environment claims do not resume distribution, proves `--help` still works, and proves an `active` fixture reaches the entrypoint's own argument validation.
It also asserts the committed control is paused, so the pause cannot be lifted without updating that test in the same reviewed change.
The test needs only Bash and POSIX tools, so it runs in the always-on Linux classification job.

### A separate, dormant assembly lane

`packaging-validation` keeps every check that does not form an app or DMG.
A new `app-distribution-validation` job runs the three assembly tests and is selected by a new `app_distribution` classification output.
`scripts/ci/resolve-app-distribution-lane.sh` passes the path classifier output through and appends `app_distribution=true` only when `packaging=true` and the committed control is active.
`scripts/ci/test-app-distribution-lane.sh` covers the resolver with copied fixture trees and asserts the workflow wiring: both classification branches resolve the lane, the packaging-contract job runs no assembly script and keeps its retained checks, the assembly job is selected only by `app_distribution`, the gate consumes it, and workflow triggers use no path filtering.
The aggregate gate gains `APP_DISTRIBUTION_REQUIRED` and `APP_DISTRIBUTION_RESULT`, requires `skipped` when it is not required, and rejects an assembly requirement without a packaging requirement.
Alternative considered: step-level `if:` inside `packaging-validation`; rejected because the gate could not observe or prove that the paused steps did not run.

### Contract text

`SPEC.md` gains §11.0 Distribution Pause and short qualifiers where it states current app-installed status and app/DMG acceptance.
The macOS native distribution profile design is unchanged, so no decision record supersedes an existing one.

## Risks / Trade-offs

- [A future distribution entrypoint is added without the guard] → The spec delta requires every app or DMG entrypoint to consume the control, and the guard test enumerates the guarded entrypoints so reviewers see the list.
- [Someone edits a guarded script to drop the guard] → That is a reviewable code change; the guard test fails when an entrypoint no longer refuses.
- [Payload Developer ID signing stays available] → It produces no installable artifact on its own; the app assembly and app signing steps that would consume it are paused.
- [Dormant assembly tests rot while paused] → The resume change re-enables the assembly lane in the same pull request, so drift surfaces before distribution resumes.
- [Local runs of the former Swift workflow assembly steps now fail] → `AGENTS.md` and `docs/tooling.md` replace them with the guard test while paused and state the expected exit status.

## Migration Plan

1. Land the control as `state=paused`, the guards, the lane split, the tests, and the documentation together.
2. To resume, open a pull request that sets `state=active`, updates the committed-state assertion in `scripts/test-distribution-control.sh`, restores the paused wording in the documents listed in `packaging/dmg/README.md`, and obtains the accountable product owner's explicit approval.
   The assembly lane then runs on that pull request.
3. Rollback of this change is a revert; no persisted state or installed host is touched.
