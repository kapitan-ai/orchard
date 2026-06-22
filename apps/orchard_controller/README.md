# orchard_controller

Controller release for Orchard's public API, Console, persistence-backed control
plane, admission/scheduling/dispatch paths, governance surfaces, and operator
readiness behavior.

This README is orientation only. Normative behavior lives in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Phoenix/Plug API endpoints and LiveView Console surfaces.
- `Orchard.Repo` migrations and Postgres-backed controller state.
- Request canonicalization, tokenization orchestration, admission, scheduling,
  dispatch, lifecycle persistence, and public response serialization.

## Does not own

- Node-local model execution or worker subprocess lifecycle; see
  `../orchard_node_agent/` and `../../native/orchard_worker_mlx/`.
- Shared generated transport modules and cross-app domain helpers; see
  `../orchard_shared/`.
- Packaged install policy; see `../../packaging/pkg/README.md`.

## Local work

Run source dev from the umbrella root with `mise exec -- bin/dev`. For setup and
validation commands, see [`../../docs/local-dev.md`](../../docs/local-dev.md)
and [`../../docs/tooling.md`](../../docs/tooling.md).
