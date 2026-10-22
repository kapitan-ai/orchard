## 1. Scanners and local commands

- [x] 1.1 Pin OSV-Scanner `2.7.0` and zizmor `1.30.1` in `mise.toml`, and verify `mise install` installs both
- [x] 1.2 Add `scripts/ci/osv-scan.mjs` with full and merge-base comparison modes, and verify `scripts/ci/test-osv-scan.mjs` covers argument parsing, lockfile discovery, finding identity, merge-base selection, the exception file, scanner and Git errors, and command-line exit statuses
- [x] 1.3 Add `osv-scanner.toml` with the exception policy and no exceptions, and verify OSV-Scanner honors an explicit `--config` ignore
- [x] 1.4 Add `make supply-chain`, `make zizmor`, `make osv`, and `make osv-diff`, and verify each runs locally against the repository

## 2. Required lane and gate

- [x] 2.1 Add `scripts/ci/classify-supply-chain-paths.sh` and its test, and verify the scan script's lockfile names all select the lane
- [x] 2.2 Add the `supply-chain-validation` job and wire `supply_chain` through the `changes` job and the aggregate gate
- [x] 2.3 Extend `scripts/ci/evaluate-required-validation.sh` and `scripts/ci/test-required-validation-gate.sh`, and verify pass, fail, required-skip, inapplicable-run, and empty-requirement cases
- [x] 2.4 Register the lane's mise-action bootstrap in `.github/mise-action-pin.json`, and verify the pin check and its tests pass with eight invocations

## 3. Dependency graph submission

- [x] 3.1 Add `.github/workflows/dependency-submission.yml` pinned to `erlef/mix-dependency-submission` v1.3.4 by commit SHA, with job-scoped `contents: write`, and verify zizmor reports no findings in the auditor persona
- [x] 3.2 Verify the v1.3.4 binary's build attestation and generate a submission locally without sending it, and confirm it resolves every Mix manifest and its transitive Hex dependencies
- [ ] 3.3 After merge, confirm the workflow submits from `main` and that Hex packages appear in the repository dependency graph

## 4. Review repairs

- [x] 4.1 Select the lane for Git-quoted paths, root zizmor configuration, and manifests at any depth, including Swift, and verify with real `git diff --name-only` output for non-ASCII and tab paths
- [x] 4.2 Request `--all-packages` and fail when OSV-Scanner reads no packages from a requested lockfile, and verify the stub scanner omits unreadable lockfiles as OSV-Scanner 2.7.0 does
- [x] 4.3 Match introduced findings against every aliased advisory record, using both the group IDs and the group aliases, and add `Package.resolved` to the scanned lockfile names after verifying OSV-Scanner 2.7.0 reads it
- [x] 4.4 Scan the Git repository that contains the working directory, and record the push-base, concurrency, and submission-binary trust decisions in this design

## 5. Documentation and validation

- [x] 5.1 Update `docs/tooling.md` and `AGENTS.md` with the commands, lane selection, exception policy, data sent to external services, and submission behavior
- [x] 5.2 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate add-supply-chain-validation --type change --strict --no-interactive` and the all-specs strict validation
- [ ] 5.3 After archive or sync, review the generated `portability-validation` spec for placeholder prose
