# orchard_node_agent

Node-agent release for Orchard's worker-node boundary. It exposes the internal
node runtime endpoint, reports node/runtime status, manages model acquisition and
cache state, and supervises local worker subprocesses.

This README is orientation only. Normative behavior lives in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Node-local runtime service behavior used by the controller.
- Model acquisition/cache/load coordination on a node.
- Worker process supervision and node-local diagnostics/status reporting.
- Manual Elixir binding for the node-agent ↔ worker proto.

## Does not own

- Public API traffic or tenant/governance decisions; those terminate at the
  controller.
- Worker model-generation internals; see `../../native/orchard_worker_mlx/`.
- Shared cluster proto source; see `../../proto/cluster/v1/`.

## Local work

Use `mise exec -- bin/dev-node-agent` for source-dev worker hosts. For split-role
setup and validation commands, see [`../../docs/local-dev.md`](../../docs/local-dev.md)
and [`../../docs/tooling.md`](../../docs/tooling.md).
