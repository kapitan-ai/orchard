## 1. Contract And Schema

- [x] 1.1 Reconcile accepted OpenSpec behavior back into `SPEC.md`, `docs/glossary/CONTEXT.md`, and `docs/decisions/0002-service-account-owned-bulk-api-access.md`.
- [x] 1.2 Add Postgres migrations for service accounts, role bindings, API key ownership, optional API key expiry, and non-secret provisioning batch metadata.
- [x] 1.3 Add or update Ecto schemas for API Clients, API Tokens, role bindings, and provisioning batches with changesets that reject plaintext token secrets.
- [x] 1.4 Preserve existing tenant-direct API Key rows and behavior without automatic migration.

## 2. Governance Domain

- [x] 2.1 Add Governance APIs for creating, updating, listing, disabling, and reading API Clients by Organization plus External Reference or API Client name.
- [x] 2.2 Add Governance APIs for creating service-account-owned API Tokens and rejecting duplicate active token names unless Key Rotation mode is explicit.
- [x] 2.3 Add Governance APIs for tenant-scoped `inference_client` Access Level assignment and lookup.
- [x] 2.4 Add Governance APIs for API Client Disablement that blocks owned API Tokens without mutating token revocation state.
- [x] 2.5 Add audit event creation for provisioning batches, API Client changes, Access Level assignment, API Token creation, API Token revocation, Key Rotation, and API Client Disablement.

## 3. Public API Auth And Authorization

- [x] 3.1 Extend API key authentication to resolve `principal_type` as `tenant` or `service_account`.
- [x] 3.2 Keep the effective Tenant as the Tenant-scoped admission, quota, queue, model-access, usage-accounting, retention, idempotency, and request-persistence boundary.
- [x] 3.3 Add public inference endpoint authorization that requires `inference_client` Access Level for API Client principals before model resolution and quota admission.
- [x] 3.4 Return `403 forbidden` for valid API Tokens owned by disabled API Clients, and keep `401 invalid_api_key` for missing, malformed, invalid, expired, or revoked API Tokens.
- [x] 3.5 Persist typed principal provenance on requests where the current request schema supports it, or add the minimum compatible persistence change needed by `SPEC.md`.

## 4. CLI Bulk Provisioning

- [x] 4.1 Add `orchardctl api-clients bulk-provision --dry-run --file <path>` validation for the required CSV fields `organization`, `api_client`, `owner_contact`, and `key_name`.
- [x] 4.2 Support optional CSV fields `team`, `owner_name`, `external_ref`, `description`, `purpose`, `expires_at`, and `metadata_json`.
- [x] 4.3 Add Apply mode that validates the output path before mutation and commits all changes as one batch.
- [x] 4.4 Write One-time Secret Output only after successful Apply and never store plaintext token secrets in Postgres, audit logs, provisioning batches, support bundles, or transient evidence artifacts.
- [x] 4.5 Add explicit Key Rotation mode for replacement API Token creation and previous-token revocation.
- [x] 4.6 Add CLI help and operator-safe error messages for dry-run failures, duplicate token names, disabled API Clients, invalid metadata JSON, invalid expiry values, and output path conflicts.

## 5. Console Management

- [x] 5.1 Add Console visibility for Organizations, API Clients, Team metadata, Owner Contacts, API Token prefixes, creation timestamps, last-used timestamps, revocation state, expiry state, and API Client Disablement state.
- [x] 5.2 Add Console actions for revoking API Tokens and disabling API Clients, scoped server-side to the selected Organization.
- [x] 5.3 Keep plaintext API Token secrets out of Console state except for existing one-time create flows, and clear any one-time secret assigns after dismissal or copy acknowledgement.
- [x] 5.4 Update Console copy, empty, error, and disabled states using `docs/DESIGN.md` guidance.

## 6. Tests And Validation

- [x] 6.1 Add governance tests for API Client upsert, metadata changes, duplicate token rejection, explicit Key Rotation, API Client Disablement, Access Level assignment, and audit payload redaction.
- [x] 6.2 Add public API tests for typed principal resolution, tenant-direct compatibility, service-account-owned API Token access, disabled API Client `403`, revoked/expired token `401`, and Tenant-scoped quota behavior.
- [x] 6.3 Add CLI tests for dry-run validation, all-or-nothing Apply, output path preflight, one-time secret output, duplicate rerun behavior, and redaction of plaintext tokens from errors.
- [x] 6.4 Add Console LiveView tests for API Client visibility, server-side Organization scoping, revoke action, disable action, and absence of plaintext token secrets in rendered historical rows.
- [x] 6.5 Run `OPENSPEC_TELEMETRY=0 npm run openspec -- validate bulk-api-client-provisioning --type change --strict --no-interactive`.
- [x] 6.6 Run `mise exec -- mix format`.
- [x] 6.7 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 6.8 Run `mise exec -- mix credo --strict`.
- [x] 6.9 Run `mise exec -- mix dialyzer`.
- [x] 6.10 Run `mise exec -- mix test`.
- [x] 6.11 Run `mise exec -- mix test --cover`.
- [x] 6.12 After archive or spec sync, review generated main specs for placeholder prose such as `Purpose TBD` and reconcile accepted behavior into durable docs and tests.
