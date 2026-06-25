## Why

At the base of this change, Orchard treats first-party Controller-to-Node Agent communication as a gRPC over mTLS product boundary even though both sides are first-party Elixir services.
This adds transport and protobuf complexity before Orchard has a non-BEAM runtime endpoint that needs it.

The architecture should make Orchard's runtime execution semantics transport-independent, add guardrails for future BEAM Distribution between admitted first-party Elixir Runtime Endpoints, keep Postgres as durable truth, and preserve the latest concurrent-inference semantics from `gnhf/objective-fully-impl-369718`.

## What Changes

- Introduce Runtime Endpoint as the schedulable execution boundary selected by the Controller.
- Introduce a transport-independent Runtime Endpoint Interface for model readiness, inference execution, cancellation, status, runtime telemetry, Placement Capacity, and scheduler observations.
- Treat the first-party Node Agent as Orchard's v1 Runtime Endpoint implementation.
- Add BEAM Distribution guardrail validation for future live communication and monitoring between first-party Orchard Elixir services.
- Keep the current gRPC/protobuf `NodeRuntimeService` path as an explicit Runtime Endpoint compatibility adapter for this implementation slice.
- Keep Postgres as Orchard's durable persistence and coordination store.
- Keep Worker Runtime as a local Node Agent-owned process/protocol boundary for Python/MLX execution.
- Demote `proto/cluster/v1` and `NodeRuntimeService` from the durable Controller domain contract to an explicit compatibility adapter and possible future non-BEAM adapter protocol.
- Preserve the latest `gnhf/objective-fully-impl-369718` concurrency semantics around Placement Capacity, conservative scheduler eligibility, `cluster_busy`, queue requeue under the original deadline, tenant FIFO, and weighted round-robin.
- Require production BEAM Distribution to be explicitly configured, identity-bound, network-restricted, and limited to admitted first-party Orchard services.
- Keep external compute, appliance-style accelerators, cloud VMs, high-performance compute nodes, and paid provider integrations outside the BEAM mesh behind future Runtime Endpoint adapters.

## Capabilities

### New Capabilities

- `runtime-endpoints`: Defines Runtime Endpoint semantics, the transport-independent Runtime Endpoint Interface, first-party BEAM transport guardrails, Placement Capacity observations, and the compatibility role of the current gRPC adapter.

### Modified Capabilities

- None.
  No accepted OpenSpec capability specs exist yet.
  This change updates `SPEC.md` behavior and supporting product docs after review.

## Impact

- Requires updates to `SPEC.md` sections that mandated no distributed Erlang across machines and gRPC over mTLS for all cross-node control traffic at the base of this change.
- Requires updates to architecture docs and glossary terms that bound internal runtime communication to gRPC/mTLS at the base of this change.
- Affects controller dispatch, scheduler, request orchestration, queue admission, node-agent runtime status, and runtime telemetry tests.
- Affects current gRPC/protobuf artifacts under `proto/cluster/v1/` and generated cluster bindings by wrapping them as adapter or compatibility transport status.
- Does not remove the local Worker Runtime protocol boundary.
- Does not merge `gnhf/objective-fully-impl-369718`, but the accepted architecture must preserve and adapt its concurrency behavior.
