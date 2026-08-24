## 1. Normative contract

- [x] 1.1 Remove native PKG from `SPEC.md` distribution, offline, upgrade, milestone, and platform-profile requirements.
- [x] 1.2 Remove Managed Node Agent zero-overlap handover, start-eligibility, exclusion, evidence, staging, and recovery requirements from `SPEC.md`.
- [x] 1.3 Preserve Orchard.app/DMG lifecycle, source-development, API, retained-state, signing, and rolling-version compatibility requirements.
- [x] 1.4 State that future packaging or managed handover requires a fresh accepted OpenSpec proposal and separate implementing pull request.

## 2. Accepted specs and decisions

- [x] 2.1 Reconcile `packaging-deployment`, `app-distribution-lifecycle`, `host-lifecycle-adapters`, and `platform-profiles` accepted specs.
- [x] 2.2 Add ADR 0027, mark ADR 0018 superseded without rewriting its historical body, and qualify ADR 0023's affected clause.
- [x] 2.3 Delete the abandoned active `managed-node-agent-handover` change instead of archiving it.

## 3. Active changes and documentation

- [x] 3.1 Reconcile active release-governance, operator-journey, and product-licensing change packages that still assume native PKG.
- [x] 3.2 Reconcile `AGENTS.md`, `README.md`, tooling, process, architecture, glossary, security, local-development, operator-journey, and docs navigation guidance.
- [x] 3.3 Preserve historical archives and classify non-normative milestone and decision references as intentional history.

## 4. Validation

- [x] 4.1 Run strict OpenSpec validation for `remove-native-pkg-distribution`.
- [x] 4.2 Run strict OpenSpec validation for all changes and accepted specs.
- [x] 4.3 Run residual searches for native PKG and managed handover claims across active normative and operator-facing files.
- [x] 4.4 Inspect and classify every remaining match as superseded history, archived history, explicit non-support language, legacy implementation residue, or unrelated use of handover vocabulary.
