# orchard_controller

Controller release for Orchard's public API, Console, persistence-backed control
plane, admission/scheduling/dispatch paths, governance surfaces, and operator
readiness behavior.

This README is orientation only. Normative behavior lives in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Phoenix/Plug API endpoints and LiveView Console surfaces.
- Authenticated public `/v1` routes for models, chat completions, and the
  bounded Responses API subset.
- `Orchard.Repo` migrations and Postgres-backed controller state.
- Durable Controller membership identity and the supervised membership owner
  that republishes `last_seen_at` and this Controller's dispatch-capacity
  capability evidence on every heartbeat.
- Durable dispatch-capacity policy, the cluster enforcement phase, the shared
  capacity evaluation, and the supervised allocation authority that owns
  per-Node claims and the per-Node acceptance gate.
- Fail-closed capacity authorization for the five named consumers — MultiNode,
  admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch
  revalidation — plus the read-only counterfactual diagnostics that stay
  observability rather than authorization.
- Governance persistence and lifecycle APIs for Organizations, tenant-direct API Tokens, API Clients, service-account-owned API Tokens, role bindings, and provisioning batches.
- Request canonicalization, tokenization orchestration, admission, scheduling,
  dispatch, lifecycle persistence, and public response serialization.
- Runtime Endpoint client adapters, including the split-role source-dev default first-party BEAM adapter and explicit opt-out gRPC compatibility adapter.

## Does not own

- Node-local model execution or worker subprocess lifecycle; see
  `../orchard_node_agent/` and `../../native/orchard_worker_mlx/`.
- Shared generated transport modules and cross-app domain helpers; see
  `../orchard_shared/`.
- Packaged install policy; see `../../packaging/pkg/README.md`.

## Local work

Run all-in-one source dev from the umbrella root with `mise exec -- bin/dev`.
Use `mise exec -- bin/dev-controller` only for split-role controller work.
Use `mise exec -- bin/source-dev-peer-grant` for the experimental certificate-scoped BEAM Peer Grant tracer with no shared cluster cookie.
For setup, BEAM or gRPC split-role flows, and validation commands, see
[`../../docs/local-dev.md`](../../docs/local-dev.md) and
[`../../docs/tooling.md`](../../docs/tooling.md).
