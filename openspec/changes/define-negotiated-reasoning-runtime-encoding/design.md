# Design: negotiated reasoning Runtime Endpoint encoding

## 1. Status, scope, and sequencing

This is an acceptance-only contract for issue #327. It is based on `origin/main` at `b50fb80c118ced9ee489384d576c12c0bfb870a6`; field availability was reviewed at that revision. It does not modify protocol source, generated outputs, runtime code, persistence, or qualification data.

Implementation is blocked until both conditions hold:

1. PR #401 has merged, so the canonical request owns the exact reasoning identity transported by this contract.
2. This OpenSpec change and its `SPEC.md` amendment have been accepted.

The implementation must re-confirm source field availability when it begins. A conflicting upstream allocation blocks implementation rather than permitting a substitute number or shape.

## 2. Canonical tuple and loaded binding

The advertised and proven reasoning tuple has exactly these ten equality fields:

1. generation policy;
2. projection;
3. model artifact digest;
4. chat-template digest;
5. render contract;
6. render contract version;
7. parser family;
8. parser version;
9. runtime contract version; and
10. event-binding version.

Every comparison is byte-exact after the validated canonical representation is formed. `source` is provenance and is not tuple identity. Independent value lists are invalid because they could fabricate a supported combination.

At the reviewed base, `WorkerCapabilities` uses fields 1 through 7, reserves field 8 explicitly for the deferred `WorkerLoadedBinding`, and has no field 9. The accepted future schema allocation is therefore:

- lift the reservation and use `WorkerCapabilities.loaded_binding = 8` with the previously recorded shape (`model_id`, `model_version`, `artifact_digest`, `selected_profile_id`); and
- add the sibling placement-scoped reasoning envelope at `WorkerCapabilities` field 9.

The future schema also introduces `proto/cluster/v1/reasoning.proto` for the shared tuple, evidence, preparation, and proof definitions. It prevents either the Worker package or Controller transport package from owning cross-boundary reasoning types. This contract assigns no source declaration in the present PR.

That placement follows the existing precedent in `proto/orchard/worker/v1/worker_runtime.proto`, which already imports `cluster/v1` files, but it does add one more `cluster.v1` dependency of the provider-neutral Worker Runtime boundary. `deprecate-node-runtime-grpc-compatibility` already records Worker Runtime imports as the reason runtime messages cannot be deleted early, and reasoning types join that same set. Relocating or removing the shared file is therefore explicitly owned by the later `cluster.v1` deprecation sequencing, not by this contract or its #327 implementation; that deprecation must sequence the reasoning definitions alongside the existing Worker Runtime imports rather than treating them as an unplanned blocker.

A reasoning envelope is meaningful only with one valid loaded binding and that envelope's `service_incarnation`. Each advertised tuple's artifact digest equals that loaded binding's artifact digest, and its selected profile resolves exactly once in the same `WorkerCapabilities` envelope. A present but incomplete envelope, duplicate or conflicting tuple, unknown enum or version, missing required member, or invalid binding proves no support; it is not legacy omission. Loading, unloading, replacement, failed destructive unload, or worker teardown invalidates the affected evidence and any preparation associated with it.

## 3. Live discovery and the narrow eligibility exception

Reasoning evidence is obtained only through an additive opt-in live observation projection. Existing status and legacy execution projections must keep their exact legacy field sets; an older or non-advertising binding receives no new reasoning field or event. Unsupported-operation, timeout, task exit, malformed response, empty evidence, and transport failure prove no reasoning support.

The Node Agent records receipt time and publishes a remaining freshness budget. The Controller deducts observation duration and derives local expiry; forwarding, serialization, heartbeat publication, or persistence must not refresh that budget. Reasoning tuples are excluded from heartbeat payloads and are not durable observation truth.

For an explicit negotiated request only, the Controller may apply a narrow reasoning-specific eligibility predicate to a fresh live result and select only an already loaded placement whose exact tuple matches. This predicate neither changes the generic capability envelope's diagnostic-only rule nor authorizes readiness, request admission, model admission, placement capacity, ordinary legacy scheduling, retry, or Runtime Endpoint projection. A cold placement is not selected merely to discover reasoning support.

The explicit negotiated request is the only opt-in. There is no separate operator configuration flag, so the projection cannot be enabled for legacy traffic or disabled for negotiated traffic independently of the request itself.

The eligibility predicate is restricted to `SPEC.md` §5.6 Tier 0 candidates. Negotiated reasoning therefore requires Tier 0 capacity that already exists, either from earlier traffic or from a §6.10 `preload = true` pinning policy. Tier 1 and Tier 2 candidates are ineligible; `residency_preference` and `max_cold_start_ms` neither widen nor narrow the negotiated candidate set, and a resolved cold-start budget is unreachable rather than a selection input. Absent Tier 0 capacity fails closed through the existing §7.2.7 `503 server_error` plus `runtime_incompatible` pre-dispatch mapping.

The live wave is bounded like the §5.5 compatibility status-probe wave rather than left to per-candidate fan-out: at most the first four deduplicated Tier 0 candidates under the §5.5 normalized target identity, one observation attempt per candidate for the entire logical request through terminal completion, a 2000 ms per-target timeout, and no retry. Automatic Attempt Retry does not reallocate the budget or start a second wave; attempt 2 chooses only among candidates the original wave already proved and otherwise declines with `no_alternative_node` under the §5.8 precedence.

The future implementation must reject, never truncate, evidence above these bounds: at most 16 tuples per placement; at most 128 bytes per identity or version string; at most 16 KiB reasoning evidence per placement; and at most 128 KiB aggregate observation evidence. Aggregate overflow omits reasoning while preserving the legacy status, health, and capacity projection.

## 4. Preparation proof before execution

`PrepareInference` is a unary Runtime Endpoint operation. It validates the exact frozen tuple against the current loaded binding before model invocation and returns:

- an authoritative proof echoing the complete tuple and the executing worker incarnation; and
- an opaque single-use authorization bound to that request, tuple, loaded binding, and current loaded worker instance.

The Controller validates the proof before it accepts the attempt as running and before it forwards execution. Only the matching execution request can redeem the authorization. Expiry, cancellation, duplicate redemption, worker restart, or loaded-instance replacement invalidates it. A proof or authorization failure must leave backend invocation, content emission, and usage emission at zero and fails through the existing pre-acceptance `runtime_incompatible` contract with `retry_decision = not_retryable`.

This closes the stream-event time-of-check/time-of-use gap while retaining Node Agent ownership of `Accepted`: negotiated `Accepted` is emitted only after preparation has been promoted and its authorization is redeemed. The authorization, preparation identifier, selected profile, and worker incarnation are attempt-local and are not retry identity.

## 5. Usage and retry boundaries

Issue #327 owns the presence-aware wire representation of exact cumulative totals. A present terminal total is known, including a present zero; an absent `Failed.usage` is missing evidence and must not normalize to zero. Reasoning-token subsets remain Worker-internal.

Issue #328 owns durable `output_usage_status` persistence and Controller lower-bound synthesis. This change does not add either behavior or change terminal conformance mapping.

Automatic retry pins all ten tuple fields and must use a different endpoint with a fresh proof for that same tuple; it never rerenders, renegotiates, or downgrades. An operator retry reuses `requests.canonical_request["reasoning"]` as its only frozen reasoning source when full capture made that value available. If it is absent or malformed, the retry fails closed with `retry_source_unavailable`; it must not reconstruct the contract from historical messages or add a database column.

## 6. Dormant activation and verified handoffs

The production reasoning tuple registry remains empty. No production tuple may be advertised or selected until #328 has landed parser, accounting, and capture guarantees and a model-qualification-governance record accepts the exact supported tuple. This contract creates no Qwen- or effort-tier-specific policy; issue #398 remains separate.

The following verified defects are handoffs only in this PR:

| ID | Required implementation owner | Handoff |
| --- | --- | --- |
| D1 | #327 | Permit the closed pre-acceptance `runtime_incompatible` code so the `SPEC.md` §7.2.7 evidence pair is representable. |
| D2 | #327 | Preserve `not_retryable` for the Controller-detected acceptance mismatch on both attempts, ahead of retry exhaustion. |
| D3 | #327 | Add the presence-aware `Failed.usage` wire field and absence-versus-zero tests. |
| D4 | #328 | Make `terminal_conformance + internal_error` representable; it is not part of this wire-contract implementation. |

No handoff above is fixed by this PR.
