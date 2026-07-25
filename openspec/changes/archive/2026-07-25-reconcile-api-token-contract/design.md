## Context

`SPEC.md` §10.2 requires canonical API Tokens, exactly 32 random secret bytes, secret-component SHA-256 semantics, constant-time verification, and hash-only persistence.
The shared `ApiKeySecret` codec instead emits `orch_<public>.<secret>` credentials with 24 secret bytes and hashes the complete token.
Already-issued credentials cannot be rehashed because Orchard intentionally does not retain their plaintext.

The first-admin implementation reuses the shared codec.
Its checked race and log-redaction tasks do not yet prove contention across independent PostgreSQL sessions or capture logs around successful and failed secret delivery.

## Goals / Non-Goals

**Goals:**

- Issue new API Tokens using one unambiguous canonical grammar.
- Preserve already-issued credentials without a database migration or forced rotation.
- Keep constant-time verification and the existing versioned hash envelope.
- Prove the first-admin one-shot guard with independent PostgreSQL sessions.
- Prove plaintext credentials are absent from captured logs on success and post-mint output failure.

**Non-Goals:**

- Retiring legacy credentials.
- Changing the `api_keys` schema.
- Changing CLI field names or Console behavior.
- Changing node-enrollment, peer-grant, packaging, release, or dispatch contracts.
- Archiving `first-admin-cluster-init`.

## Decisions

### Canonical issuance

New tokens use `orchard_sk_<public>_<secret>`.
The public component is the canonical unpadded base64url encoding of 12 random bytes and is therefore exactly 16 characters.
The secret component is the canonical unpadded base64url encoding of 32 random bytes and is therefore exactly 43 characters.
The persisted and displayed prefix is `orchard_kp_<public>`.
Fixed lengths make the underscore-delimited grammar unambiguous.

The canonical hash input is the exact encoded 43-character secret component.
The stored representation remains `sha256$<unpadded-base64url-digest>`.

### Legacy compatibility

Authentication continues to accept `orch_<public>.<secret>` credentials indefinitely.
Legacy lookup uses the existing `orch_<public>` prefix and legacy verification hashes the complete presented token.
The presented namespace selects exactly one parse and hash-input path.
Verification never tries multiple hash inputs.

No database migration or format-discriminator column is required because the namespaces are disjoint and the existing text fields accommodate both representations.

### Canonical-only generation

The configurable Governance generator remains a test seam, but generated credentials must pass canonical-only validation before persistence.
The general parser remains dual-format for authentication and audit lookup.

### First-admin evidence

The race regression uses separate `Sandbox.unboxed_run/2` sessions, proves they have distinct PostgreSQL backend process identifiers, and observes both mint sessions waiting on a held bootstrap advisory lock before releasing contention.
Committed fixtures are cleaned explicitly without removing the legacy Tenant.

Cluster CLI output operations use a configurable file-operations module that defaults to `File`.
Tests can allow preflight and then force final publication failure after minting.
Captured logs, returned output, and audit data must exclude the plaintext credential.
Successful publication leaves one intentional plaintext pathname, while failed publication inspects residual files and reports confirmed logical containment or unresolved containment without claiming guaranteed erasure under arbitrary filesystem refusal.

## Risks / Trade-offs

- **Old-binary rollback cannot authenticate newly issued canonical tokens**: restore the dual-read binary or revoke and reissue canonical credentials after a permanent rollback.
- **Indefinite legacy reads retain two verification paths**: keep format selection centralized in `ApiKeySecret` and cover both paths with independent expected hashes.
- **Unboxed race tests commit fixtures**: use narrow explicit cleanup before and after the test.
- **File-operation injection can widen production code**: keep the seam local to Cluster CLI and default it directly to `File`.

## Migration Plan

Deploy the dual-read implementation before issuing canonical credentials.
Existing rows remain unchanged and continue authenticating.
New rows use `orchard_kp` prefixes and secret-component hashes.
No schema or data migration runs.

## Open Questions

None.
