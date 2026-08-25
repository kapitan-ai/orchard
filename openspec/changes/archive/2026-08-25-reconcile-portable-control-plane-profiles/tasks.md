## 1. Accepted specs

- [x] 1.1 Rename and modify the `platform-profiles` portable core and profile requirements to the portable Orchard control-plane core and the four qualified profile kinds.
- [x] 1.2 Rename and modify the `packaging-deployment` distribution scope and payload selection requirements to the macOS native distribution profile.
- [x] 1.3 Add the `packaging-deployment` requirement separating source availability from supported public binary availability.
- [x] 1.4 Rename and modify the `portability-validation` macOS lane requirement and requalify required Linux portable validation.
- [x] 1.5 Modify the `host-lifecycle-adapters` isolation requirement to name the portable Orchard control-plane core.
- [x] 1.6 Modify the `worker-runtime-providers` conformance requirement to trigger on a runtime-provider profile.
- [x] 1.7 Update the affected capability purposes to the same qualified vocabulary.
- [x] 1.8 State that a runtime-provider profile qualifies a Node role and MUST NOT make the portable Node Agent provider-specific.
- [x] 1.9 State that source availability changes neither public binary support nor Orchard's licensing terms.

## 2. Normative contract and decisions

- [x] 2.1 Reconcile `SPEC.md` §§1.1, 1.4, 1.5, 2, 4.1, 10, 11, and 14 with the qualified profile vocabulary and the portable Orchard control-plane core.
- [x] 2.2 State in `SPEC.md` that source availability does not imply a supported public binary and that credentialed release gates remain release-only.
- [x] 2.3 Qualify ADR 0023 with the same vocabulary without rewriting its historical decision.
- [x] 2.4 Record the source-availability scope in ADR 0027 with a dated Status annotation so the addition is not attributed to its original reviewers.
- [x] 2.5 Keep the archived `remove-native-pkg-distribution` package at its original decision scope.

## 3. Documentation

- [x] 3.1 Reconcile `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, and `docs/README.md` distribution wording and the Milestone 8 roadmap entry.
- [x] 3.2 Reconcile `docs/architecture.md`, `docs/tooling.md`, `docs/local-dev.md`, and `docs/process.md`.
- [x] 3.3 Reconcile `docs/glossary/CONTEXT.md` with qualified profile terms and qualified Node platform wording.
- [x] 3.4 Reconcile `packaging/README.md` and `packaging/dmg/README.md` with the approved macOS native distribution wording.
- [x] 3.5 Distinguish portable-core build prerequisites such as the Apple C toolchain used by `orchard_cli` from validation steps owned by the macOS native distribution and macOS MLX Node runtime profiles.
- [x] 3.6 Describe the mixed-platform acceptance profile as evidence that is satisfied rather than a deployment topology that is supported.
- [x] 3.7 Keep the shared distribution-neutral payload contract and name `Orchard.app` and the DMG as its current macOS native-distribution consumers without treating the payload as a profile.

## 4. Preserved decisions

- [x] 4.1 Keep native PKG and managed handover removed.
- [x] 4.2 Keep `Orchard.app` inside the DMG as the approved macOS native distribution design.
- [x] 4.3 Make no legal licensing change, introduce no `orchard_node_core` abstraction, and change no product code or CI workflow.

## 5. Validation

- [x] 5.1 Run strict OpenSpec validation for `reconcile-portable-control-plane-profiles` while the change is active.
- [x] 5.2 Archive the completed change with `--skip-specs` because the accepted specs are already synchronized.
- [x] 5.3 Run strict OpenSpec validation for all changes and specs after archiving.
- [x] 5.4 Review the affected main specs for placeholder prose such as `Purpose TBD` after archiving.
