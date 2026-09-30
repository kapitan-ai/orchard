## 1. Pause control and entrypoint guards

- [x] 1.1 Add `packaging/distribution-control` committed as `state=paused` with re-enable guidance, and verify it parses as paused through the library
- [x] 1.2 Add `scripts/lib/distribution-control.sh` with fail-closed parsing and a refusal helper, and verify `bash -n` and ShellCheck pass
- [x] 1.3 Guard `scripts/build-app.sh`, `scripts/sign-app.sh`, and `scripts/build-dmg.sh` after argument parsing, and verify `--help` still exits `0` and a paused run exits `78`
- [x] 1.4 Add `scripts/test-distribution-control.sh` with fixture trees and fake tools covering paused, missing, directory, symlinked, unreadable, empty, duplicated, conflicting, malformed, CRLF, missing-library, environment-override, help, and active cases, and verify it passes under Homebrew Bash 5 and macOS `/bin/bash` 3.2

## 2. CI lane split and gate

- [x] 2.1 Add `scripts/ci/resolve-app-distribution-lane.sh` and `scripts/ci/test-app-distribution-lane.sh`, and verify paused, active, missing-control, malformed-control, environment-claim, and malformed classifier input cases
- [x] 2.2 Split `packaging-validation` into the retained packaging-contract job and a dormant `app-distribution-validation` job selected by `app_distribution`, and verify workflow YAML parses and `scripts/ci/test-app-distribution-lane.sh` asserts the split and gate wiring
- [x] 2.3 Extend `scripts/ci/evaluate-required-validation.sh` and `scripts/ci/test-required-validation-gate.sh` for the assembly lane, and verify paused-skip, required-failure, inapplicable-run, and packaging-consistency cases
- [x] 2.4 Add the classifier case for `packaging/distribution-control`, and verify `scripts/ci/test-classify-required-validation-paths.sh` passes

## 3. Contract and documentation reconciliation

- [x] 3.1 Amend `SPEC.md` §1, §1.1, §1.4, §11.0, Milestone 0, and Milestone 8 wording, and verify no remaining text presents app or DMG distribution as currently active
- [x] 3.2 Update `AGENTS.md`, `docs/tooling.md`, `docs/process.md`, `docs/local-dev.md`, `docs/operator-journey.md`, `docs/README.md`, `docs/architecture.md`, `README.md`, `SECURITY.md`, `packaging/README.md`, and `packaging/dmg/README.md`, and verify re-enable instructions require the accountable product owner's approval and a reviewed control change

## 4. Validation

- [x] 4.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate pause-app-dmg-distribution --type change --strict --no-interactive` and the all-specs strict validation, and verify both pass
- [x] 4.2 Run the CI routing, gate, classifier, resolver, and guard tests plus ShellCheck and workflow YAML parsing, and verify all pass without assembling an app or DMG
- [ ] 4.3 After merge and acceptance, archive or sync this change and review generated main specs for placeholder prose such as `Purpose TBD`
