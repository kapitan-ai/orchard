# Operator API uses operator-or-admin cluster-scoped service-account tokens

Accepted.

Amendment accepted by Najib on 2026-11-12: [ADR 0042](0042-read-only-cluster-role.md) and `SPEC.md` §§7.3 and 10.4 add an accepted but inactive API-Client-only `cluster_reader` exception for exactly eight bounded GETs. It does not admit the whole Operator pipeline or writes/previews. Activation requires the shared-authority prerequisites and reader verification; the operator/admin boundary below and existing behavior remain unchanged. Public inference authority alone remains insufficient, while additive mixed grants follow ADR 0042's action-specific path and transmission re-selection rules.

Operator API requests are cluster runtime-operations calls and require a service-account-owned API Token whose owning API Client is enabled and holds a cluster-scoped `operator` or `admin` RoleBinding with `tenant_scope_id = nil`.
Tenant-direct API Keys and tenant-scoped Access Levels such as `inference_client` and `tenant_admin` do not authorize Operator API access.
Public inference credentials do not authorize Operator API access.
Unauthenticated callers receive `401 invalid_api_key`; authenticated non-operator principals receive `403 operator_required`.

This extends ADR 0004's service-account bearer boundary to the narrower operator surface that ADR 0004 deferred.
Admin-role principals retain Operator API access because cluster admin is a superset of operator.
The admin and operator request-context plugs share one parameterized bearer-auth base so the two surfaces cannot drift.

The trade-off is a second cluster-scoped bearer boundary that must stay fail-closed against tenant and public credentials.
API Client disablement remains the single kill switch for both Admin and Operator service-account tokens.

SPEC.md impact: `SPEC.md` §7.3 records the Operator API authentication boundary and its 401/403 codes.
