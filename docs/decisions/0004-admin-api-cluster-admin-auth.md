# Admin API uses service-account-owned cluster admin tokens

Accepted.

Admin API requests are cluster control-plane operations and require a service-account-owned API Token whose owning API Client is enabled and has a cluster-scoped `admin` RoleBinding.
The required RoleBinding has `principal_type = :service_account`, `principal_id = service_account.id`, `role = :admin`, and `tenant_scope_id = nil`.
Tenant-direct API Keys do not authorize Admin API access.
Tenant-scoped Access Levels such as `inference_client` and `tenant_admin` do not authorize Admin API access.
The `operator` role does not authorize Admin API access unless a future decision explicitly grants a narrower operator surface.

This keeps public inference credentials, tenant-scoped automation credentials, and cluster administration credentials separate.
It also makes API Client disablement the single kill switch for service-account-owned Admin API tokens.

The first Admin API admission slice may seed admin credentials in tests and local setup code.
The operator-facing first-admin and cluster bootstrap workflow remains a separate `orchardctl cluster init`, bootstrap-token, or provisioning slice.

Amended 2026-07-06: the deferred first-admin workflow is now decided as local `orchardctl cluster init`, with the bootstrap-token and network-provisioning alternatives rejected; see ADR 0011.
