## 1. Normative contract

- [x] 1.1 Remove native PKG from `SPEC.md` distribution, offline, upgrade, milestone, and platform-profile requirements.
- [x] 1.2 Remove Managed Node Agent zero-overlap handover, start-eligibility, exclusion, evidence, staging, and recovery requirements from `SPEC.md`.
- [x] 1.3 Preserve Orchard.app/DMG lifecycle, source-development, API, retained-state, signing, and rolling-version compatibility requirements.
- [x] 1.4 State that future packaging or managed handover requires a fresh accepted OpenSpec proposal and separate implementing pull request.
- [x] 1.5 Keep the legacy PKG receipt takeover blocker normative in `SPEC.md` §11.4 and in the `app-distribution-lifecycle` capability.

## 2. Accepted specs and decisions

- [x] 2.1 Reconcile `packaging-deployment`, `app-distribution-lifecycle`, `host-lifecycle-adapters`, and `platform-profiles` accepted specs.
- [x] 2.2 Add ADR 0027, mark ADR 0018 superseded without rewriting its historical body, and qualify ADR 0023's affected clause.
- [x] 2.3 Delete the abandoned active `managed-node-agent-handover` change instead of archiving it.
- [x] 2.4 Declare the removed, renamed, added, and modified requirements explicitly in this change's spec deltas.
- [x] 2.5 Record the `orchardctl start` job-domain enable and the non-persistent `orchardctl stop` in ADR 0027 and `design.md`.

## 3. Active changes and documentation

- [x] 3.1 Reconcile active release-governance, operator-journey, and product-licensing change packages that still assume native PKG.
- [x] 3.2 Reconcile `AGENTS.md`, `README.md`, tooling, process, architecture, glossary, security, local-development, operator-journey, and docs navigation guidance.
- [x] 3.3 Preserve historical archives and classify non-normative milestone and decision references as intentional history.
- [x] 3.4 Move installer-independent transport, TLS, CORS, Console, environment-file, and upgrade-rollout operator documentation into `packaging/README.md` and retarget every pointer to it.

## 4. Retained regression coverage

- [x] 4.1 Keep wrapper regression coverage for `packaging/payload/bin/orchard-controller`, `orchard-node-agent`, and `orchard-managed-postgres`.
- [x] 4.2 Keep payload signing, verification, and Mach-O closure regression coverage for `scripts/sign-payload.sh`, `scripts/verify-payload-signing.sh`, and `scripts/remediate-otp-openssl-closure.sh`.
- [x] 4.3 Make the payload build gate run `scripts/build-payload.sh` and assert the emitted `PAYLOAD_ROOT=` handoff and staged tree instead of inspecting help text.

## 5. Validation

- [x] 5.1 Run strict OpenSpec validation for `remove-native-pkg-distribution`.
- [x] 5.2 Run strict OpenSpec validation for all changes and accepted specs.
- [x] 5.3 Run residual searches for native PKG and managed handover claims across active normative and operator-facing files.
- [x] 5.4 Inspect and classify every remaining match as superseded history, archived history, explicit non-support language, legacy implementation residue, or unrelated use of handover vocabulary.
