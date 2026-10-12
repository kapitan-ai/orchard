## 1. Contract and implementation

- [x] 1.1 Reconcile SPEC.md and Linux Node documentation with the precise runtime-target seam and additive compatibility behavior
- [x] 1.2 Implement bounded pure allowlist projection and existing runtime snapshot/NodeStatus integration
- [x] 1.3 Test positive CPU/vendor observations, missing and invalid evidence, timestamps, size bounds, redaction, integration parity and unchanged authority/persistence
- [x] 1.4 Expose re-normalized diagnostics in the existing authenticated operator health response and test response-level redaction, freshness, failure suppression, authorization, public readiness and the single runtime read

## 2. Validation

- [x] 2.1 Run strict OpenSpec validation before implementation and at handoff
- [x] 2.2 Run the ordered Elixir quality workflow, tests, coverage and diff checks on the final operator-facing implementation

This change is only the inventory and health/lifecycle observation tranche. Task 3.3 in reconcile-linux-node-source-dev-contract remains incomplete: broader logs and metrics diagnostics and candidate qualification remain deferred.
