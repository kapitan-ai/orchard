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
Use `mise exec -- bin/source-dev-peer-grant` for the experimental certificate-scoped, cookie-free BEAM Peer Grant tracer.
For setup, BEAM or gRPC split-role flows, and validation commands, see
[`../../docs/local-dev.md`](../../docs/local-dev.md) and
[`../../docs/tooling.md`](../../docs/tooling.md).
