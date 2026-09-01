# orchard_node_agent

Node-agent release for Orchard's worker-node boundary.
It exposes the split-role source-dev default BEAM Runtime Endpoint facade and explicit opt-out gRPC Runtime Endpoint compatibility service, reports node/runtime status, manages model acquisition and cache state, and supervises local worker subprocesses.

This README is orientation only. Normative behavior lives in
[`../../SPEC.md`](../../SPEC.md); repo/runtime boundaries are mapped in
[`../../docs/architecture.md`](../../docs/architecture.md).

## Owns

- Node-local Runtime Endpoint behavior used by the controller through gRPC
  compatibility and first-party BEAM adapters.
- Model acquisition/cache/load coordination on a node.
- Worker process supervision and node-local diagnostics/status reporting.
- Runtime aggregate node and placement capacity telemetry.
- Generated Elixir binding for the provider-neutral node-agent ↔ worker proto.

## Does not own

- Public API traffic or tenant/governance decisions; those terminate at the
  controller.
- Worker model-generation internals; see `../../native/orchard_worker_mlx/`.
- Shared cluster proto source; see `../../proto/cluster/v1/`.
- Provider-neutral Worker Runtime proto source; see `../../proto/orchard/worker/v1/worker_runtime.proto`.

## Local work

Use `mise exec -- bin/dev-node-agent` for source-dev worker hosts.
For default BEAM split-role testing, configure `ORCHARD_BEAM_NODE_NAME` when overriding the role default and use the shared cookie surface documented in local-dev.
For the experimental certificate-scoped BEAM Peer Grant tracer with no shared cluster cookie, use `mise exec -- bin/source-dev-peer-grant` as documented in local-dev.
For gRPC split-role compatibility testing, set `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`, configure `ORCHARD_NODE_AGENT_LISTEN_HOST`, and configure the controller's `ORCHARD_RUNTIME_CLIENT_TARGETS`.
For setup and validation commands, see [`../../docs/local-dev.md`](../../docs/local-dev.md)
and [`../../docs/tooling.md`](../../docs/tooling.md).
