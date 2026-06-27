## ADDED Requirements

### Requirement: API Clients are non-interactive principals
Orchard SHALL support API Clients as product-facing Service Accounts within an Organization.
An API Client SHALL be a non-interactive principal that may own API Tokens and tenant-scoped Access Levels.
Owner Contact and Team SHALL be metadata on the API Client and SHALL NOT authenticate, authorize, own quota, define model access, define routing policy, or create a nested Tenant.
This changes `SPEC.md` §10.3 and §10.4 by making the service-account principal path the default for bulk-provisioned public inference access.

#### Scenario: API Client metadata does not create identity
- **WHEN** an operator provisions an API Client with Owner Contact `alice@example.com` and Team `Platform`
- **THEN** Orchard records those values as API Client metadata only
- **AND** Orchard does not create a human user, Tenant, role principal, quota boundary, routing policy, or login identity from those values

### Requirement: Bulk provisioning creates service-account-owned API Tokens
Bulk provisioning SHALL create service-account-owned API Tokens by default.
Tenant-direct API Keys SHALL remain valid for manual, bootstrap, and compatibility paths, but SHALL NOT be the default output of the bulk provisioning workflow.
This changes `SPEC.md` §7.4.4, §8.2, §10.2, and §10.3 by requiring bulk-created credentials to resolve through Service Account ownership.

#### Scenario: Bulk row creates API Client and API Token
- **WHEN** an operator applies a valid bulk provisioning row for Organization `acme`, API Client `alice-codex-dev`, Owner Contact `alice@example.com`, and key name `default`
- **THEN** Orchard creates or updates the API Client inside Organization `acme`
- **AND** Orchard creates an API Token owned by that API Client
- **AND** Orchard does not create a tenant-direct API Key for that row

### Requirement: Bulk provisioning uses stable API Client identity and safe token creation
Bulk provisioning SHALL match API Clients by Organization plus External Reference when an External Reference is present.
Bulk provisioning SHALL otherwise match API Clients by Organization plus API Client name.
Bulk provisioning SHALL NOT silently create duplicate active API Tokens when the same API Client and key name already have an active token.
Bulk provisioning SHALL reject rows targeting disabled API Clients.
Replacement token creation SHALL require an explicit Key Rotation mode.
This changes `SPEC.md` §10.2 and §10.9 by defining safe repeated provisioning behavior.

#### Scenario: Repeated import updates API Client metadata without duplicate token
- **WHEN** an operator reapplies a bulk provisioning file that references an existing API Client and an existing active key name without Key Rotation mode
- **THEN** Orchard updates allowed API Client metadata changes
- **AND** Orchard rejects the duplicate token operation before creating any new token secret

### Requirement: Bulk provisioning supports dry run and all-or-nothing apply
The bulk provisioning CLI SHALL support Dry Run and Apply modes.
Dry Run SHALL validate the entire input, duplicate behavior, referenced Organizations, API Client identity, API Token names, optional expiry values, JSON metadata, and output destination readiness without mutating state or generating token secrets.
Apply SHALL reject the entire batch before creating token secrets when validation fails.
Apply SHALL commit all validated provisioning changes as one batch or roll back the batch on failure.
Post-commit One-time Secret Output delivery failure SHALL mark the Provisioning Batch `output_failed`, emit a redacted audit event, and return API Token prefixes for revocation or rotation.
This changes `SPEC.md` §7.4.4 and §10.9 by defining the operator workflow and failure behavior for bulk credential creation.

#### Scenario: Invalid row prevents all secret generation
- **WHEN** an operator runs Apply with a bulk provisioning file that contains one invalid row
- **THEN** Orchard rejects the batch
- **AND** Orchard creates no API Clients
- **AND** Orchard creates no API Tokens
- **AND** Orchard emits no One-time Secret Output

### Requirement: Bulk provisioning input has a stable CSV contract
The bulk provisioning CSV input SHALL require `organization`, `api_client`, `owner_contact`, and `key_name`.
The bulk provisioning CSV input MAY include `team`, `owner_name`, `external_ref`, `description`, `purpose`, `expires_at`, and `metadata_json`.
Plaintext API Token secrets MUST NOT be accepted in the input file.
Token expiry SHALL be supported but SHALL NOT be required in the first slice.
Repeated provisioning SHALL preserve omitted optional API Client metadata columns, clear present blank optional scalar metadata columns, and replace metadata when `metadata_json` is present.
This changes `SPEC.md` §7.4.4 and §10.2 by defining the operator input contract for bulk API Token creation.

#### Scenario: CSV with required fields is accepted
- **WHEN** an operator validates a CSV row with `organization`, `api_client`, `owner_contact`, and `key_name`
- **THEN** Orchard accepts the row shape for semantic validation
- **AND** Orchard treats absent `expires_at` as allowed by the first-slice contract

### Requirement: One-time Secret Output is never persisted
Orchard SHALL display or export plaintext API Token secrets only as One-time Secret Output after successful API Token creation.
Orchard MUST NOT persist plaintext token secrets in Postgres, audit logs, provisioning batches, Console assigns after dismissal, support bundles, local evidence logs, or raw OpenSpec artifacts.
The bulk provisioning CLI SHALL validate the operator-chosen output path before mutating state.
The bulk provisioning CLI SHALL support `--json` summaries without writing plaintext API Tokens to stdout.
One-time Secret Output CSV SHALL include `organization`, `api_client`, `external_ref`, `key_name`, `api_token_id`, `api_token_prefix`, `api_token`, and `expires_at`.
This changes `SPEC.md` §7.4.4, §10.2, §10.9, and §11.9 by defining secret handling for bulk token creation.

#### Scenario: Successful apply writes sensitive output once
- **WHEN** an operator applies a valid bulk provisioning batch with an output CSV path
- **THEN** Orchard persists only token prefixes and secret hashes
- **AND** Orchard writes plaintext API Token secrets to the chosen output file once
- **AND** Orchard excludes plaintext API Token secrets from audit payloads and provisioning batch records

#### Scenario: Output delivery failure preserves recovery evidence without plaintext
- **WHEN** an operator applies a valid bulk provisioning batch and the output file cannot be written after persistence succeeds
- **THEN** Orchard marks the Provisioning Batch `output_failed`
- **AND** Orchard emits a redacted output-failed audit event
- **AND** Orchard returns API Token prefixes for revocation or rotation
- **AND** Orchard does not persist plaintext API Token secrets

### Requirement: API Clients receive explicit inference access
Bulk provisioning SHALL assign each created or updated API Client an explicit tenant-scoped `inference_client` Access Level by default.
Public `/v1/chat/completions` and `/v1/responses` requests authenticated by a service-account-owned API Token SHALL require the owning API Client to have the `inference_client` Access Level for the effective Tenant.
This changes `SPEC.md` §5.2 and §10.4 by making endpoint authorization explicit for API Client principals.

#### Scenario: API Client can call inference after role assignment
- **WHEN** a request to `/v1/responses` uses a valid API Token owned by an enabled API Client with tenant-scoped `inference_client` access
- **THEN** Orchard authenticates the API Token
- **AND** Orchard authorizes the API Client for public inference before model resolution and tenant quota admission

### Requirement: Request context resolves typed principals
Public inference request authentication SHALL resolve a typed principal for every valid API Token.
Tenant-direct API Keys SHALL resolve `principal_type` as `tenant`.
Service-account-owned API Tokens SHALL resolve `principal_type` as `service_account` and `principal_id` as the owning Service Account id.
The effective Tenant SHALL remain the Tenant used for model access, quota, queueing, usage accounting, retention, idempotency, and request persistence.
This changes `SPEC.md` §3.4, §5.2, §5.3, §8.2, and §10.3 by replacing temporary tenant-only principal semantics.

#### Scenario: Service-account-owned token resolves API Client principal
- **WHEN** a request uses a valid service-account-owned API Token
- **THEN** Orchard assigns the owning Tenant as the effective Tenant
- **AND** Orchard assigns the owning Service Account as the effective principal
- **AND** Orchard applies Tenant-scoped admission and accounting unchanged

### Requirement: API Client Disablement blocks owned tokens
Orchard SHALL support API Client Disablement.
An API Client Disablement SHALL immediately block all API Tokens owned by that API Client without mutating each token's revoked state.
A valid API Token owned by a disabled API Client SHALL authenticate as a known credential and fail authorization with `403 forbidden`.
Missing, malformed, invalid, expired, or revoked API Tokens SHALL fail authentication with `401 invalid_api_key`.
This changes `SPEC.md` §5.2, §7.2.2, §10.2, and §10.3 by distinguishing credential validity from principal authorization.

#### Scenario: Disabled API Client returns forbidden
- **WHEN** a request uses a valid, unrevoked, unexpired API Token owned by a disabled API Client
- **THEN** Orchard rejects the request before model resolution
- **AND** Orchard returns `403 forbidden` with a sanitized disabled-principal error code

### Requirement: Provisioning batches and audits contain no secrets
Orchard SHALL record non-secret Provisioning Batch metadata for bulk provisioning Apply runs.
Provisioning Batch metadata SHALL include tenant identity, actor identity when available, status, row counts, started and completed timestamps, and non-secret error summary.
Audit events SHALL cover batch start, batch completion or failure, API Client creation or update, Access Level assignment, API Token creation, API Token revocation during Key Rotation, and API Client Disablement.
Audit payloads MUST NOT include plaintext token secrets or raw input CSV content.
This changes `SPEC.md` §10.9 by adding bulk provisioning audit requirements.

#### Scenario: Batch audit omits token secrets
- **WHEN** a bulk provisioning batch creates API Tokens
- **THEN** Orchard records batch and per-action audit evidence
- **AND** each audit payload may include token prefix, API Client id, Owner Contact snapshot, Team, and batch id
- **AND** no audit payload includes a plaintext API Token secret

### Requirement: Console surfaces API Client management without bulk secret export
Orchard Console SHALL show Organizations, API Clients, Team metadata, Owner Contact metadata, API Token prefixes, creation timestamps, last-used timestamps, revocation state, expiry state, and API Client Disablement state.
Orchard Console SHALL allow operators with sufficient access to revoke API Tokens and disable API Clients.
The first slice SHALL NOT require Console bulk secret export or a bulk Admin API endpoint.
This changes `SPEC.md` §2.3 and §10.3 by defining the initial Console management surface for API Client access.

#### Scenario: Console shows API Client token provenance
- **WHEN** an operator opens an Organization's API Client management view
- **THEN** Orchard Console shows each API Client with Team and Owner Contact metadata
- **AND** Orchard Console shows owned API Tokens by prefix without plaintext token secrets
