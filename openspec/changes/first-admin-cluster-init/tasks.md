## 1. Governance bootstrap

- [ ] 1.1 Implement `Orchard.Governance.ClusterBootstrap` with `mint_first_admin/1` and `mint_recovery_admin/1`: single transaction with a race-safe one-shot guard (refuse when an enabled cluster-scoped `admin` RoleBinding exists; guard skipped for recovery), creating the service account API Client (default name overridable via `--client-name`), the API Token via `ApiKeySecret` (hash and prefix persisted only), the ADR 0004 RoleBinding shape, and a cluster-scoped audit event; return the secret exactly once.
- [ ] 1.2 Reuse or cleanly extract shared logic from `ApiClientProvisioning` where applicable instead of duplicating it.

## 2. CLI

- [ ] 2.1 Replace the deferred `orchardctl cluster init` stub with the real command: `--output` (required for apply), `--json`, `--client-name`, `--force-new-admin`, `--yes`; local controller-runtime execution with the shared leader-only write gate; stable human and JSON output contracts; output preflight before minting per the one-time secret pattern.
- [ ] 2.2 Post-setup guidance in successful output: provision named admin API Clients, then revoke the bootstrap credential.

## 3. Tests

- [ ] 3.1 Governance tests: happy path with exact ADR 0004 binding shape; one-shot guard; guard race safety; recovery path adds without mutating existing credentials; hash-only persistence; audit event; non-leader refusal. Cite SPEC §11.9 and §10.2 where natural.
- [ ] 3.2 CLI tests: output preflight failure before any mint; `cluster_already_initialized` error contract; `--force-new-admin` confirmation gate; JSON contract stability; secret emitted exactly once and never logged.

## 4. Validation

- [ ] 4.1 Full Elixir workflow (format, compile --warnings-as-errors, credo --strict, dialyzer, test, test --cover) plus strict OpenSpec validation for this change.
