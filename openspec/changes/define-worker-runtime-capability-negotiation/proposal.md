## Why

`SPEC.md` §4.10 and ADR 0025 already require a Worker Runtime provider to report protocol version, provider identity, and generic capability evidence before that evidence authorizes work, and they require unknown, malformed, absent, stale, or incompatible evidence to prove nothing.
After #345 / PR #352 the neutral schema exists, but `WorkerStatusResponse` still carries no capability envelope, so the accepted `worker-runtime-providers` requirement "Versioned Runtime Capability Negotiation" has no concrete encoding and no fail-closed local evaluator.
Issue #354 shapes this as delivery item 2 of #266, after #327 in order, so that later normalized-evidence and scheduling-authority slices build on a reviewed generic envelope rather than on reasoning-specific fields.

## What Changes

- Add one additive, provider-neutral capability envelope to the `GetStatus` response at the Node Agent-to-Worker Runtime boundary: protocol identity and version, provider identity and version, complete indivisible capability profiles, and a non-secret service incarnation.
- Define an optional local loaded binding (loaded model, exact artifact identity, selected profile) whose inclusion is conditional on #327's accepted incarnation and artifact identity; it is deferred if that contract is not accepted when this design is reviewed.
- Add a Node Agent-owned evidence classifier and exact-profile evaluator that binds evidence to subprocess custody and Node Agent receipt time, classifies `absent`, `malformed`, `duplicate_or_conflicting`, `incompatible`, `stale`, `unknown`, and query-level `unsupported` distinctly from a successful proof, and invalidates evidence on worker restart, unload, or reload.
- Populate the envelope from the MLX worker with its real provider identity and one exact supported profile.
- Extend the descriptor golden and reciprocal Python and Elixir fixtures so a current-revision worker and a previous-revision worker (no envelope) both decode additively.
- The evaluator is a local proof surface with telemetry and diagnostic access only. It does not change readiness, admission, dispatch, scheduling, retry, Runtime Endpoint projection, or public behavior.

`SPEC.md` impact: makes §4.10 and §7.5.2a capability-evidence sentences executable at the Worker Runtime boundary; clarifies that the local evaluator is diagnostic-only until the separately reviewed cutover named in ADR 0026 and #266 item 4.
No public API, Runtime Endpoint, Controller, or scheduler behavior changes. Section wording in §4.10 gains one sentence naming the envelope and its non-gating status.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `worker-runtime-providers`: The "Versioned Runtime Capability Negotiation" requirement gains a concrete envelope, indivisible-profile rule, Node Agent ownership of freshness and classification, a distinct evidence taxonomy with deterministic precedence, and an explicit non-gating boundary. A new requirement covers the optional loaded binding and its dependency on #327.

## Impact

- `proto/orchard/worker/v1/worker_runtime.proto`, its descriptor golden, generated Python and Elixir bindings, and the reciprocal fixtures under `proto/orchard/worker/v1/fixtures/`.
- `orchard_node_agent`: `Orchard.Node.WorkerRuntimeAdapter.get_status/2` decoding, `Orchard.Node.WorkerProcess` snapshot custody, and a new `Orchard.Node.WorkerCapabilityEvidence` module.
- `native/orchard_worker_mlx`: `WorkerRuntimeServicer.GetStatus` and backend status population, plus provider-neutral conformance for the stub backend.
- Validation lanes selected by the `portability-validation` dependency rules for proto changes: binding drift, descriptor, reciprocal fixtures, provider-neutral conformance, Node Agent and MLX tests, and the Apple Silicon MLX acceptance lane.
- Excluded: reasoning tuples and acceptance proof (#327), Runtime Endpoint projection, Controller persistence, scheduler, host capability-provider seam, Console/CLI, packaging, Linux, CUDA/ROCm, new provider support claims.
