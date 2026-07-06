## 1. Governance bootstrap

- [x] 1.1 Implement `Orchard.Governance.ClusterBootstrap` with `mint_first_admin/1` and `mint_recovery_admin/1`: single transaction with a race-safe one-shot guard (refuse when an enabled cluster-scoped `admin` RoleBinding exists; guard skipped for recovery), creating the service account API Client (default name overridable via `--client-name`), the API Token via `ApiKeySecret` (hash and prefix persisted only), the ADR 0004 RoleBinding shape, and a cluster-scoped audit event; return the secret exactly once.
  Completion note: Added `Orchard.Governance.ClusterBootstrap` with advisory-lock guarded first-admin minting, additive recovery minting, hash-only token persistence, exact cluster-admin RoleBinding shape, cluster audit, and output-failure audit support.
- [x] 1.2 Reuse or cleanly extract shared logic from `ApiClientProvisioning` where applicable instead of duplicating it.
  Completion note: Reused the existing governance schemas, `ApiKeySecret`, `AuditLog`, and one-time-secret output/audit precedent while keeping the first-admin transaction scoped to the new bootstrap module.

## 2. CLI

- [x] 2.1 Replace the deferred `orchardctl cluster init` stub with the real command: `--output` (required for apply), `--json`, `--client-name`, `--force-new-admin`, `--yes`; local controller-runtime execution with the shared leader-only write gate; stable human and JSON output contracts; output preflight before minting per the one-time secret pattern.
  Completion note: Replaced the deferred stub with real `cluster init` parsing, required output preflight, leader-gated minting, stable errors, human output, JSON output, recovery confirmation, and one-time secret file delivery.
- [x] 2.2 Post-setup guidance in successful output: provision named admin API Clients, then revoke the bootstrap credential.
  Completion note: Human and JSON success output now include named-admin provisioning and bootstrap credential revocation guidance.

## 3. Tests

- [x] 3.1 Governance tests: happy path with exact ADR 0004 binding shape; one-shot guard; guard race safety; recovery path adds without mutating existing credentials; hash-only persistence; audit event; non-leader refusal. Cite SPEC §11.9 and §10.2 where natural.
  Completion note: Added governance tests for fresh minting, stable second-init refusal, concurrent guard race safety, additive recovery, hash-only persistence, cluster audit, and shared write-gate refusal.
- [x] 3.2 CLI tests: output preflight failure before any mint; `cluster_already_initialized` error contract; `--force-new-admin` confirmation gate; JSON contract stability; secret emitted exactly once and never logged.
  Completion note: Added CLI tests for output preflight, JSON success shape, one-time secret file content, stdout secret suppression, stable second-init error, and recovery confirmation.

## 4. Validation

- [x] 4.1 Full Elixir workflow (format, compile --warnings-as-errors, credo --strict, dialyzer, test, test --cover) plus strict OpenSpec validation for this change.
  Completion note: Completed format, compile, Credo strict, Dialyzer, full test, and coverage locally before checking this item; strict OpenSpec validation follows this task update.
