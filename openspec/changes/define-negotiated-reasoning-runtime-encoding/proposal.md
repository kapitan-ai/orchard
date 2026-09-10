## Why

`SPEC.md` §7.5.3a requires an exact negotiated reasoning contract and a loaded-worker proof before model invocation, but deliberately leaves its concrete Runtime Endpoint and Worker Runtime encoding unaccepted. Issue #327 supplies that acceptance gate without implementing the schema or runtime behavior.

The generic `WorkerCapabilities` envelope is diagnostic-only by its accepted contract. Negotiated reasoning needs a narrower exception: an explicit negotiated request may select only a loaded placement that proves its exact tuple through fresh live reasoning evidence. This does not promote generic capability evidence into readiness, admission, capacity, retry, or ordinary scheduler authority.

## What Changes

- Accept one indivisible ten-field reasoning tuple and its loaded-binding association; source provenance is not tuple identity.
- Accept the deferred `WorkerLoadedBinding` allocation in `WorkerCapabilities` field 8, a sibling reasoning envelope in field 9, and shared Controller/Worker-facing definitions in `proto/cluster/v1/reasoning.proto`, after this change's source review confirmed those allocations are available.
- Accept a unary `PrepareInference` operation whose proof and opaque single-use authorization form the pre-inference barrier. The authorization is redeemed only by the matching execution request after Controller proof validation.
- Require opt-in, live-probe-only reasoning evidence and selection from already loaded placements. Heartbeats, persisted observations, and legacy projections do not carry or refresh reasoning evidence.
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
- Future implementation may modify shared protocol source, Runtime Endpoint bindings, Worker Runtime bindings, Node Agent, Controller, and provider-neutral fixtures only after PR #401 has merged and this contract is accepted.
- This PR intentionally contains no `.proto` field declaration, generated binding, migration, runtime implementation, registry entry, model-specific policy, or public API change.
- The parent `define-reasoning-output-contract` implementation tasks remain incomplete; this package authorizes their #327 implementation handoff but does not mark code work complete.
