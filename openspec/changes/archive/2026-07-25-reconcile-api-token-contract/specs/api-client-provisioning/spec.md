## ADDED Requirements

### Requirement: API Tokens use canonical issuance with legacy authentication compatibility
New API Tokens SHALL use the `orchard_sk_<public>_<secret>` format defined by `SPEC.md` §10.2.
The public component SHALL be the canonical unpadded base64url encoding of 12 random bytes.
The secret component SHALL be the canonical unpadded base64url encoding of exactly 32 random bytes.
The persisted and displayed token prefix SHALL be `orchard_kp_<public>`.
Orchard SHALL persist a versioned SHA-256 digest of the exact encoded secret component and SHALL compare digests in constant time.
Orchard SHALL continue authenticating already-issued `orch_<public>.<secret>` credentials by their existing prefix and complete-token hash semantics.
Legacy compatibility SHALL NOT require a database migration or forced credential rotation.

#### Scenario: New credential uses the canonical contract
- **WHEN** Orchard creates a tenant-direct, API Client, bulk-provisioned, or first-admin API Token
- **THEN** the credential uses the canonical `orchard_sk` grammar with exactly 32 random secret bytes
- **AND** Orchard persists the corresponding `orchard_kp` prefix and secret-component digest only

#### Scenario: Existing credential remains valid
- **WHEN** an API request presents an existing valid `orch_<public>.<secret>` credential
- **THEN** Orchard resolves its existing persisted prefix
- **AND** Orchard verifies its existing complete-token digest in constant time
- **AND** Orchard does not rewrite the credential row

### Requirement: First-admin evidence covers independent contention and secret redaction
The first-admin one-shot guard SHALL be tested through independent PostgreSQL sessions.
Successful and failed first-admin One-time Secret Output delivery SHALL capture logs and prove that plaintext API Token credentials are absent.
Post-mint output failure diagnostics and durable control-plane recovery evidence SHALL contain no plaintext API Token.

#### Scenario: Concurrent initialization uses independent sessions
- **WHEN** two first-admin initialization attempts race on distinct PostgreSQL sessions
- **THEN** exactly one attempt succeeds
- **AND** the other attempt fails with `cluster_already_initialized`
- **AND** exactly one first-admin credential set persists

#### Scenario: Secret delivery paths do not log plaintext
- **WHEN** first-admin secret delivery succeeds or fails after minting
- **THEN** captured logs exclude the plaintext API Token
- **AND** returned output and audit records exclude the plaintext API Token
- **AND** successful publication leaves the operator-chosen output as the only intentional plaintext pathname
- **AND** failed publication reports confirmed logical containment or unresolved containment without claiming that arbitrary filesystem refusal erased all bytes
