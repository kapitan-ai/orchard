# Cluster Admission Admin API Slice Plan

## Status

Accepted implementation plan for the initial cluster-management Admin API node-admission slice.
The implemented slice covers OpenSpec task `2.8` and preserves the explicit out-of-scope boundaries below for later CLI, Console, bootstrap, and diagnostics work.

## Recommended Slice

Implement OpenSpec task `2.8`: Admin API admission and pending-admission rejection semantics with cluster-scoped audit events.

The slice should expose the first `/admin/v1` node-admission API surface, wire real Admin API authorization, preserve the admission-candidate evidence model from PR #30, and keep enough response shape stability for later CLI and Console parity.

## Scope

Add an Admin API router pipeline under `/admin/v1`.
This pipeline must be separate from the public inference pipeline and must not reuse `authorize_public_inference/1`.

Add Admin API authentication and authorization for Bearer API Keys.
The token must resolve to a service-account-owned API Token.
The owning API Client must be enabled.
The API Client must have a cluster-scoped `admin` RoleBinding with `tenant_scope_id == nil`.
Tenant-direct API Keys, tenant-scoped `inference_client`, `tenant_admin`, `operator`, disabled service accounts, expired tokens, revoked tokens, and malformed tokens must fail closed.

Add a small governance helper for checking or ensuring cluster-scoped admin access.
The implementation should follow the existing `ensure_inference_client_access/3` and `has_inference_client_access?/2` shape where it fits, but admin access is cluster-scoped and must not require a Tenant scope.

Add a narrow leader-only write gate for Admin API control-plane mutations.
In current single-controller and source-dev mode it may return `:ok`.
When HA-lite standby state is represented, the gate must fail closed with one stable external Admin API error code.
Use `controller_standby` as the external error code with HTTP `503 Service Unavailable`.
Do not claim complete HA-lite enforcement until first-observed candidate creation and other non-Admin write paths are also covered.

Implement these endpoints:

```text
GET  /admin/v1/node-admission/candidates
GET  /admin/v1/node-admission/candidates/:candidate_id
POST /admin/v1/node-admission/candidates/:candidate_id/reject
POST /admin/v1/node-admission/candidates/:candidate_id/clear-rejection
POST /admin/v1/nodes/:node_id/admit
```

Candidate-route mutations must be candidate-only.
Do not call context functions in a way that allows a missing `candidate_id` to fall back to a Node row with the same UUID.
Add candidate-only context functions or route-level locking that returns `candidate_not_found` for candidate routes.

Node admission remains node-only.
Observed-only Runtime Endpoint Admission Candidates must not be directly admitted.
Admin admission execution requires a registered trusted Node with inventory, pool, and required policy inputs.
Successful admission transitions `registered -> admitted`, not `active`.

## Response Contract

List responses should use:

```json
{
  "object": "list",
  "data": []
}
```

Candidate responses should expose sanitized stored evidence and decision metadata:

```json
{
  "object": "node_admission_candidate",
  "id": "uuid",
  "node_id": null,
  "source": "runtime_endpoint_observation",
  "admission_category": "pending_observed",
  "observed_identity": {},
  "target_ref": "host:port",
  "endpoint": {
    "transport": "grpc",
    "target": "host:port"
  },
  "inventory": {},
  "compatibility_evidence": {},
  "last_observed_at": "2026-06-29T00:00:00Z",
  "inserted_at": "2026-06-29T00:00:00Z",
  "updated_at": "2026-06-29T00:00:00Z",
  "latest_decision": null
}
```

Mutation responses should include the changed resource, the appended Admission Decision, and a compact audit reference:

```json
{
  "object": "node_admission_action_result",
  "action": "node_admission.rejected",
  "candidate": {},
  "decision": {},
  "audit_log": {
    "id": 123,
    "scope": "cluster",
    "action": "node_admission.rejected"
  }
}
```

Present stored `observed_identity`, `inventory`, `compatibility_evidence`, and decision metadata as stored.
Do not re-sanitize already stored snapshots on read, because that could hide or alter explicit `__orchard_snapshot_truncation__` markers from PR #30.

Admin API errors should use stable JSON with `error.code`, `error.message`, and optional `error.details`.
Use `401` for missing, malformed, invalid, expired, or revoked Bearer tokens.
Use `403` for tenant-direct tokens, disabled service accounts, missing cluster admin role, or wrong role.
Use `404` for missing candidates or nodes.
Use `409` for lifecycle or admission blockers.
Use `503` for `controller_standby`.

Initial stable error codes should include:

```text
admin_required
candidate_not_found
node_not_found
reason_required
admission_not_pending
admission_not_rejected
admission_rejected
node_not_registered
node_not_pending_admission
inventory_missing
trust_not_established
pool_required
policy_required
controller_standby
```

## Likely Files

Likely new or changed controller files:

```text
apps/orchard_controller/lib/orchard/api/router.ex
apps/orchard_controller/lib/orchard/api/admin_request_context.ex
apps/orchard_controller/lib/orchard/api/admin_error_helpers.ex
apps/orchard_controller/lib/orchard/api/admin/node_admission_controller.ex
apps/orchard_controller/lib/orchard/api/admin/node_admission_presenter.ex
apps/orchard_controller/lib/orchard/control_plane.ex
apps/orchard_controller/lib/orchard/governance.ex
apps/orchard_controller/lib/orchard/nodes.ex
```

Likely test files:

```text
apps/orchard_controller/test/orchard/api/admin/node_admission_controller_test.exs
apps/orchard_controller/test/orchard/api/admin_request_context_test.exs
apps/orchard_controller/test/orchard/governance/governance_test.exs
apps/orchard_controller/test/orchard/nodes_test.exs
```

OpenSpec files may need small task or spec clarifications only if implementation discovers a contract mismatch:

```text
openspec/changes/cluster-management-ux-foundation/tasks.md
openspec/changes/cluster-management-ux-foundation/specs/cluster-management-ux/spec.md
```

## Validation Plan

Run focused tests first:

```text
mise exec -- mix test apps/orchard_controller/test/orchard/api/admin_request_context_test.exs
mise exec -- mix test apps/orchard_controller/test/orchard/api/admin/node_admission_controller_test.exs
mise exec -- mix test apps/orchard_controller/test/orchard/nodes_test.exs
mise exec -- mix test apps/orchard_controller/test/orchard/governance
```

Run OpenSpec validation before implementation handoff:

```text
OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate cluster-management-ux-foundation --type change --strict --no-interactive
```

Run the Elixir quality workflow from the umbrella root:

```text
mise exec -- mix format
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix dialyzer
mise exec -- mix test
mise exec -- mix test --cover
```

After implementation, repeat the documented two-Mac gRPC smoke using mawarduri:

```text
mise exec -- bin/dev-node-agent
mise exec -- bin/dev-controller
```

The smoke should still show first-observed Runtime Endpoints persisting as `pending_observed` candidates, `nodes` count staying `0`, and no trusted active Node being auto-created.

## Required Tests

Admin API auth tests:

```text
missing token returns 401
malformed token returns 401
invalid token returns 401
expired token returns 401
revoked token returns 401
tenant-direct API Key returns 403 admin_required
service-account token with only inference_client returns 403 admin_required
service-account token with operator role returns 403 admin_required
disabled API Client returns 403 admin_required
service-account token with cluster-scoped admin role succeeds
```

Admission route tests:

```text
admin can list candidates
admin can show candidate
candidate show returns 404 candidate_not_found
candidate reject requires nonblank normalized reason
candidate reject appends Admission Decision and cluster audit log
candidate clear-rejection appends Admission Decision and cluster audit log
candidate reject route does not fall back to a Node with the same UUID
candidate clear route does not fall back to a Node with the same UUID
node admit rejects observed-only candidates
node admit rejects provisioned nodes
node admit rejects rejected nodes
node admit rejects registered nodes missing inventory
node admit rejects registered nodes missing trust
node admit rejects registered nodes missing pool or policy inputs
node admit transitions registered trusted node to admitted
node admit writes Admission Decision and cluster audit log
stored snapshot truncation markers are preserved in API responses
controller_standby returns 503 before mutating admission state or audit logs
```

## Out Of Scope

Do not implement `orchardctl nodes admit`.
Do not implement Console pending admission UX.
Do not implement action previews.
Do not implement shared scheduler explanation UI.
Do not implement `POST /admin/v1/nodes/provision`.
Do not implement `POST /admin/v1/nodes/:node_id/decommission`.
Do not implement `/admin/v1/bootstrap-tokens`.
Do not implement `orchardctl cluster init`.
Do not implement first-admin credential provisioning.
Do not implement full HA-lite failover, leadership transfer, standby read-only UX, or leader election.
Do not change observed Runtime Endpoint behavior back to auto-created active Nodes.

## Risks And Open Questions

First-admin provisioning is a deployability gap.
It is not a task 2.8 blocker, but release notes and handoff must avoid presenting the Admin API as fully operator-usable until `cluster init`, bootstrap tokens, or another provisioning path exists.

Leader-only write-path compliance is partial in this slice.
Admin API mutations can be gated now, but first-observed candidate creation through Runtime Endpoint observation is also leader-only per `SPEC.md` and should be covered by a later HA-lite write-path slice or included only if the implementation explicitly expands scope.

Admin API response envelopes should be treated as a contract for CLI and Console.
Changing them later will create avoidable parity work.

Cluster-scoped Admin API auth now has a durable ADR in `docs/decisions/0004-admin-api-cluster-admin-auth.md`.
If implementation finds `SPEC.md` text that conflicts with that ADR, treat the PR as blocked until the conflict is reconciled.
