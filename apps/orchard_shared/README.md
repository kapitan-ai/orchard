# orchard_shared

Shared umbrella app for Orchard transport modules, cross-app domain structs, and
small helpers used by controller, node-agent, and CLI releases.

This README is orientation only. Normative shared contracts live in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Generated Elixir modules for `proto/cluster/v1/` under `lib/cluster/v1/`.
- Shared Runtime Endpoint domain structs, target normalization, and mappers used
  across releases.
- Shared filesystem/path, build metadata, licensing, manifest, and Sentry helper
  modules when they are release-neutral.

## Does not own

- Controller workflows, persistence orchestration, or public API behavior.
- Node-agent worker lifecycle and runtime supervision.
- Product decisions that belong in `SPEC.md` or `../../docs/decisions/`.

## Local work

Regenerate cluster proto modules from the umbrella root with
`mise exec -- mix proto.gen` when `../../proto/cluster/v1/*.proto` changes. See
[`../../proto/cluster/v1/README.md`](../../proto/cluster/v1/README.md) and
[`../../docs/tooling.md`](../../docs/tooling.md).
