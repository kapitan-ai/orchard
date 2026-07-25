## 1. Canonical API Token contract

- [x] 1.1 Clarify `SPEC.md` §10.2 with the canonical component grammar, `orchard_kp` prefix mapping, encoded-secret hash input, and indefinite legacy compatibility.
- [x] 1.2 Implement canonical API Token generation and parsing with at least 32 random secret bytes, constant-time verification, and exact legacy verification compatibility.

## 2. Governance and authentication

- [x] 2.1 Require canonical-only new issuance while preserving canonical and legacy authentication and failure-audit lookup through `Orchard.Governance`.
- [x] 2.2 Prove legacy compatibility through the public request-context seam without duplicating the complete codec matrix in consumers.

## 3. First-admin regression evidence

- [x] 3.1 Prove canonical first-admin minting and race safety across independent PostgreSQL sessions with distinct backend process identifiers.
- [x] 3.2 Prove successful and post-mint output-failure paths exclude plaintext credentials from captured logs, returned output, and audits; inspect residual files and distinguish confirmed logical containment from unresolved containment under injected filesystem refusal.

## 4. Validation and review

- [x] 4.1 Run focused token, authentication, first-admin, and CLI tests.
- [x] 4.2 Run the full Elixir quality and coverage workflow, strict validation for both active changes and all OpenSpec content, and `git diff --check`.
- [x] 4.3 Run exact-head RepoPrompt Review and Oracle, resolve any patch-caused P0 or P1, and verify no generated placeholder prose remains.
