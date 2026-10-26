## Why

Required validation has no dependency vulnerability check and no workflow security analysis.
Known advisories in `mix.lock`, `package-lock.json`, and the `uv.lock` files surface only through a weekly manual dependency sweep, and agent-authored pull requests can add a vulnerable dependency or an unsafe workflow change without any check failing.
GitHub's dependency graph cannot read `mix.lock`, so the Hex dependencies that make up the Orchard product get no Dependabot alerts.
Contributors also need to run the same checks locally before CI.

## What Changes

- Pin OSV-Scanner and zizmor in `mise.toml`.
- Add `scripts/ci/osv-scan.mjs`: a full scan of every lockfile OSV-Scanner reads, plus a comparison mode that reports only vulnerabilities introduced relative to the merge base with a given base revision.
- Add `osv-scanner.toml` as the single committed exception file, with no exceptions.
- Add `make supply-chain`, `make zizmor`, `make osv`, and `make osv-diff`.
- Add a required `Supply-chain validation` lane that runs `make zizmor` and `make osv-diff`.
  `scripts/ci/classify-supply-chain-paths.sh` selects it for dependency, workflow, toolchain-pin, and scanner changes, and it runs on every push to `main`.
  The required aggregate gate requires it when it applies and expects it to be skipped otherwise.
- Add `.github/workflows/dependency-submission.yml`, which submits the Mix dependency graph from `main` with `erlef/mix-dependency-submission` so Hex dependencies get Dependabot alerts.
- Register the new lane's mise-action bootstrap in `.github/mise-action-pin.json`.
- Update `docs/tooling.md` and `AGENTS.md`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `portability-validation`: adds the supply-chain validation lane, its selection and failure rules, local parity, the exception policy, and Mix dependency graph submission.

## Impact

- No `SPEC.md` behavior impact.
  This changes repository validation and contributor workflow only; it adds nothing to the product install or runtime path and does not affect the `SPEC.md` §11.7 air-gapped install.
- Code: `mise.toml`, `Makefile`, `package.json`, `osv-scanner.toml`, `scripts/ci/osv-scan.mjs`, `scripts/ci/classify-supply-chain-paths.sh`, `scripts/ci/evaluate-required-validation.sh`, their tests, both workflows, and `.github/mise-action-pin.json`.
- Validation: the `Required Orchard validation gate` check name and branch protection are unchanged.
  The existing vulnerability backlog on `main` does not fail the new lane.
- External services: OSV-Scanner sends package names and versions to `api.osv.dev` unless run offline; zizmor's online audits call the GitHub API; the submission workflow writes a dependency snapshot to GitHub.
  No third-party account or secret is required.
