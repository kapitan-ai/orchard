## 1. Shared Read Builders

- [x] 1.1 Move the `cluster_management.cluster_status` payload builder, including its `object` and `contract_version` strings, into Controller-owned code and make `orchardctl cluster status --json` call it without changing its output.
- [x] 1.2 Move the `cluster_management.node_status_list` and inspected Node payload builders into Controller-owned code and make `orchardctl nodes list --json` and `orchardctl nodes inspect --json` call them.
- [x] 1.3 Add an explicit `latest_decision` projection option: operator projection (`object`, `decision`, `decided_at`) for the Operator API and the existing full projection for the local CLI.
- [x] 1.4 Add a non-observing Runtime Endpoint snapshot option that skips `Orchard.Nodes.observe_status/3` and queue-capacity refresh, and use it for the shared memory budget.
- [x] 1.5 Share the strict inventory read and summary between text and JSON modes of `orchardctl nodes list`, reporting `database_unavailable` with exit status 1 in both modes while preserving healthy output (KAP-208).

## 2. Operator API Routes

- [x] 2.1 Add `GET /ops/v1/cluster`, `GET /ops/v1/nodes`, and `GET /ops/v1/nodes/:node_id` under the existing `:operator_api` pipeline, changing only those router lines.
- [x] 2.2 Leader-gate the two Node routes with `ControlPlane.authorize_write_path/1`, returning `503 controller_standby` and `503 controller_leadership_unproven`; leave `/ops/v1/cluster` ungated.
- [x] 2.3 Return `404 node_not_found` for unknown and malformed Node IDs and `503 database_unavailable` for Node inventory query failures after admission, both in the shared error envelope.

## 3. Tests

- [x] 3.1 Cover `401 invalid_api_key` for missing, malformed, invalid, expired, and revoked credentials; `403 operator_required` for tenant-direct keys, tenant-scoped RoleBindings, API Clients with no cluster role, and disabled API Clients; `no-store`; and success for cluster `operator` and `admin`.
- [x] 3.2 Cover Standby and unproven-leadership refusals on the Node routes, and a Standby answering `/ops/v1/cluster` without claiming leadership.
- [x] 3.3 With an injected `runtime_impl`, assert each HTTP payload and its CLI payload share `object`, `contract_version`, and field set, and that list values match.
- [x] 3.4 Assert the operator `latest_decision` projection omits reason, actor, audit, observed-identity, target, and metadata fields, and the CLI keeps the full projection.
- [x] 3.5 With a Runtime Endpoint probe that succeeds, assert Node inspect creates or updates no Node, Admission Candidate, queue-capacity source, audit, or Admission Decision row.
- [x] 3.6 Cover unknown and malformed Node IDs, an empty Node inventory, nonzero state and health summary counts, a Node with and without a memory budget, and inventory query failures on the Operator API and both text and JSON modes of `orchardctl nodes list`.
- [x] 3.7 Exercise authenticated BEAM status and a real mTLS compatibility connection with `observe?: false`: preserve domain rows and queue sources on success and rejection, reject invalid peer/target/enrollment/grant bindings, and retain default observation as a positive control.

## 4. Validation

- [x] 4.1 Run strict validation for this change and all OpenSpec changes.
- [x] 4.2 Run the applicable full Elixir quality and coverage workflow.
