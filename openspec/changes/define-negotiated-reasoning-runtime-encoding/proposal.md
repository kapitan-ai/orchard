## Why

`SPEC.md` §7.5.3a already requires an exact negotiated reasoning contract, a loaded-worker proof before model invocation, and the indivisible eleven-field tuple with field 8/9 allocations. Issue #327 still needs the owner-confirmed concrete schema decision recorded before any declaration or runtime work. This change records that decision and does not implement the schema or runtime behavior.

The generic `WorkerCapabilities` envelope is diagnostic-only by its accepted contract. Negotiated reasoning needs a narrower exception: an explicit negotiated request may select only a loaded placement that proves its exact tuple through fresh live reasoning evidence. This does not promote generic capability evidence into readiness, admission, capacity, retry, or ordinary scheduler authority.

That exception is already reconciled in the landed `SPEC.md` §5.6 and §5.5 language this package traces. The live wave remains bounded like the existing compatibility status-probe wave instead of fanning out per candidate. This PR does not re-amend those sections.

## What Changes

- Trace the already-landed indivisible eleven-field reasoning tuple and its loaded-binding association; source provenance is not tuple identity.
- Record the owner-confirmed schema decision in `design.md` §2.1 as proposed-only declarations. Schema declarations, generated bindings, and runtime implementation remain separate and blocked until this change is accepted.
- Accept the deferred `WorkerLoadedBinding` allocation in `WorkerCapabilities` field 8, a sibling reasoning envelope in field 9, and shared Controller/Worker-facing definitions in `proto/cluster/v1/reasoning.proto`, after this change's source review confirmed those allocations are available.
- Accept a unary `PrepareInference` operation whose proof and opaque single-use authorization form the pre-inference barrier. The authorization is redeemed only by the matching execution request after Controller proof validation.
- Require opt-in, live-probe-only reasoning evidence and selection from already loaded placements. Heartbeats, persisted observations, and legacy projections do not carry or refresh reasoning evidence.
- Restrict negotiated candidate selection to `SPEC.md` §5.6 Tier 0 and make `residency_preference` and `max_cold_start_ms` inapplicable to it, including its `timeout_at`, which always uses the §12.4 loaded-only formula.
- Observe the reachable loaded-placement universe — capacity- and tenant-cap-blocked placements included; targets that are not scheduler-fresh, fail §5.5's own health condition, or are suppressed by either §5.10 breaker scope withheld — so exhaustion can distinguish absent support from absent free capacity without circumventing suppression or inventing a reasoning-specific health gate.
- Keep selection evidence and exhaustion evidence distinct through three closed probe result classes. Only a completed well-formed exact-tuple response is proving. A completed response that reports the projection or tuple unsupported — the mixed-version answer of a non-advertising binding included — or that returns valid evidence with an absent or mismatched tuple is confirmed non-support and counts toward exhaustion. Malformed evidence, a timeout, a task exit, a transport failure, and a missing or incomplete response are unknown: they fail selection but never exhaustion. Reserve the pre-dispatch incompatibility mapping for a model with no loaded placement, or a universe in which every placement was probed and each returned confirmed non-support. Capacity-blocked, unreachable, and withheld placements all keep the `cluster_busy`/`model_busy` queue-waitable outcome under §5.4 as transient unavailability.
- Bound the live wave on concurrency rather than reach: at most four probes in flight advancing down the §5.7 ranking with the `node_id` tie-break last, under one 2000 ms wave deadline with no transport retry. Resolve to the highest-ranked proving placement so completion latency cannot displace that ranking. The explicit negotiated request is the only opt-in; there is no separate operator configuration flag.
- Count waves per logical request — one initial wave plus one more only for a real automatic attempt 2 — so the §5.4 requeue loop cannot multiply them. A busy re-grant re-probes nothing and keeps the earlier selection as a non-authoritative hint, carved out explicitly from the fresh-observation selection rule, with `PrepareInference` as the authoritative gate.
- Define presence-aware terminal wire totals, including `Failed.usage`; leave durable `output_usage_status` and Controller lower-bound synthesis to #328.
- Pin automatic retry to the accepted tuple. For an operator retry, reuse `requests.canonical_request["reasoning"]` only when full capture retains it; otherwise fail with `retry_source_unavailable`. This adds no database column.
- Keep production tuple registries empty and the feature dormant until #328's parser, accounting, and capture guarantees and model-qualification governance permit activation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `runtime-endpoints`: adds the negotiated-reasoning live-observation and preparation-proof contract while preserving legacy operations.
- `scheduler`: records the bounded negotiated-reasoning live selection wave as the sole exception to durable-only candidate construction and final dispatch revalidation, with `PrepareInference` authoritative before invocation.
- `worker-runtime-providers`: records loaded-binding-scoped reasoning evidence and worker preparation behavior.
- `automatic-attempt-retry`: records the canonical retry source and closed unavailable-source result for negotiated reasoning.
- `portability-validation`: requires reciprocal current and N-1 encoding fixtures without widening the supported version window.

## Impact

- This PR does not amend `SPEC.md`. It traces the already-landed §7.5.3a encoding, activation, and sequencing contract, including the eleven-field tuple and field 8/9 allocations.
- The landed `SPEC.md` §5.6 Tier 0-only negotiated exception, §3.4 and §12.4 routing-policy and deadline inapplicability, §5.5 bounded reasoning wave, and §13.1 non-advertising `N-1` confirmed non-support remain the apex contract. This package does not rewrite them.
- `proto/cluster/v1/reasoning.proto` adds one `cluster.v1` dependency of the provider-neutral Worker Runtime boundary; its relocation or removal is sequenced by the later `cluster.v1` deprecation, not by this contract.
- Future implementation may modify shared protocol source, Runtime Endpoint bindings, Worker Runtime bindings, Node Agent, Controller, and provider-neutral fixtures only after this change is accepted, and only by reproducing `design.md` §2.1 unchanged in a separate implementing change. PR #401 has already merged.
- This PR intentionally contains no `.proto` field declaration, generated binding, migration, runtime implementation, registry entry, model-specific policy, or public API change.
- The parent `define-reasoning-output-contract` implementation tasks remain incomplete; this package authorizes their #327 implementation handoff but does not mark code work complete.
