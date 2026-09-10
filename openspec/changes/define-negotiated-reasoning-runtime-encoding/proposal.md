## Why

`SPEC.md` §7.5.3a requires an exact negotiated reasoning contract and a loaded-worker proof before model invocation, but deliberately leaves its concrete Runtime Endpoint and Worker Runtime encoding unaccepted. Issue #327 supplies that acceptance gate without implementing the schema or runtime behavior.

The generic `WorkerCapabilities` envelope is diagnostic-only by its accepted contract. Negotiated reasoning needs a narrower exception: an explicit negotiated request may select only a loaded placement that proves its exact tuple through fresh live reasoning evidence. This does not promote generic capability evidence into readiness, admission, capacity, retry, or ordinary scheduler authority.

That exception has to be reconciled with the two contracts it touches. `SPEC.md` §5.6 tier selection would otherwise still offer Tier 1 and Tier 2 candidates that no negotiated request can use, and §5.5 would otherwise still forbid every inline request-path observation. Both are amended here, and the live wave is bounded like the existing compatibility status-probe wave instead of fanning out per candidate.

## What Changes

- Accept one indivisible ten-field reasoning tuple and its loaded-binding association; source provenance is not tuple identity.
- Accept the deferred `WorkerLoadedBinding` allocation in `WorkerCapabilities` field 8, a sibling reasoning envelope in field 9, and shared Controller/Worker-facing definitions in `proto/cluster/v1/reasoning.proto`, after this change's source review confirmed those allocations are available.
- Accept a unary `PrepareInference` operation whose proof and opaque single-use authorization form the pre-inference barrier. The authorization is redeemed only by the matching execution request after Controller proof validation.
- Require opt-in, live-probe-only reasoning evidence and selection from already loaded placements. Heartbeats, persisted observations, and legacy projections do not carry or refresh reasoning evidence.
- Restrict negotiated candidate selection to `SPEC.md` §5.6 Tier 0 and make `residency_preference` and `max_cold_start_ms` inapplicable to it, including its `timeout_at`, which always uses the §12.4 loaded-only formula.
- Reserve the pre-dispatch incompatibility mapping for a model with no loaded placement or an observed candidate set that proves no tuple. A loaded placement that is merely at capacity keeps the ordinary `cluster_busy`/`model_busy` queue-waitable outcome.
- Bound the live wave to the first four deduplicated candidates of a deterministic order — universe built without the reasoning predicate, then §5.7 ranking with the `node_id` tie-break last — at 2000 ms per target with no transport retry. The explicit negotiated request is the only opt-in; there is no separate operator configuration flag.
- Give each Inference Attempt its own wave, so automatic retry re-observes rather than reusing evidence whose freshness budget forwarding cannot refresh.
- Define presence-aware terminal wire totals, including `Failed.usage`; leave durable `output_usage_status` and Controller lower-bound synthesis to #328.
- Pin automatic retry to the accepted tuple. For an operator retry, reuse `requests.canonical_request["reasoning"]` only when full capture retains it; otherwise fail with `retry_source_unavailable`. This adds no database column.
- Keep production tuple registries empty and the feature dormant until #328's parser, accounting, and capture guarantees and model-qualification governance permit activation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `runtime-endpoints`: adds the negotiated-reasoning live-observation and preparation-proof contract while preserving legacy operations.
- `worker-runtime-providers`: records loaded-binding-scoped reasoning evidence and worker preparation behavior.
- `automatic-attempt-retry`: records the canonical retry source and closed unavailable-source result for negotiated reasoning.
- `portability-validation`: requires reciprocal current and N-1 encoding fixtures without widening the supported version window.

## Impact

- `SPEC.md` §7.5.3a gains the accepted encoding, activation, and sequencing contract.
- `SPEC.md` §5.6 records the Tier 0-only negotiated exception and its capacity-versus-incompatibility split, §3.4 and §12.4 record the routing-policy and deadline inapplicability, and §5.5 records the bounded reasoning wave as a second inline-observation exception.
- `proto/cluster/v1/reasoning.proto` adds one `cluster.v1` dependency of the provider-neutral Worker Runtime boundary; its relocation or removal is sequenced by the later `cluster.v1` deprecation, not by this contract.
- Future implementation may modify shared protocol source, Runtime Endpoint bindings, Worker Runtime bindings, Node Agent, Controller, and provider-neutral fixtures only after PR #401 has merged and this contract is accepted.
- This PR intentionally contains no `.proto` field declaration, generated binding, migration, runtime implementation, registry entry, model-specific policy, or public API change.
- The parent `define-reasoning-output-contract` implementation tasks remain incomplete; this package authorizes their #327 implementation handoff but does not mark code work complete.
