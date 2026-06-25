## 1. Contract And Documentation

- [x] 1.1 Update `SPEC.md` to replace first-party gRPC-only cross-node rules with Runtime Endpoint and BEAM-first first-party semantics.
- [x] 1.2 Update `SPEC.md` to define Runtime Endpoint Observation, Runtime Endpoint Availability, Placement Capacity, and `cluster_busy` capacity semantics.
- [x] 1.3 Update `SPEC.md` to keep Postgres as durable truth and BEAM Distribution as live first-party communication only.
- [x] 1.4 Update `SPEC.md` to keep Worker Runtime as a Node Agent-local boundary.
- [x] 1.5 Update `docs/architecture.md` and glossary docs to match accepted Runtime Endpoint language.
- [x] 1.6 Decide and document which `proto/cluster/v1` artifacts remain as adapter or compatibility protocol inputs.

## 2. Runtime Endpoint Interface

- [x] 2.1 Define transport-independent Runtime Endpoint request, response, event, status, availability, and Placement Capacity domain types.
- [x] 2.2 Define a Controller-facing Runtime Endpoint behaviour for status, ensure model loaded, unload model, execute inference, cancel inference, and prefix-cache scoring.
- [ ] 2.3 Implement the first-party BEAM Runtime Endpoint adapter for Node Agent communication.
- [x] 2.4 Add production guardrails for first-party BEAM Distribution configuration, identity binding, network restriction, and admitted-service membership.
- [x] 2.5 Keep or adapt gRPC client/server modules only behind an explicit compatibility or future-adapter boundary.

## 3. Scheduler, Dispatch, And Queue Behavior

- [x] 3.1 Refactor `Orchard.Scheduler.MultiNode` to consume Runtime Endpoint Observations instead of gRPC `StatusResponse` structs.
- [x] 3.2 Preserve conservative Placement Capacity behavior for active loaded placements with unknown, malformed, duplicate, or nonmatching capacity.
- [x] 3.3 Preserve loadedness, lower active placement count, health, cache, safe-tokenization, memory, and deterministic tie-break ranking order.
- [x] 3.4 Refactor dispatch so `RequestDispatcher` depends on the Runtime Endpoint Interface rather than a gRPC client module.
- [x] 3.5 Preserve timeout, caller disconnect, cancellation, streaming event, and terminal event behavior during dispatch.
- [x] 3.6 Preserve queue-enabled post-grant `cluster_busy` requeue under the original queue deadline.
- [x] 3.7 Preserve queue-disabled `cluster_busy` as an immediate public failure.

## 4. Node Agent And Worker Runtime Boundary

- [ ] 4.1 Adapt Node Agent status and runtime operations to serve the first-party Runtime Endpoint Interface.
- [x] 4.2 Preserve `ModelManager` ownership of active request accounting and Placement Capacity.
- [x] 4.3 Preserve local Worker Runtime supervision, model loading, generation, cancellation, diagnostics, and cleanup.
- [x] 4.4 Keep Python/MLX worker communication behind the Worker Runtime Interface.

## 5. gnhf Concurrency Preservation

- [x] 5.1 Choose the merge or rebase baseline for `gnhf/objective-fully-impl-369718` before implementation begins.
- [x] 5.2 Preserve the gnhf capacity-2 concurrent inference behavior for `/v1/responses`.
- [x] 5.3 Preserve the gnhf capacity-2 concurrent inference behavior for `/v1/chat/completions`.
- [x] 5.4 Preserve tenant FIFO, weighted round-robin, same-lane bypass prevention, and grant requeue behavior in `QueueManager`.
- [x] 5.5 Preserve public error mappings for `cluster_busy`, `queue_full`, and `queue_timeout`.

## 6. Tests And Validation

- [x] 6.1 Recast gRPC-specific node-agent capacity tests as Runtime Endpoint Interface contract tests.
- [x] 6.2 Keep targeted gRPC adapter tests if the gRPC compatibility adapter remains supported.
- [x] 6.3 Add scheduler tests for Runtime Endpoint Observations and Placement Capacity edge cases.
- [x] 6.4 Add request orchestration tests for `cluster_busy` requeue and timeout behavior through the Runtime Endpoint Interface.
- [x] 6.5 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate beam-first-runtime-endpoints --type change --strict --no-interactive`.
- [x] 6.6 Run `mise exec -- mix format`.
- [x] 6.7 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 6.8 Run `mise exec -- mix credo --strict`.
- [x] 6.9 Run `mise exec -- mix dialyzer`.
- [x] 6.10 Run `mise exec -- mix test`.
- [x] 6.11 Run `mise exec -- mix test --cover`.
- [x] 6.12 After spec sync or archive, review generated specs for placeholder prose such as `Purpose TBD`.
