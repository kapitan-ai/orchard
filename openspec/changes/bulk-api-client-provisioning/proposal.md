## Why

Operators need an easy, auditable way to provision many API callers for `/v1/chat/completions` and `/v1/responses` without creating separate tenants for every internal developer, app, coding agent, or automation.
Current Orchard API access is tenant-scoped and manual, which makes small team rollouts and agent access cumbersome and weakly attributable.

This change adds service-account-owned API access using product-facing labels that business and operator users can understand while preserving the existing Orchard domain model.
It has SPEC.md behavior impact for governance identity, API key ownership, authorization, audit, CLI provisioning, and Console visibility.

## What Changes

- Add API Client provisioning as the operator-facing workflow for creating service accounts, owner metadata, and service-account-owned API Tokens in bulk.
- Preserve Tenant as the canonical governance boundary while using Organization as the product-facing label.
- Preserve Service Account as the canonical non-interactive principal while using API Client as the product-facing label.
- Preserve API Key as the canonical bearer credential while using API Token as the product-facing label.
- Treat Team and Owner Contact as API Client metadata only; they do not authenticate, authorize, own quota, define routing policy, or create nested tenancy.
- Make bulk provisioning create service-account-owned API Keys by default and leave tenant-direct API Keys as a manual, bootstrap, and compatibility path.
- Require explicit tenant-scoped `inference_client` Access Level assignment for bulk-provisioned API Clients.
- Keep quotas, queues, model access, usage accounting, and retention Tenant-scoped for this slice.
- Add CLI-first bulk provisioning with dry-run and all-or-nothing apply semantics.
- Emit One-time Secret Output only after successful apply and never persist plaintext token secrets in Postgres, audit logs, import batches, Console state after dismissal, support bundles, or local evidence artifacts.
- Add API Client Disablement semantics: disabling an API Client blocks all owned API Tokens without mutating each token's revoked state.
- Return `403 forbidden` for valid tokens owned by disabled API Clients, while missing, malformed, invalid, expired, or revoked tokens remain `401 invalid_api_key`.
- Show API Clients, Teams, Owner Contacts, API Token prefixes, last-used timestamps, revocation, and disablement controls in Console without requiring a bulk Admin API endpoint in the first slice.

## Capabilities

### New Capabilities

- `api-client-provisioning`: Bulk operator provisioning, lifecycle, authorization, audit, and visibility for service-account-owned API access.

### Modified Capabilities

None.

## Impact

- Affected product contract: `SPEC.md` §2.1, §3.4, §5.2, §5.3, §7.4.3, §8.2, §8.3, §10.2, §10.3, §10.4, and §10.9.
- Affected glossary and decisions: `docs/glossary/CONTEXT.md` and `docs/decisions/0002-service-account-owned-bulk-api-access.md`.
- Affected controller code: governance schemas and services, request authentication context, authorization checks, audit log creation, and request persistence provenance.
- Affected CLI code: `orchardctl` bulk provisioning commands, dry-run validation, output-file handling, and key rotation guardrails.
- Affected Console code: tenant detail or governance views for API Clients, owner/team metadata, API Token management, and disablement/revocation actions.
- Affected data model: service accounts, API key ownership, role bindings, optional API key expiration, provisioning batches, and non-secret audit payloads.
- Public inference endpoints remain `/v1/chat/completions` and `/v1/responses`; request/response payload contracts for callers do not change.
