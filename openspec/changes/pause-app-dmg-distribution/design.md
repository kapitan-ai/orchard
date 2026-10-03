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
- Guarding payload staging or payload signing in code. These produce the distribution-neutral payload contract, not `Orchard.app` or a DMG, and their credential-free contract tests depend on running them with fake tools.
  Credentialed Developer ID payload signing is release-only by policy and is not performed while paused.
- Treating the guard as a security boundary. It prevents accidental distribution through the supported entrypoints; it does not defend against deliberately editing the checkout or running an entrypoint through a custom interpreter.
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

### Shell-environment hardening for direct execution

The entrypoints use `#!/bin/bash -p`.
Privileged mode ignores `BASH_ENV` and shell functions imported from the environment, so a startup file or an exported `source`, `cd`, `dirname`, or guard function cannot stub the check.
The repository root is derived with `${BASH_SOURCE[0]%/*}`, `builtin cd -P`, and `builtin pwd -P` after `unset CDPATH`, so a `PATH` command or `CDPATH` cannot point the guard at another checkout.
Alternatives considered: `unset -f` of known names (incomplete, and `unset` itself can be shadowed) and a compiled launcher (a broad refactor).
Invoking an entrypoint as `bash script.sh` bypasses the shebang and is outside normal supported direct execution.

### DMG cleanup starts only after outputs are confirmed absent

`build-dmg.sh` previously installed its `EXIT` cleanup before argument parsing, so help, usage errors, a missing option value, or an existing-output refusal could delete a file already at `--output`.
The trap is now installed after the existing-output check, which is the first point where every path it removes is known to belong to this run.
The pause refusal no longer needs to clear the trap.

### Refuse after argument parsing, before any validation or tool use

Each entrypoint keeps its existing argument loop, so `--help` exits successfully and unknown options still exit with usage status `64`.
The guard runs immediately after the loop and before input checks, tool discovery, temporary directories, or builds.
A paused refusal exits with status `78` (`EX_CONFIG`), which none of the three entrypoints uses for another failure.
`build-dmg.sh --dry-run` is also refused: it rehearses the credentialed release path and requires an already assembled app, so it is not a useful read-only surface during the pause.

### Tests use copied fixture trees, not overrides

`scripts/test-distribution-control.sh` copies the guarded entrypoints and the library into temporary fixture repositories with fixture control files, and prepends fake `swift`, `ditto`, `codesign`, `hdiutil`, `amore`, `xcrun`, `jq`, `plutil`, `shasum`, and `mise` tools that record any invocation and exit nonzero.
It proves refusal, no tool invocation, and no output for a paused fixture and for every fail-closed control shape, proves Orchard environment claims, `PATH` redirection, `CDPATH`, `BASH_ENV`, and exported functions do not resume distribution, proves `--help` still works, proves `build-dmg.sh` preserves a pre-existing `--output` file on every early exit, and proves an `active` fixture reaches the entrypoint's own argument validation.
One labeled committed-state block asserts the committed control is paused and the real entrypoints refuse, so the pause cannot be lifted without updating that block in the same reviewed change.
`scripts/ci/test-app-distribution-lane.sh` uses paused and active fixtures for lane selection and gate evaluation, and derives its committed-control expectation from the control itself, so it passes unchanged after an approved resume.
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
- [Payload Developer ID signing stays technically available] → `SPEC.md` §11.0 and the runbook make it release-only and forbidden while paused; it produces no installable artifact on its own, and the app assembly and app signing steps that would consume it are guarded.
- [The dormant assembly lane lacks a dependency when resumed] → The lane installs the pinned mise toolchain that `verify-app-signing.sh` needs, and the lane test asserts that step precedes the assembly tests.
- [Dormant assembly tests rot while paused] → The resume change re-enables the assembly lane in the same pull request, so drift surfaces before distribution resumes.
- [Local runs of the former Swift workflow assembly steps now fail] → `AGENTS.md` and `docs/tooling.md` replace them with the guard test while paused and state the expected exit status.

## Migration Plan

1. Land the control as `state=paused`, the guards, the lane split, the tests, and the documentation together.
2. To resume, open a pull request that sets `state=active`, updates the committed-state block in `scripts/test-distribution-control.sh`, restores the paused wording in the documents listed in `packaging/dmg/README.md`, and obtains the accountable product owner's explicit approval.
   The assembly lane then runs on that pull request.
3. Rollback of this change is a revert; no persisted state or installed host is touched.
