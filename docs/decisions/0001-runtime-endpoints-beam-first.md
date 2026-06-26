# ADR: Beam-first Runtime Endpoints

## Status

Accepted

## Context

Before this decision, `SPEC.md` defined cross-node control traffic as gRPC over mTLS and forbade distributed Erlang across machines.
That direction was chosen while Orchard's cluster boundary was still being worked out.
The current architecture uses Elixir for both the Controller and first-party Node Agent, while Python/MLX remains a local Worker Runtime detail behind the Node Agent.
The latest `gnhf/objective-fully-impl-369718` work strengthens concurrent inference behavior with live placement capacity, conservative scheduler eligibility, `cluster_busy` requeue semantics, and queue fairness.
Those semantics should be treated as target architecture inputs even though their current representation is gRPC/protobuf-shaped.

The key ambiguity is whether the Node Agent is a protocol-isolated runtime endpoint that happens to be implemented in Elixir, or a first-party Orchard BEAM participant that owns node-local execution.

## Decision

Model Orchard scheduling around transport-independent Runtime Endpoints.
The v1 Runtime Endpoint is the first-party Node Agent.
For first-party Runtime Endpoints, keep BEAM Distribution as the preferred live communication and monitoring layer between Elixir services when guardrails and rollout gates allow it.
Limit BEAM Distribution to first-party Orchard Runtime Endpoints.
External or provider-backed Runtime Endpoints must integrate through explicit Runtime Endpoint adapters and provider-appropriate protocols.

Keep Postgres as the durable persistence and coordination store.
BEAM Distribution must not become durable cluster truth.
Use BEAM Distribution for guarded live first-party communication, monitoring, and fast session failure signals.
Persist Runtime Endpoint Observations in Postgres for inventory, lifecycle, availability, scheduling, and operator-visible history.
A connected BEAM node is not automatically schedulable.
Production BEAM Distribution must be explicitly configured, identity-bound, network-restricted, and limited to admitted first-party Orchard services.
External Runtime Endpoints must not join the BEAM mesh.

Keep the Runtime Endpoint Interface independent of a transport protocol.
The implementation defines an Elixir behaviour with the current gRPC Compatibility Adapter and a default-off first-party BEAM adapter behind the same Runtime Endpoint Interface.
Future Runtime Endpoint adapters may target external compute, cloud VMs, high-performance compute nodes, appliance-style accelerators, or paid provider integrations.
Existing `proto/cluster/v1` work should be demoted from the default first-party Controller-to-Node Agent path to a possible future adapter protocol.
Placement Capacity is a first-class Runtime Endpoint observation and must be exposed by the interface independently of transport.
Unknown, malformed, duplicate, or nonmatching Placement Capacity must not prove eligibility for an active loaded placement.

The BEAM Runtime Endpoint adapter is the intended primary source-dev Controller-to-Node Agent path once it passes the accepted two-Mac smoke.
Until that gate passes, current source-dev continues to use the gRPC Compatibility Adapter on port `50071` as the compatibility and fallback path.
The accepted smoke gate requires Console Nodes to show local and remote Node Agents reachable, `GET /v1/models` to return `200`, and `POST /v1/chat/completions` to complete through the Console Playground or an equivalent API request.
Console Nodes live diagnostics use the configured Runtime Endpoint target list, so explicit BEAM Runtime Endpoint targets take precedence over legacy gRPC runtime client targets during that smoke.
Do not remove gRPC compatibility before the BEAM adapter passes that smoke.

Keep the Worker Runtime Interface separate.
The Node Agent may continue to use a local worker protocol for Python/MLX subprocesses.
The BEAM-first decision applies to first-party Controller-to-Node Agent communication.
It does not remove the local process/protocol boundary between the Node Agent and non-BEAM Worker Runtimes.

## Consequences

This removes gRPC/protobuf as the durable Controller-to-Node Agent domain abstraction for first-party Elixir services.
It reduces transport duplication, generated-code surface, and domain-to-proto translation for the v1 path.
It keeps OTP semantics close to the Orchard services that already run on the BEAM.

The design still preserves an extension point for non-BEAM Runtime Endpoints.
Those endpoints should integrate through Runtime Endpoint adapters rather than forcing the first-party v1 path through an external-service protocol.
It also avoids extending BEAM trust to endpoints Orchard does not fully own.
The existing cluster proto surface should not be deleted solely because the durable domain model moves to Runtime Endpoint semantics or the first-party path moves to BEAM Distribution.
It may still become useful for external Runtime Endpoint adapters or compatibility bridges.

Node lifecycle remains first-party and Node-specific.
Runtime Endpoint Availability becomes the scheduler-facing availability concept for both first-party and future external endpoints.
Runtime Endpoint Observations remain durable scheduler and operator inputs even when live first-party communication uses BEAM monitoring.
Model Placement becomes scoped to Runtime Endpoints rather than only Nodes.
Placement Capacity becomes a Runtime Endpoint Observation rather than a protobuf-specific `runtime_model_placements` field.
The queue and scheduling semantics from `gnhf/objective-fully-impl-369718` should be preserved while adapting their transport-specific shell.
The conservative unknown-capacity rule is part of that behavior, not a gRPC artifact.
Keep the existing `cluster_busy` error name for now, but define it as live Runtime Endpoint capacity exhaustion rather than a transport-specific node-cluster failure.

## SPEC.md impact

The `SPEC.md` update replaces prior gRPC-only runtime execution language with Runtime Endpoint semantics, current gRPC compatibility transport, guarded BEAM transport, node scheduling, node lifecycle, and model placement.
The update also reconciles the incoming gnhf concurrency semantics around Placement Capacity, `cluster_busy`, queue requeue under the original deadline, tenant FIFO, weighted round-robin, and unknown-capacity fail-closed behavior.
The OpenSpec change should treat `gnhf/objective-fully-impl-369718` as an architecture input and preservation dependency, not as implementation scope to merge inside the proposal.
This ADR records the decision rationale; `SPEC.md` remains the normative build contract.
