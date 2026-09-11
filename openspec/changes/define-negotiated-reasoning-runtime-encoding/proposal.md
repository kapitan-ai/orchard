## Why

`SPEC.md` §7.5.3a requires an exact negotiated reasoning contract and a loaded-worker proof before model invocation. It accepts the eleven-field tuple, the `WorkerCapabilities` field allocation, and the shared cross-boundary definition location, and leaves the remaining Runtime Endpoint and Worker Runtime message design undeclared. Issue #327 supplies that acceptance gate without implementing the schema or runtime behavior.

The generic `WorkerCapabilities` envelope is diagnostic-only by its accepted contract. Negotiated reasoning needs a narrower exception: an explicit negotiated request may select only a loaded placement that proves its exact tuple through fresh live reasoning evidence. This does not promote generic capability evidence into readiness, admission, capacity, retry, or ordinary scheduler authority.

That exception has to be reconciled with the two contracts it touches. `SPEC.md` §5.6 tier selection would otherwise still offer Tier 1 and Tier 2 candidates that no negotiated request can use, and §5.5 would otherwise still forbid every inline request-path observation. Both reconciliations already stand in `SPEC.md`, which this package traces rather than re-amends, and the live wave is bounded like the existing compatibility status-probe wave instead of fanning out per candidate.

## What Changes

- Reconcile the indivisible eleven-field reasoning tuple: generation policy, projection, reasoning effort, model artifact digest, chat-template digest, render contract, render contract version, parser family, parser version, runtime contract version, and event-binding version. Source provenance is not tuple identity.
- Preserve the normative `PrepareInference` behavioral barrier: its proof and opaque single-use authorization form the pre-inference gate, and only the matching execution request redeems the authorization after Controller proof validation. `SPEC.md` §7.5.3a already fixes the Runtime Endpoint Interface placement of that unary operation; this reconciliation selects no enum value, `nil`-presence encoding, protobuf service or RPC declaration owner, evidence/preparation/proof message layout, or execution-redemption shape.
- Trace, rather than re-choose, the `SPEC.md` §7.5.3a allocation: `WorkerCapabilities` field 8 for the deferred `WorkerLoadedBinding`, field 9 for its sibling reasoning envelope, and shared tuple, evidence, preparation, and proof definitions in `proto/cluster/v1/reasoning.proto`. Implementation re-confirms those allocations and blocks rather than substituting a conflicting number or shape.
- Record the concrete protocol source declarations that realize them — their enum values, `nil`-presence encoding, service and RPC declaration ownership, message layouts, and execution-redemption shape — as blocked pending owner-approved schema design, recorded per `design.md` §1 condition 3. This PR adds no protocol source declaration or generated binding.
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

- This package now traces its tuple, activation, and sequencing language to `SPEC.md` §7.5.3a and the accepted `define-qualified-reasoning-effort` contract.
- `SPEC.md` §5.6 records the Tier 0-only negotiated exception and its capacity-versus-incompatibility split, §3.4 and §12.4 record the routing-policy and deadline inapplicability, and §5.5 records the bounded reasoning wave as a second inline-observation exception, which the `scheduler` capability spec records in turn. `SPEC.md` §13.1 records that a non-advertising `N-1` response is confirmed non-support, so an all-`N-1` loaded universe fails closed rather than waiting out `queue_timeout`.
- `proto/cluster/v1/reasoning.proto` remains the `SPEC.md` §7.5.3a shared definition location and one `cluster.v1` dependency of the provider-neutral Worker Runtime boundary; its relocation or removal is sequenced by the later `cluster.v1` deprecation rather than by this contract. The concrete declarations that realize that allocation remain blocked pending owner-approved schema design; this reconciliation neither adds nor alters them.
- Future implementation may modify shared protocol source, Runtime Endpoint bindings, Worker Runtime bindings, Node Agent, Controller, and provider-neutral fixtures only after PR #401 has merged, the schema design is owner-approved, and this contract is accepted.
- This PR intentionally contains no `.proto` field declaration, generated binding, migration, runtime implementation, registry entry, model-specific policy, or public API change. Its single `.proto` edit is comment-only: the field 8 reservation now names the owner-approved schema design prerequisite alongside issue #327 acceptance, leaving the descriptor golden and generated bindings unchanged.
- The parent `define-reasoning-output-contract` implementation tasks remain incomplete; this package authorizes their #327 implementation handoff but does not mark code work complete.
