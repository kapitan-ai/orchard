# ADR: Beam-first Runtime Endpoints

## Status

Proposed

## Context

`SPEC.md` currently defines cross-node control traffic as gRPC over mTLS and forbids distributed Erlang across machines.
That direction was chosen while Orchard's cluster boundary was still being worked out.
The current architecture uses Elixir for both the Controller and first-party Node Agent, while Python/MLX remains a local Worker Runtime detail behind the Node Agent.
The latest `gnhf/objective-fully-impl-369718` work strengthens concurrent inference behavior with live placement capacity, conservative scheduler eligibility, `cluster_busy` requeue semantics, and queue fairness.
Those semantics should be treated as target architecture inputs even though their current representation is gRPC/protobuf-shaped.

The key ambiguity is whether the Node Agent is a protocol-isolated runtime endpoint that happens to be implemented in Elixir, or a first-party Orchard BEAM participant that owns node-local execution.

## Decision

Model Orchard scheduling around transport-independent Runtime Endpoints.
The v1 Runtime Endpoint is the first-party Node Agent.
For first-party Runtime Endpoints, prefer BEAM Distribution as the live communication and monitoring layer between Elixir services.
Limit BEAM Distribution to first-party Orchard Runtime Endpoints.
External or provider-backed Runtime Endpoints must integrate through explicit Runtime Endpoint adapters and provider-appropriate protocols.

Keep Postgres as the durable persistence and coordination store.
BEAM Distribution must not become durable cluster truth.
Use BEAM Distribution for live first-party communication, monitoring, and fast session failure signals.
Persist Runtime Endpoint Observations in Postgres for inventory, lifecycle, availability, scheduling, and operator-visible history.
A connected BEAM node is not automatically schedulable.
Production BEAM Distribution must be explicitly configured, identity-bound, network-restricted, and limited to admitted first-party Orchard services.
External Runtime Endpoints must not join the BEAM mesh.

Keep the Runtime Endpoint Interface independent of a transport protocol.
The first implementation can be an Elixir behaviour backed by BEAM Distribution.
Future Runtime Endpoint adapters may target external compute, cloud VMs, high-performance compute nodes, appliance-style accelerators, or paid provider integrations.
Existing `proto/cluster/v1` work should be demoted from the default first-party Controller-to-Node Agent path to a possible future adapter protocol.
Placement Capacity is a first-class Runtime Endpoint observation and must be exposed by the interface independently of transport.
Unknown, malformed, duplicate, or nonmatching Placement Capacity must not prove eligibility for an active loaded placement.

Keep the Worker Runtime Interface separate.
The Node Agent may continue to use a local worker protocol for Python/MLX subprocesses.
The BEAM-first decision applies to first-party Controller-to-Node Agent communication.
It does not remove the local process/protocol boundary between the Node Agent and non-BEAM Worker Runtimes.

## Consequences

This removes gRPC/protobuf as the default Controller-to-Node Agent abstraction for first-party Elixir services.
It reduces transport duplication, generated-code surface, and domain-to-proto translation for the v1 path.
It keeps OTP semantics close to the Orchard services that already run on the BEAM.

The design still preserves an extension point for non-BEAM Runtime Endpoints.
Those endpoints should integrate through Runtime Endpoint adapters rather than forcing the first-party v1 path through an external-service protocol.
It also avoids extending BEAM trust to endpoints Orchard does not fully own.
The existing cluster proto surface should not be deleted solely because the first-party path moves to BEAM Distribution.
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

Update required in `SPEC.md` sections that mandate no distributed Erlang across machines, gRPC over mTLS for all cross-node control traffic, Internal Node/Worker API language, node scheduling, node lifecycle, and model placement.
The update should also reconcile the incoming gnhf concurrency semantics around Placement Capacity, `cluster_busy`, queue requeue under the original deadline, tenant FIFO, weighted round-robin, and unknown-capacity fail-closed behavior.
The OpenSpec change should treat `gnhf/objective-fully-impl-369718` as an architecture input and preservation dependency, not as implementation scope to merge inside the proposal.
This ADR does not by itself change the normative build contract.
