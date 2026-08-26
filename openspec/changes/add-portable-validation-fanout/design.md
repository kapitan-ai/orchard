## Context

The existing required workflow has one path detector, one monolithic Apple Silicon validation job, and one required aggregate gate.
The accepted portability-validation specification requires Linux portable evidence without allowing fake or portable tests to substitute for platform-specific acceptance.
It also requires dependency-aware fan-out rather than a simple documentation versus code split.

The prerequisite issue #287 moves retained Darwin helper compilation behind an explicit macOS-owned boundary.
The Linux lane can therefore compile the umbrella with an `xcrun` tripwire and reject any Darwin helper artifact.

## Goals / Non-Goals

**Goals:**

- Prove the portable Orchard control-plane core on Linux with no Apple or accelerator toolchain.
- Exercise provider-neutral contracts with fake or stub implementations on Linux.
- Retain explicit macOS host, MLX, application, DMG, and signing-contract evidence.
- Make validation fan-out and aggregate behavior executable and locally testable.
- Preserve the required branch-protection check name.

**Non-Goals:**

- Define or support a Linux Platform or Distribution Profile.
- Add Linux Nodes, CUDA, ROCm, or accelerator discovery.
- Replace Apple Silicon MLX validation with stub-worker tests.
- Change branch protection, release credentials, notarization, or publication.

## Decisions

### A repository-owned classifier controls fan-out

Changed paths SHALL be passed to `scripts/ci/classify-required-validation-paths.sh` on pull requests.
The classifier SHALL emit independent portable, conformance, macOS, MLX, and packaging decisions.
Pushes to `main` SHALL run every lane.

Shared contracts, proto source, root configuration, root toolchain, release composition, accepted OpenSpec material, `SPEC.md`, and workflow changes SHALL fan out to every lane.
Native package source, lockfile, metadata, or entrypoint changes SHALL also select packaging validation because payload assembly installs non-editable package trees in a separate environment.
Retained macOS test fixtures SHALL select each macOS host or packaged PTY lane that consumes them.
First-party umbrella application source outside `test/` SHALL also select packaging validation because payload assembly and the packaged CLI lanes build `MIX_ENV=prod` releases from those trees.
Unknown paths SHALL fail safe by selecting every lane.
An empty changed-path set SHALL fail classification rather than emit an all-inapplicable decision, so a failed or unresolvable pull-request diff cannot green the required gate with no validation.
Ordinary documentation MAY select no heavy lane.
Pull-request diffs SHALL disable rename detection so both the removed source path and added destination path enter classification.

Using only workflow-native directory filters was rejected because the dependency rules would be harder to test locally and unknown paths could silently miss consumers.

### Linux portable and provider-neutral evidence are separate

The Linux portable lane SHALL run the portable compile tripwire, format check, warnings-as-errors compilation, Credo, Dialyzer, portable Mix tests and coverage, tokenizer formatting, lint, tests, and coverage.
It SHALL install the Worker Runtime base environment without the MLX extra so stub-backed tests can run without importing accelerator implementations.
It SHALL run focused Worker Runtime stub formatting, lint, tests, and coverage from that base environment.

The provider-neutral lane SHALL run focused contract tests over Worker Runtime mapping, Runtime Endpoints, capability evaluation, lifecycle command invariants, and scheduling.
It SHALL remain separately named so its success is not represented as Linux host support or real-hardware acceptance.

Combining both lanes was rejected because focused provider-neutral failures would be harder to identify and retry.

### Retained platform evidence stays explicit

The macOS host lane SHALL compile the retained Darwin helpers through the explicit builder and run tests tagged `macos`.
The MLX lane SHALL install the accelerator extra and run the real provider package tests on Apple Silicon.
The packaging lane SHALL retain payload, signing-contract, Swift application, lifecycle, assembled app, DMG, and packaged CLI validation.

Moving these checks to Linux or replacing them with stubs was rejected because it would erase the distinction between portable evidence and platform acceptance.

### One tested evaluator owns the aggregate result

The `Required Orchard validation gate` SHALL run after every conditional lane.
It SHALL require `success` for every selected lane and `skipped` for every unselected lane.
Changed-path classification failure, a failed or skipped selected lane, or an unexpectedly executed unselected lane SHALL fail the aggregate.

The evaluator SHALL live in a repository-owned script with deliberate success and failure tests.
Inline workflow conditionals were rejected because they are difficult to exercise before pushing and can accidentally accept an ambiguous result.

## Risks / Trade-offs

- **A dependency edge is omitted** - unknown paths and normative shared surfaces select every lane, while matrix tests lock the known classifications.
- **A macOS-only test is silently lost** - retained Darwin-only test modules and cases carry the `macos` tag and the macOS host lane runs that tag explicitly.
- **Linux accidentally imports MLX** - the portable lane installs only the base Worker Runtime environment and never selects the `mlx` extra.
- **Conditional jobs make branch protection ambiguous** - the unchanged aggregate gate requires exact success or skipped states for every lane.

## Migration Plan

The workflow change takes effect when this stacked pull request merges after issue #287.
No persisted state, operator migration, branch-protection update, or release credential is required.

## Open Questions

None.
