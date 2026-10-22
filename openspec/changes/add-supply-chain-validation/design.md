## Context

Orchard has six tracked lockfiles across three ecosystems: `mix.lock` (Hex), `package-lock.json` (npm), and four `uv.lock` files (PyPI).
`packaging/app` declares no third-party Swift packages.
A weekly dependency sweep runs Hex audit, `npm audit`, and OSV checks by hand and opens update pull requests, applying a seven-day age rule to new releases.
At the time of this change, a full OSV scan of `main` reports ten advisories across seven packages, two of them with no released fix.

## Goals / Non-Goals

**Goals:**

- Fail a pull request that introduces a known vulnerable dependency version or an unsafe workflow definition.
- Give Hex dependencies continuous Dependabot alerts.
- Run every check locally with the same pinned tools and commands as CI.
- Keep tooling open source, account-free, and secret-free.

**Non-Goals:**

- Remediating the existing backlog; dependency update work owns it.
- Malware or behavioural package analysis.
- Swift-specific tooling, while `packaging/app` has no third-party packages; a `Package.swift` change selects the lane and a committed `Package.resolved` is scanned.
- Digest-pinning the CI service container images; zizmor reports this only in its auditor persona, and it is separate work.

## Decisions

### Introduced-only failure for pull requests

A full-scan gate would fail every pull request today and again whenever a new advisory is published, for at least the seven days the age rule holds back the fix.
That would block unrelated work and push contributors toward suppressing findings.
The lane therefore fails only on findings present in the change and absent at the merge base.
Using the merge base, not the base branch tip, keeps a branch that is behind a fix on `main` from being blamed for it.
In the pull request checkout, `HEAD` is GitHub's merge commit, so the comparison reflects what merging would add.
The backlog stays visible through `make osv` and Dependabot alerts.

A finding's identity is lockfile, ecosystem, package, and advisory, not version.
An advisory matches any of its aliased records, so a bump that stays inside the same advisory adds nothing even when a different alias record reports it; the same advisory reaching another lockfile is new exposure.

OSV-Scanner leaves out a lockfile it cannot read and still exits successfully.
The script requests every package (`--all-packages`) and fails when a requested lockfile is missing from the results, so an unreadable lockfile cannot hide an introduced vulnerability.

On a push to `main`, the base is the previous `main` commit.
Branch protection forbids force pushes and deletion of `main`, so that commit is always an ancestor, and the merge base is that commit; an unreachable or zero base fails the step.
Workflow concurrency cancels an earlier `main` run when a later push arrives; the cancelled change was already compared in its pull request lane, so this is a reporting gap, not a bypass.

Alternative considered: OSV-Scanner's reusable GitHub workflow, which also compares base and head.
It runs only in GitHub Actions, uploads SARIF, and cannot be run locally with the same command, so it fails the local-parity goal.

### Repository-owned exceptions

`osv-scanner.toml` is passed explicitly with `--config`, so one file governs every lockfile and both sides of a comparison.
Exceptions need an advisory ID, a dated `ignoreUntil`, and a reason, and are product-owner decisions.

### Path-selected lane

The lane runs only when a change can affect dependencies, workflows, tool pins, or the scanners, and on every push to `main`.
Selecting by path also limits zizmor's online audits, which can change as advisories are published, to changes that touch workflows or their inputs.
A separate classifier keeps the existing classifier's output and tests unchanged; a test asserts it selects the lane for every lockfile name the scan script reads.
Manifests match at any depth, and a path that Git quotes because of special characters selects the lane, because its real name cannot be matched.

### Dependency graph submission from `main` only

The Dependency Submission API needs `contents: write`.
Only the submission job holds it, and it runs on push to `main` and manual dispatch, never on pull requests.
The action verifies its release binary's build provenance before running it.
`install-deps` stays off: the submission resolves all five Mix manifests and their transitive dependencies from `mix.lock` without fetching dependencies with the action's bundled Elixir.

### Tool selection

OSV-Scanner reads `mix.lock`, `package-lock.json`, and `uv.lock` in one run and draws on the open OSV database, which includes the Erlang Ecosystem Foundation's Hex advisories.
zizmor covers workflow risks that action SHA pinning does not.
Both are pinned through mise, so local runs and CI use the same versions.
A hosted behavioural scanner was evaluated and deferred: it gives no coverage for Hex, which is most of the product dependency set, and it requires a third-party GitHub App with write access.

## Risks / Trade-offs

- [OSV database or API unavailable] → The lane fails closed with exit status 2; rerun, or run offline with downloaded databases.
- [New advisory against an existing dependency] → Does not fail pull requests; surfaces through Dependabot alerts and `make osv`.
- [zizmor online audit drift] → Limited to changes that touch workflow inputs; such a change owns the finding.
- [Exception misuse] → Exceptions are reviewable diffs in `osv-scanner.toml`, and the file is a lane trigger.
- [Submission binary trust] → The pinned action fetches its binary by release tag and verifies that the upstream release workflow built it, not a fixed digest, while the job holds `contents: write`. A compromised upstream release pipeline could act with that token. Accepted: the job runs only on `main` pushes and manual dispatch, and branch protection bounds what the token can change on `main`.
