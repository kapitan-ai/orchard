## ADDED Requirements

### Requirement: Supply-Chain Validation Lane
Required validation SHALL run a supply-chain lane when a pull request changes a third-party dependency manifest or lockfile, a CI workflow definition, the toolchain pins, or the supply-chain scanners or their configuration, and on every push to `main`.
The lane SHALL statically audit the repository's GitHub Actions workflow definitions and SHALL fail on findings at the auditor's default severity and confidence.
The lane SHALL fail when the change introduces a known vulnerability into a scanned lockfile, judged against the merge base with the target revision, and SHALL NOT fail on vulnerabilities already present at that merge base.
Scanner, repository, or usage errors SHALL fail the lane rather than pass it.
The required repository gate SHALL require the lane to succeed when it applies and SHALL fail if the lane runs when it does not apply.

#### Scenario: Change introduces a vulnerable dependency version
- **WHEN** a pull request changes a lockfile so that it resolves a package version affected by a known advisory that does not affect that lockfile at the merge base
- **THEN** the supply-chain lane fails and names the advisory, package, version, and lockfile
- **AND** the required gate fails

#### Scenario: Existing vulnerability backlog
- **WHEN** a pull request changes a lockfile and every reported advisory is already present at the merge base
- **THEN** the supply-chain lane passes

#### Scenario: Change touches no supply-chain input
- **WHEN** a pull request changes only application source or ordinary documentation
- **THEN** the supply-chain lane is skipped
- **AND** the required gate treats the skip as inapplicable

#### Scenario: Unsafe workflow change
- **WHEN** a pull request changes a workflow in a way the workflow auditor reports at its default severity and confidence
- **THEN** the supply-chain lane fails

### Requirement: Supply-Chain Checks Run Locally
Each supply-chain check SHALL be runnable locally, before CI, with the same pinned tools and repository commands that the supply-chain lane runs.
A local full scan SHALL report every known vulnerability in the scanned lockfiles.
The scanned lockfiles SHALL include untracked lockfiles that are not ignored.
Accepting a known vulnerability SHALL require a committed exception with the advisory identifier, an expiry date, and a reason, and SHALL be an accountable product-owner decision.

#### Scenario: Contributor checks a dependency change before pushing
- **WHEN** a contributor changes a lockfile and runs the documented local supply-chain command
- **THEN** it reports the same introduced vulnerabilities that the CI lane would report for that change

#### Scenario: Known vulnerability has no released fix
- **WHEN** the product owner accepts an advisory with no released fix
- **THEN** a dated, reasoned exception is committed in the scanner configuration
- **AND** both full scans and comparisons apply it

### Requirement: Mix Dependency Graph Submission
Orchard SHALL submit the Mix dependency graph of `main` to the repository host's dependency graph so that Hex dependencies receive dependency vulnerability alerts.
Submission SHALL run only from pushes to `main` or an explicit manual dispatch, SHALL NOT run for pull requests, and SHALL limit write permission to the submitting job.

#### Scenario: Change merges to main
- **WHEN** a commit lands on `main`
- **THEN** the Mix dependency snapshot for that commit is submitted
- **AND** no other job in the workflow holds repository write permission

#### Scenario: Pull request
- **WHEN** a pull request is opened or updated
- **THEN** no dependency snapshot is submitted
