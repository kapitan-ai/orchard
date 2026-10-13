## 1. Contract shaping

- [x] 1.1 Reconcile `SPEC.md` Node lifecycle, Action Preview, capacity, trust, audit, CLI, and Ubuntu single-host requirements.
- [x] 1.2 Add proposed ADR 0038 with exact authority, atomicity, fallback, race, replay, recovery, and ownership boundaries.
- [x] 1.3 Add OpenSpec proposal, design, deterministic scenarios, capability deltas, and threat/failure analysis.
- [x] 1.4 Reconcile active operator-first-run, Console enrollment, and cluster-management wording while preserving manual admission as default.
- [x] 1.5 Record Repository Owner acceptance of exact contract commit `5544533123d494d3c124e3f5c44373db74be2c96`; implementation remains separately gated.

## 2. Separately authorized persistence and issuance slice

- [x] 2.1 Add the versioned preauthorization record, closed state constraints, exact foreign keys, immutable policy/revision fields, terminal evidence, and retention behavior.
- [x] 2.2 Add explicit Controller mode configuration with `manual` default and fail-closed parsing; mode enablement alone must authorize nothing.
- [x] 2.3 Extend Enrollment issuance with side-effect-free preview, confirmation, exact policy/revision binding, leader-only write, non-secret bundle correlation, and atomic audit.
- [x] 2.4 Add previewed, confirmed, audited revocation and deterministic expiry classification without mutating already admitted Nodes.

## 3. Separately authorized redemption slice

- [x] 3.1 Compose Enrollment and admission validation under the documented lock order and current leader/write gate.
- [x] 3.2 Commit full registration, admission, decision, capacity policy, audit, consumption, and initial pending-grant metadata atomically.
- [x] 3.3 Commit only registered pending review for independently valid Enrollment with admission-only drift; reject identity, trust, or write-authority failure.
- [x] 3.4 Implement one-winner concurrency, exact idempotent response-loss replay, divergent replay refusal, and restart reconciliation from durable state.

## 4. Separately authorized operator and security slice

- [x] 4.1 Add stable human/JSON issuance, revoke, join-success, pending-review, replay, and diagnostic output with secret redaction.
- [x] 4.2 Add the bounded deterministic acceptance matrix for manual default, successful preauthorization, exact replay, revocation, preauthorization-before-Enrollment expiry, terminal-state pending review, admission-only drift, full and pending-review rollback, and lock-overlapped exact-redemption concurrency in isolated PostgreSQL.
- [ ] 4.2a As separately prioritized deferred hardening, add exhaustive per-bound-field mismatch, mode-disablement, expiry/revocation and Controller-membership race, phase/policy drift, divergent concurrent redemption, response-loss, Controller-restart, Node-restart, and same-host non-bypass scenarios. The Repository Owner explicitly accepted KAP-109 without making this matrix a KAP-100 blocker.
- [x] 4.3 Run full Elixir, migration, security, targeted/all strict OpenSpec, and coverage validation without real credential issuance or host mutation unless separately authorized. Migration, focused and affected suites, the repository-wide portable suite, static checks, targeted/all strict OpenSpec, and changed-surface coverage pass in the owner-authorized disposable PostgreSQL environment.
- [x] 4.4 Record the Repository Owner's 2026-09-21 acceptance of exact KAP-109 implementation and validation commit `31b7186a46decf1edd609d3bdafeb7fd76d5d690`. KAP-100 may consume the capability, but its execution and every real-host action remain separately gated.
