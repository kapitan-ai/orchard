# Service-account-owned bulk API access

Accepted.

Bulk API access provisioning will create service-account-owned API Tokens by default, using the canonical API Key schema and the product labels API Clients and API Tokens in operator-facing surfaces.
Owner Contact and Team are descriptive API Client metadata only; they do not authenticate, authorize, own quota, or define routing policy.
Tenant-direct API Keys remain supported for manual, bootstrap, and compatibility paths, but bulk provisioning uses API Clients so Orchard can audit, disable, and rotate non-interactive client access without introducing first-class human users.
A Portal User is a portal-scoped interactive identity, not a bulk-provisioning identity, and does not weaken this decision for API Clients, Owner Contacts, or non-interactive access.
Each bulk-provisioned API Client receives an explicit tenant-scoped `inference_client` Access Level by default.
The first provisioning surface is CLI-first so One-time Secret Output can be written to an operator-chosen local file.
Console may show and manage Organizations, Teams, API Clients, Owner Contacts, API Token prefixes, revocation, and API Client Disablement, but bulk secret export does not require an Admin API endpoint in the first slice.
The bulk provisioning CSV requires `organization`, `api_client`, `owner_contact`, and `key_name`.
It may include `team`, `owner_name`, `external_ref`, `description`, `purpose`, `expires_at`, and `metadata_json`.
Token expiry is encouraged but not required in the first slice so internal rollout is not blocked before a rotation process exists.

Quotas, queues, model access, usage accounting, and retention remain Tenant-scoped for this change.
API Client Disablement blocks all owned API Tokens without mutating each token's revoked state.
Calls using a valid token owned by a disabled API Client return `403 forbidden`, while missing, malformed, invalid, expired, or revoked tokens remain `401 invalid_api_key`.

The first implementation stores API Clients in `service_accounts`, tenant-direct and service-account-owned credentials in `api_keys`, Access Levels in `role_bindings`, and non-secret bulk run metadata in `provisioning_batches`.
The first implementation exposes bulk provisioning through `orchardctl api-clients bulk-provision` with Dry Run, Apply, output preflight, and explicit Key Rotation mode.
The first implementation exposes Console visibility and management through the Organization detail page without adding a bulk Admin API endpoint.
