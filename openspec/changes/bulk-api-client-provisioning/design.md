## Context

Orchard currently authenticates public `/v1/*` calls with tenant-scoped Bearer API Keys.
The current implementation stores tenants, API keys, and audit logs, and temporarily resolves `principal_id` to the tenant id.
`SPEC.md` already describes service accounts, role bindings, API key status and expiry, and RBAC, but the implementation has not yet built those pieces.

The user-facing need is easier rollout for several internal developers, applications, coding agents, and automation clients inside the same organization or team.
The design keeps Tenant as the governance boundary and uses API Clients as the product-facing label for service accounts.
Owner Contact and Team are metadata only, not Orchard users or nested tenant boundaries.

## Goals / Non-Goals

**Goals:**

- Bulk provision API Clients, owner metadata, and service-account-owned API Tokens for public inference.
- Preserve Tenant-scoped quotas, queues, model access, usage accounting, and retention.
- Resolve service-account-owned API Token calls to a typed API Client principal.
- Provide CLI-first dry-run and apply workflows with one-time token output.
- Expose enough Console management to inspect, revoke, and disable API access safely.
- Record non-secret batch, API Client, Access Level, and API Token audit evidence.

**Non-Goals:**

- Do not add first-class human users, login, invitations, self-service token creation, SSO, or SCIM.
- Do not make Team a first-class table or a quota, routing, retention, or model-access boundary.
- Do not add service-account-scoped quotas in this change.
- Do not auto-migrate existing tenant-direct API Keys.
- Do not require a bulk Admin API endpoint for the first implementation slice.

## Decisions

1. Bulk provisioning creates service-account-owned API Tokens by default.
Tenant-direct API Keys remain supported for manual, bootstrap, and compatibility use.
This avoids inventing human user identity while making non-interactive clients auditable and disableable.

2. Product surfaces use friendly labels while code and specs preserve canonical vocabulary.
Tenant is labeled Organization, Service Account is labeled API Client, API Key is labeled API Token, RBAC Role is labeled Access Level, and Service Account owner metadata is labeled Owner Contact.
This makes the Console and CLI easier to understand without weakening the domain model.

3. Owner Contact and Team live on API Client metadata.
API Tokens carry credential lifecycle fields such as name, prefix, expiry, last-used timestamp, and revoked timestamp.
This keeps ownership stable across token rotation.

4. Bulk provisioning upserts API Clients but does not silently duplicate API Tokens.
Repeated imports match API Clients by Organization plus External Reference when present, otherwise by Organization plus API Client name.
Creating another active token with the same name requires an explicit rotation mode.

5. Bulk provisioning is CLI-first with all-or-nothing apply.
Dry run validates the whole input and output destination before any mutation or token generation.
Apply creates all records in one transaction and writes One-time Secret Output only after successful persistence.
If One-time Secret Output delivery fails after successful persistence, Apply marks the Provisioning Batch `output_failed`, emits a redacted audit event, and returns API Token prefixes for revocation or rotation.

6. API Client Disablement blocks owned API Tokens without mutating each token.
This separates principal lifecycle from credential lifecycle and preserves rotation and revocation history.
Valid tokens owned by disabled API Clients fail authorization with `403 forbidden`.
Missing, malformed, invalid, expired, or revoked tokens fail authentication with `401 invalid_api_key`.

7. Bulk-provisioned API Clients receive an explicit tenant-scoped `inference_client` Access Level by default.
This follows the RBAC model already described by `SPEC.md` and avoids implicit inference permission rules.

8. Existing Tenant-scoped admission behavior remains unchanged.
The effective principal changes for service-account-owned API Tokens, but effective tenant remains the admission, quota, queue, model-access, accounting, and retention boundary.

## Risks / Trade-offs

- Plaintext token leakage during bulk output -> Validate the output path before mutation, never persist plaintext tokens, redact support bundles, and document the output file as sensitive.
- Partial import ambiguity -> Require dry-run validation and all-or-nothing apply semantics.
- Credential sprawl from repeated CSV runs -> Upsert API Clients and require explicit rotation for duplicate active token names.
- Friendly labels drifting from canonical terms -> Keep glossary mappings and use canonical terms in code, schemas, and SPEC reconciliation.
- Disabled API Client behavior can reveal that a token was valid -> Return only sanitized `403 forbidden` details and avoid exposing owner metadata or service-account internals in public errors.
- Introducing role bindings broadens implementation scope -> Keep only tenant-scoped `inference_client` role creation and public endpoint authorization in this slice.

## Migration Plan

1. Add schema migrations for service accounts, role bindings, API key ownership, optional expiry, and provisioning batch metadata.
2. Preserve existing tenant-direct API Keys and their current authentication behavior.
3. Extend request context to resolve `principal_type` as `tenant` or `service_account`.
4. Add authorization checks for explicit `inference_client` Access Level before public inference admission.
5. Add CLI bulk dry-run and apply commands.
6. Add Console visibility and management for API Clients and their API Tokens.
7. Add tests before enabling the new workflow in handoff documentation.

Rollback keeps existing tenant-direct API Key behavior available.
If the new schema must be disabled operationally, operators can stop using the bulk provisioning command and continue using existing tenant-direct key creation while data remains inert.

## Open Questions

None for the first proposal.
Future work can revisit SCIM, first-class users, per-principal quotas, and Console-driven bulk import after API Client provisioning is proven.
