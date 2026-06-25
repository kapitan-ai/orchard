## Context

At the base of this change, `SPEC.md` requires no distributed Erlang across machines and requires all cross-node control traffic to use gRPC over mTLS.
That made sense while Orchard's runtime boundary was still being shaped, but the v1 first-party Controller and Node Agent are both Elixir services owned, packaged, and operated by Orchard.

The latest concurrency work in `gnhf/objective-fully-impl-369718` adds important behavior that must survive this architectural pivot.
It introduces live Placement Capacity, conservative scheduler eligibility, `cluster_busy`, queue requeue under the original deadline, tenant FIFO, and weighted round-robin queue discipline.
Those semantics are product behavior even though their current representation is `StatusResponse.runtime_model_placements` over gRPC.

Postgres remains Orchard's durable persistence and coordination store.
The Worker Runtime remains a local process/protocol boundary owned by the Node Agent.

## Goals / Non-Goals

**Goals:**

- Define Runtime Endpoint as the Controller-selected execution boundary.
- Define Runtime Endpoint Interface as transport-independent runtime semantics.
- Add guardrails for future BEAM Distribution between first-party Controller and Node Agent services.
- Keep Runtime Endpoint Observations durable in Postgres for operator-visible state and scheduling inputs.
- Preserve `gnhf/objective-fully-impl-369718` concurrency semantics while moving controller domain code to Runtime Endpoint semantics.
- Keep external compute and provider integrations behind future Runtime Endpoint adapters.
- Keep `proto/cluster/v1` available as a future adapter or compatibility protocol instead of deleting it immediately.

**Non-Goals:**

- Do not merge `gnhf/objective-fully-impl-369718` as part of this architecture proposal.
- Do not implement external provider endpoints in this change.
- Do not remove the local Worker Runtime protocol boundary.
- Do not make BEAM Distribution durable cluster truth.
- Do not allow external Runtime Endpoints to join the first-party BEAM mesh.

## Decisions

### Runtime Endpoint Becomes The Scheduler Target

The Scheduler should select a Runtime Endpoint rather than a Node.
A Node is a managed Apple Silicon Mac in Orchard inventory.
A Runtime Endpoint is the execution boundary capable of receiving model runtime work.

Alternative considered: keep scheduling centered on Nodes.
That keeps v1 terminology simple, but it makes future Cloud VM, high-performance compute, appliance, or paid-provider execution targets look like fake Nodes.

### Runtime Endpoint Interface Is Transport-Independent

The Controller should depend on a Runtime Endpoint Interface for status, model readiness, inference execution, cancellation, runtime telemetry, Placement Capacity, and prefix-cache scoring.
This slice should introduce the interface and keep the current first-party path behind a gRPC Compatibility Adapter.
A later first-party implementation can use BEAM Distribution.
Future non-BEAM implementations can use provider APIs, gRPC/protobuf, or other adapter protocols.

Alternative considered: keep `NodeRuntimeService` as the core interface.
That preserves current code shape, but it keeps gRPC/protobuf as the ontology rather than an adapter.

### BEAM Distribution Is First-Party Only

BEAM Distribution should be limited to admitted first-party Orchard Elixir services.
Production BEAM Distribution must be explicitly configured, identity-bound, network-restricted, and unavailable to external Runtime Endpoints.

Alternative considered: use BEAM Distribution for every endpoint.
That extends first-party trust to systems Orchard does not own and makes provider integration unsafe.

### Postgres Remains Durable Truth

BEAM Distribution provides live communication, monitoring, and fast failure signals.
Postgres remains the durable store for inventory, lifecycle state, Runtime Endpoint Observations, scheduling history, request state, and operator-visible status.

Alternative considered: use BEAM node connectivity as cluster truth.
That would blur live session state with durable operator state and would weaken recovery after controller restart.

### Placement Capacity Is First-Class Runtime Endpoint Observation

Placement Capacity must be part of the Runtime Endpoint Interface.
It includes the requested model placement, current active request count, and maximum concurrency.
Unknown, malformed, duplicate, or nonmatching Placement Capacity must not prove eligibility for an active loaded placement.

Alternative considered: keep Placement Capacity as scheduler-internal telemetry.
The `gnhf` work shows it drives visible concurrency, `cluster_busy`, and queue behavior, so it belongs in the interface observation vocabulary.

### gRPC Is Demoted, Not Deleted

`proto/cluster/v1` and `NodeRuntimeService` should no longer be the durable Controller domain contract.
They remain the current compatibility transport and may remain as future adapter protocol artifacts.

Alternative considered: delete the proto surface during the pivot.
That creates avoidable churn and removes a useful candidate protocol for future non-BEAM Runtime Endpoint adapters.

## Risks / Trade-offs

Risk: BEAM Distribution security may be weaker than the prior mTLS story if treated casually.
Mitigation: require explicit production configuration, identity binding, network restriction, and first-party admission before any BEAM node participates.

Risk: Transport-neutral interfaces can become vague.
Mitigation: specify concrete operations and observations, including Placement Capacity, cancellation, streaming events, status, availability, and scheduler-visible failure modes.

Risk: The `gnhf` concurrency behavior may regress during transport adaptation.
Mitigation: carry its scheduler, queue, public endpoint, and node-agent active-request regressions forward as Runtime Endpoint Interface tests.

Risk: Existing gRPC tests may be deleted before replacement tests exist.
Mitigation: first recast them as Runtime Endpoint contract tests, then keep or remove gRPC adapter tests based on whether the adapter remains supported.

Risk: The term `cluster_busy` may feel stale after Runtime Endpoint modeling.
Mitigation: keep the name for compatibility and define it as live Runtime Endpoint capacity exhaustion.

## Migration Plan

1. Update `SPEC.md`, architecture docs, and glossary to define Runtime Endpoint, Runtime Endpoint Interface, Runtime Endpoint Observation, Runtime Endpoint Availability, Placement Capacity, and first-party BEAM Distribution constraints.
2. Introduce a Controller-facing Runtime Endpoint Interface, current gRPC Compatibility Adapter, and BEAM guardrail validation.
3. Adapt scheduler and dispatch code to depend on Runtime Endpoint semantics instead of the low-level gRPC client module.
4. Preserve and adapt the `gnhf` queue, placement capacity, and `cluster_busy` behavior after the gnhf baseline is chosen.
5. Recast current gRPC integration tests as Runtime Endpoint Interface contract tests.
6. Keep a smaller adapter or compatibility test suite if gRPC remains available for future external endpoints.
7. Validate OpenSpec, compile, lint, Dialyzer, tests, and coverage under the repo workflow before handoff.

Rollback is architectural rather than runtime.
If the BEAM-first path proves unsafe, keep the Runtime Endpoint Interface and continue binding the first-party adapter to gRPC while preserving the transport-independent domain model.

## Open Questions

- What exact production BEAM Distribution identity mechanism will Orchard use for admitted first-party services?
- Should `cluster_busy` eventually be renamed to `runtime_capacity_exhausted` or kept indefinitely for compatibility?
- Which subset of `proto/cluster/v1` should remain generated after the first-party path moves to BEAM?
- Should external Runtime Endpoint adapters be introduced as a later OpenSpec capability or as implementation slices under `runtime-endpoints`?
