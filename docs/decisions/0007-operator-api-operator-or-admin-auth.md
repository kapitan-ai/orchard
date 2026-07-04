# Operator API uses operator-or-admin cluster-scoped service-account tokens

Accepted.

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
