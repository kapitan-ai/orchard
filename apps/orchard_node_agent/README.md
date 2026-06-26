# orchard_node_agent

Node-agent release for Orchard's worker-node boundary.
It exposes the current gRPC Runtime Endpoint compatibility service and default-off BEAM Runtime Endpoint facade, reports node/runtime status, manages model acquisition and cache state, and supervises local worker subprocesses.

This README is orientation only. Normative behavior lives in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Node-local Runtime Endpoint behavior used by the controller through gRPC
  compatibility and first-party BEAM adapters.
- Model acquisition/cache/load coordination on a node.
- Worker process supervision and node-local diagnostics/status reporting.
- Runtime aggregate node and placement capacity telemetry.
- Manual Elixir binding for the node-agent ↔ worker proto.

## Does not own

- Public API traffic or tenant/governance decisions; those terminate at the
  controller.
- Worker model-generation internals; see `../../native/orchard_worker_mlx/`.
- Shared cluster proto source; see `../../proto/cluster/v1/`.

## Local work

Use `mise exec -- bin/dev-node-agent` for source-dev worker hosts.
For gRPC split-role testing, configure `ORCHARD_NODE_AGENT_LISTEN_HOST` and the controller's `ORCHARD_RUNTIME_CLIENT_TARGETS`.
For BEAM split-role testing, configure `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`, `ORCHARD_BEAM_NODE_NAME`, and the shared cookie surface documented in local-dev.
For setup and validation commands, see [`../../docs/local-dev.md`](../../docs/local-dev.md)
and [`../../docs/tooling.md`](../../docs/tooling.md).
