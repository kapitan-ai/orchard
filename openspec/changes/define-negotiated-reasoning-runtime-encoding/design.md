# Design: negotiated reasoning Runtime Endpoint encoding

## 1. Status, scope, and sequencing

This is an acceptance-only contract for issue #327. It reconciles the active package with `SPEC.md` §7.5.3a and the accepted `define-qualified-reasoning-effort` package. It does not modify protocol source, generated outputs, runtime code, persistence, or qualification data.

Implementation is blocked until all of these conditions hold:

1. PR #401 has merged, so the canonical request owns the exact reasoning identity transported by this contract.
2. This OpenSpec change and its `SPEC.md` amendment have been accepted.
3. An owner-approved schema design defines the concrete message declarations that realize the accepted allocation, without substituting an unapproved number or shape.

This reconciliation selects no enum value, `nil`-presence encoding, protobuf service or RPC declaration owner, evidence/preparation/proof message layout, or execution-redemption shape. It restates the `SPEC.md` §7.5.3a field allocation and the Runtime Endpoint Interface placement of unary `PrepareInference` as traceability rather than choosing either, and it adds no protocol source declaration.

## 2. Canonical tuple and loaded binding

The advertised and proven reasoning tuple has exactly these eleven equality fields:

1. generation policy;
2. projection;
3. reasoning effort;
4. model artifact digest;
5. chat-template digest;
6. render contract;
7. render contract version;
8. parser family;
9. parser version;
10. runtime contract version; and
11. event-binding version.

Every comparison is byte-exact after the validated canonical representation is formed. `source` is provenance and is not tuple identity. Independent value lists are invalid because they could fabricate a supported combination.

`SPEC.md` §7.5.3a already fixes the allocation this contract traces: `WorkerCapabilities` field 8 is the deferred `WorkerLoadedBinding` allocation with the previously recorded shape (`model_id`, `model_version`, `artifact_digest`, `selected_profile_id`), field 9 is its sibling placement-scoped reasoning envelope, and the shared tuple, evidence, preparation, and proof definitions live in `proto/cluster/v1/reasoning.proto`. Implementation must re-confirm those allocations when it begins and block on a conflicting upstream allocation rather than substitute a different number or shape.

That shared file keeps cross-boundary reasoning types out of both the Worker package and the Controller transport package, following the existing precedent in `proto/orchard/worker/v1/worker_runtime.proto`, which already imports `cluster/v1` files, but it does add one more `cluster.v1` dependency of the provider-neutral Worker Runtime boundary. `deprecate-node-runtime-grpc-compatibility` already records Worker Runtime imports as the reason runtime messages cannot be deleted early, and reasoning types join that same set. Relocating or removing the shared file is therefore owned by the later `cluster.v1` deprecation sequencing, not by this contract or its #327 implementation.

The declarations that realize that allocation remain blocked pending owner-approved schema design, which must decide the enum values, the representation of an omitted `reasoning_effort`, the protobuf service and RPC declaration ownership, the evidence, preparation, and proof message layouts, and the execution-redemption shape. This contract supplies none of those choices and assigns no source declaration in the present PR.

The omitted-`reasoning_effort` representation is load-bearing rather than cosmetic. Because every comparison is byte-exact, an encoding that left an absent effort indistinguishable from a selected tier would let an advertisement that selected no tier compare equal to a tier-selected request tuple, fabricating exactly the unadvertised combination the indivisible tuple exists to prevent. `SPEC.md` §7.5.3a requires the fresh observation to advertise the exact complete tuple including the selected effort when present, so the pending design must keep those two cases distinguishable.

A reasoning envelope is meaningful only with one valid loaded binding and that envelope's `service_incarnation`. Each advertised tuple's artifact digest equals that loaded binding's artifact digest, and its selected profile resolves exactly once in the same `WorkerCapabilities` envelope. A present but incomplete envelope, duplicate or conflicting tuple, unknown enum or version, missing required member, or invalid binding proves no support; it is not legacy omission. Loading, unloading, replacement, failed destructive unload, or worker teardown invalidates the affected evidence and any preparation associated with it.

## 3. Live discovery and the narrow eligibility exception

Reasoning evidence is obtained only through an additive opt-in live observation projection. Existing status and legacy execution projections must keep their exact legacy field sets; an older or non-advertising binding receives no new reasoning field or event. No unsupported-operation response, timeout, task exit, malformed response, empty evidence, or transport failure proves reasoning support; which of them also prove its absence is settled by the probe result classes below.

The Node Agent records receipt time and publishes a remaining freshness budget. The Controller deducts observation duration and derives local expiry; forwarding, serialization, heartbeat publication, or persistence must not refresh that budget. Reasoning tuples are excluded from heartbeat payloads and are not durable observation truth.

For an explicit negotiated request only, the Controller may apply a narrow reasoning-specific eligibility predicate to a fresh live result and select only an already loaded placement whose exact tuple matches. This predicate neither changes the generic capability envelope's diagnostic-only rule nor authorizes readiness, request admission, model admission, placement capacity, ordinary legacy scheduling, retry, or Runtime Endpoint projection. A cold placement is not selected merely to discover reasoning support.

The explicit negotiated request is the only opt-in. There is no separate operator configuration flag, so the projection cannot be enabled for legacy traffic or disabled for negotiated traffic independently of the request itself.

The eligibility predicate is restricted to `SPEC.md` §5.6 Tier 0 candidates. Negotiated reasoning therefore requires Tier 0 capacity that already exists, either from earlier traffic or from a §6.10 `preload = true` pinning policy. Tier 1 and Tier 2 candidates are ineligible; `residency_preference` and `max_cold_start_ms` neither widen nor narrow the negotiated candidate set, and a negotiated request resolves `timeout_at` through the §12.4 loaded-only formula under every policy, so an `allow_cold_load` policy adds neither the queue-wait nor the cold-start term.

Restricting selection to loaded placements must not turn a busy cluster into a permanently incompatible one, and scoping the wave to the eligible subset would have done exactly that. §5.6 tiers are drawn from the §5.5 eligible set, which excludes placements over concurrency, without Dispatch Headroom, or under a circuit breaker. A cluster with capable-but-saturated P1 and idle-but-incapable P2 would then present a one-element ranked list, exhaust it without a prover, and report permanent incompatibility on the strength of a placement it never looked at.

The wave's universe is therefore every loaded placement of the requested model on a scheduler-fresh node that passes §5.5's health condition, including the ones ordinary eligibility excludes solely for exhausted slots or Dispatch Headroom, exceeded placement concurrency, or exhausted tenant active capacity. Capacity eligibility then only decides whether the placement the predicate picks can be dispatched now.

Liveness exclusions stay in force, though. Probing a stale or unhealthy node buys nothing and costs something real: §5.7's late tie-break ranks lower active-request count above health, so a stale placement reporting zero active requests outranks a busy healthy one and can hold an in-flight slot it will never answer. Probing breaker-suppressed targets would also work against §5.10's suppression. Those targets are withheld from the wave, and their reasoning support stays unknown rather than disproven.

Two details in that gate are stated by reference rather than restated, because restating them is how they drift. "Healthy" is §5.5's own two-part condition — `healthy`, or `degraded` while the shared capacity authority decision is `legacy_pre_cutover` — so the probe gate is exactly the dispatch gate and tightens automatically at that cutover. Inventing a stricter reading would have been worse than useless: the durable phase is still `pre_cutover`, so `degraded` nodes are routinely dispatchable, and withholding them would leave support unknown on nodes ordinary scheduling happily uses. Breaker suppression is likewise read at both scopes §5.5 already enforces, the node-level breaker and the `(node, model)` placement-level breaker, so a placement-breakered placement on an otherwise healthy node is withheld too.

Because a suppressed target is never probed, the proving-but-undispatchable branch is about capacity and tenant caps only; it does not list breaker suppression, which that branch could never reach. A breaker that opens after a fresh proof is ordinary §5.10 suppression and §5.4 queue handling, not a reason to reclassify compatibility.

Unknown is the load-bearing third state. `runtime_incompatible` is reserved for a model with no loaded placement at all, or a universe in which every placement was probed and each affirmatively answered that it does not support the tuple. Everything else — a proven tuple without capacity, an incomplete probe, an elapsed wave deadline, a withheld node — is transient pre-dispatch unavailability on the existing `cluster_busy`/`model_busy` queue path under §5.4.

This is why the selection rule and the exhaustion rule had to be separated, and the separation runs along completion rather than along verdict. Three closed classes settle every probe result. A completed well-formed response carrying the exact tuple is proving, and nothing else may be selected. A completed well-formed response that reports the projection or the requested tuple unsupported — the §13.1 mixed-version answer from a binding carrying no negotiated reasoning contract included — or that returns valid evidence with an absent or mismatched tuple is confirmed non-support and counts toward exhaustion, because the endpoint answered the question. Everything remaining is unknown: syntactically malformed evidence, a timeout, a task exit, a transport failure, a missing or otherwise incomplete response. Unknown fails selection exactly as confirmed non-support does but cannot count toward exhaustion, or a brief partition on the one capable node would produce a permanent refusal for a transient condition.

Counting the non-advertising answer as confirmed is what closes §13.1's mixed-version case. A loaded universe of `N-1` bindings answers completely and negatively, so it exhausts and takes the `runtime_incompatible` mapping instead of waiting out `queue_timeout` on placements that will never gain the contract without an upgrade. A syntactically malformed reasoning envelope is deliberately on the other side of that line: it means the response could not be read, not that the endpoint denied support.

Only the queue outcome semantics match legacy traffic. Deadline duration does not: §12.4 keeps the loaded-only formula for every policy, so queue wait and each attempt's wave consume the same remaining request budget instead of a widened one. That is the accepted cost of not giving negotiated traffic a cold-start term it can never spend on a cold load.

The live wave is bounded like the §5.5 compatibility status-probe wave rather than left to per-candidate fan-out, but the bound is on concurrency rather than on reach: at most four probes in flight, each candidate observed at most once, one 2000 ms deadline for the whole wave, and no transport retry.

Bounding reach instead would have been wrong. The universe is built without the reasoning predicate — ordinary §5.5 eligibility, §5.6 Tier 0 grouping, the §5.7 ranking in force with its lexicographic `node_id` tie-break last — and then deduplicated on the §5.5 normalized target identity. That ranking is entirely capability-blind: loadedness, active count, health, cache affinity, safe tokenization, memory headroom, `node_id`. A fixed leading window of four would therefore let a heterogeneous cluster rank its incapable nodes first and refuse every negotiated request while capable capacity sat idle, deterministically and permanently.

The wave instead advances down the ranked order as probes finish, stopping when the highest-ranked proving placement is known, on exhaustion, or when the wave deadline elapses. The order still makes the sequence reproducible across identical attempts, and the two terminal stop reasons mean different things: exhaustion proves no loaded placement supports the tuple and takes the incompatibility mapping, while an elapsed deadline proves only that the remainder went unobserved and takes the transient queue-waitable path.

"First to prove" would have been ambiguous with four probes in flight, and the completion-order reading is both the easier implementation and the wrong one — it would quietly replace §5.7 ranking with a latency race, letting a `degraded` node beat a `healthy` one or a busier placement beat a quieter one purely by answering sooner. The wave therefore resolves to the highest-ranked proving placement, and a lower-ranked proof cannot end it until every higher-ranked in-flight probe has resolved non-proving.

The budget is counted per logical request, not per scheduling pass. Counting per Inference Attempt would have left the §5.4 requeue loop unbounded: a pre-start busy re-grant happens before `start_and_dispatch_attempt`, so it is not an attempt, and with a non-refreshable freshness budget every re-grant would otherwise need its own 2000 ms wave — many waves against a 3000 ms default `max_queue_wait_ms`.

So a logical request gets one initial fresh wave plus at most one more, and only for a real automatic attempt 2 after attempt 1 started. A busy re-grant runs no wave at all: it carries the earlier wave's selected placement as a non-authoritative scheduling hint, and `PrepareInference` revalidates the tuple against the current loaded binding before invocation, so nothing invokes on expired selection evidence. A re-granted pass that still cannot dispatch, or whose hint an unload or load replacement invalidated, requeues or terminalizes under §5.4's existing budget and `queue_timeout` rather than re-probing.

That hint is an explicit carve-out from §7.5.3a's own rule that an endpoint is selected only on a fresh observation, and the carve-out is stated there rather than left implicit. The hint claims no support and grants no invocation authority; `PrepareInference` is the authority. Attempt 2 resolves the same freshness tension differently — it runs a fresh wave — because it is choosing a *different* endpoint rather than returning to one an earlier wave already picked.

Attempt 2's wave is fresh rather than a reuse of attempt 1's evidence, because forwarding does not refresh a remaining freshness budget and stale evidence proves no support. It applies `exclude_node_ids` first, rebuilds and reorders its universe by the same deterministic rule, runs under the same four-in-flight bound and 2000 ms wave deadline with no transport retry, and obtains a new `PrepareInference` proof for the different endpoint it selects. Both waves draw on the one absolute deadline §12.4 assigned. A wave that proves no different eligible candidate declines with `no_alternative_node` under the §5.8 precedence.

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

Automatic retry pins all eleven tuple fields and must use a different endpoint with a fresh proof for that same tuple; it never rerenders, renegotiates, or downgrades. An operator retry reuses `requests.canonical_request["reasoning"]` as its only frozen reasoning source when full capture made that value available. If it is absent or malformed, the retry fails closed with `retry_source_unavailable`; it must not reconstruct the contract from historical messages or add a database column.

## 6. Dormant activation and verified handoffs

The production reasoning tuple registry remains empty. No production tuple may be advertised or selected until #328 has landed parser, accounting, and capture guarantees and a model-qualification-governance record accepts the exact supported tuple. The tuple includes the accepted `reasoning_effort = nil | low | medium | high` axis only as exact identity; this contract creates no Qwen- or effort-tier-specific policy and does not choose its wire representation.

The following verified defects are handoffs only in this PR:

| ID | Required implementation owner | Handoff |
| --- | --- | --- |
| D1 | #327 | Permit the closed pre-acceptance `runtime_incompatible` code so the `SPEC.md` §7.2.7 evidence pair is representable. |
| D2 | #327 | Preserve `not_retryable` for the Controller-detected acceptance mismatch on both attempts, ahead of retry exhaustion. |
| D3 | #327 | Add the presence-aware `Failed.usage` wire field and absence-versus-zero tests. |
| D4 | #328 | Make `terminal_conformance + internal_error` representable; it is not part of this wire-contract implementation. |

No handoff above is fixed by this PR.
