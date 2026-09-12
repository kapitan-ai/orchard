# Design: negotiated reasoning Runtime Endpoint encoding

## 1. Status, scope, and sequencing

This is a documentation-only contract for issue #327. It records the
owner-confirmed schema decisions in §2.1. It does not amend `SPEC.md`, and it
adds no protocol declaration, generated binding, runtime code, persistence,
qualification data, public control, usage writer, production registry, or live
qualification. Its only protocol-source edit is a comment-only field 8
reservation trace in `proto/orchard/worker/v1/worker_runtime.proto`.

The `SPEC.md` §7.5.3a, §5.6, and §5.5 language this package traces already
landed on `main`, including the indivisible eleven-field tuple. PR #401 has
merged, so the canonical request owns the exact reasoning identity this
contract will later transport. Field availability was re-confirmed at
`a1421755830811dc5daef77341ae47df2d0b0d71`.

Schema declarations, generated bindings, and runtime implementation remain
separate and blocked until this change is accepted. After acceptance, a
separate implementing change must re-confirm source field availability and add
declarations, generated bindings, reciprocal N/N-1 fixtures, and runtime
behavior atomically. A conflicting upstream allocation blocks implementation
rather than permitting a substitute number or shape. Task 2.2 must not proceed
on an implementer's own schema judgment; it must reproduce §2.1 unchanged.

## 2. Canonical tuple and loaded binding

The advertised and proven reasoning tuple has exactly these eleven equality
fields:

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

Every comparison is byte-exact after the validated canonical representation is
formed. `source` is provenance and is not tuple identity. Independent value
lists are invalid because they could fabricate a supported combination.

At the reviewed base, `WorkerCapabilities` uses fields 1 through 7, reserves
field 8 explicitly for the deferred `WorkerLoadedBinding`, and has no field 9.
The accepted future schema allocation is therefore:

- lift the reservation and use `WorkerCapabilities.loaded_binding = 8` with the
  four-member shape sourced from D7 of
  `define-worker-runtime-capability-negotiation` (`model_id`, `model_version`,
  `artifact_digest`, `selected_profile_id`); and
- add the sibling placement-scoped reasoning envelope at `WorkerCapabilities`
  field 9.

D7 records that four-member shape provisionally and assigns no tag numbers. The
owner-confirmed §2.1 record supplies the member tags, `string` types, presence,
artifact/profile linkage, and the outer-incarnation association. This package
does not lift the field 8 reservation or declare those fields.

The future schema also introduces `proto/cluster/v1/reasoning.proto` for the
shared tuple, evidence, preparation, and proof definitions. It prevents either
the Worker package or Controller transport package from owning cross-boundary
reasoning types. This contract assigns no source declaration in the present PR.

That placement follows the existing precedent in
`proto/orchard/worker/v1/worker_runtime.proto`, which already imports
`cluster/v1` files, but it does add one more `cluster.v1` dependency of the
provider-neutral Worker Runtime boundary. `deprecate-node-runtime-grpc-compatibility`
already records Worker Runtime imports as the reason runtime messages cannot be
deleted early, and reasoning types join that same set. Relocating or removing
the shared file is therefore explicitly owned by the later `cluster.v1`
deprecation sequencing, not by this contract or its #327 implementation; that
deprecation must sequence the reasoning definitions alongside the existing
Worker Runtime imports rather than treating them as an unplanned blocker.

A reasoning envelope is meaningful only with one valid loaded binding and that
Worker Runtime's `service_incarnation`. Each advertised tuple's artifact digest
equals that loaded binding's artifact digest, and its selected profile resolves
exactly once in the same `WorkerCapabilities` envelope. A present but incomplete
envelope, duplicate or conflicting tuple, unknown enum or version, missing
required member, or invalid binding proves no support; it is not legacy
omission. Loading, unloading, replacement, failed destructive unload, or worker
teardown invalidates the affected evidence and any preparation associated with
it.

## 2.1 Owner-confirmed schema decision record

The owner confirmed the following complete decision record. It is the sole
schema-decision source for this package. It is reproduced here as proposed
declarations only and does not add or alter a `.proto` file. Schema
declarations, generated bindings, and runtime implementation remain separate
and blocked until this change is accepted.

All cross-boundary types below, including `WorkerLoadedBinding`, are declared
once in `proto/cluster/v1/reasoning.proto` (`package cluster.v1`) and import
only `cluster/v1/common.proto`. `worker_runtime.proto` and `runtime.proto`
import `reasoning.proto`; this creates no import cycle.

### Shared types, loaded binding, tuple, and live observation

```proto
enum ReasoningEffort {
  REASONING_EFFORT_UNSPECIFIED = 0;
  REASONING_EFFORT_LOW = 1;
  REASONING_EFFORT_MEDIUM = 2;
  REASONING_EFFORT_HIGH = 3;
}

message ReasoningEffortSelection {
  ReasoningEffort effort = 1;
}

message WorkerLoadedBinding {
  string model_id = 1;
  string model_version = 2;
  string artifact_digest = 3;
  string selected_profile_id = 4;
}

message NegotiatedReasoningTuple {
  string generation_policy = 1;
  string projection = 2;
  ReasoningEffortSelection reasoning_effort = 3;
  string model_artifact_digest = 4;
  string chat_template_digest = 5;
  string render_contract = 6;
  string render_contract_version = 7;
  string parser_family = 8;
  string parser_version = 9;
  string runtime_contract_version = 10;
  string event_binding_version = 11;
}

message ReasoningEvidenceEnvelope {
  repeated NegotiatedReasoningTuple tuples = 1;
  bytes loaded_instance_id = 2;
}

message ReasoningObservationRequest {}

message ReasoningEvidence {
  WorkerLoadedBinding loaded_binding = 1;
  ReasoningEvidenceEnvelope envelope = 2;
  string service_incarnation = 3;
  uint64 remaining_freshness_ms = 4;
}

message ReasoningNonAdvertising {}
message ReasoningUnknown {}

message ReasoningLiveObservation {
  oneof result {
    ReasoningEvidence evidence = 1;
    ReasoningNonAdvertising non_advertising = 2;
    ReasoningUnknown unknown = 3;
  }
}
```

`WorkerCapabilities` lifts its reservation into these singular, presence-aware
fields:

```proto
cluster.v1.WorkerLoadedBinding loaded_binding = 8;
cluster.v1.ReasoningEvidenceEnvelope reasoning_evidence = 9;
```

`WorkerStatusRequest` and `StatusRequest` each gain the singular presence
marker:

```proto
cluster.v1.ReasoningObservationRequest reasoning_observation = 1;
```

`StatusResponse` gains:

```proto
cluster.v1.ReasoningLiveObservation reasoning_observation = 14;
```

Rules:

- A missing `ReasoningEffortSelection` means the negotiated `nil` effort. A
  present wrapper with `UNSPECIFIED` is invalid; only `LOW`, `MEDIUM`, and
  `HIGH` are selected tiers. A selected tier is valid only for
  `generation_policy = enabled` and `projection = final_only`.
- All `WorkerLoadedBinding` strings are required and non-empty when the binding
  is present. Omission of field 8 means a non-advertising binding.
  `artifact_digest` equals each advertised or proven tuple's
  `model_artifact_digest`; `selected_profile_id` resolves exactly once to a
  profile in the same `WorkerCapabilities.profiles`.
- `service_incarnation` remains the existing outer
  `WorkerCapabilities.service_incarnation = 6`; it is not duplicated inside the
  binding or envelope. `ReasoningEvidence.service_incarnation` is an
  equality-checked live-observation echo of that outer value.
- `reasoning_evidence.tuples` is cardinality `0..16`; every included tuple is
  complete, unique, and non-conflicting. A valid empty list means confirmed
  non-support. `loaded_instance_id` is required and exactly 16 raw bytes.
- A present `ReasoningEvidence` requires all four members. Its binding,
  envelope, and incarnation must equal Worker fields 8, 9, and 6 respectively;
  its freshness must be positive to prove selection. Malformed, partial, stale,
  duplicate, conflicting, or mismatched evidence is `unknown`, never legacy or
  support.
- The request marker is emitted only for an explicit negotiated request.
  Without it, legacy status and execution projections remain unchanged.
  `non_advertising` is the complete negative result for an N-1 or
  non-advertising binding; no typed reasoning execution event is sent to that
  binding.

### Preparation and redemption

```proto
message FrozenExecutionInput {
  string request_id = 1;
  string controller_session_id = 2;
  string model_id = 3;
  string version = 4;
  bytes rendered_prompt_utf8 = 5;
  uint32 input_tokens = 6;
  GenerationParams params = 7;
  uint64 deadline_unix_ms = 8;
  bytes metadata_json = 9;
  string cache_affinity_fingerprint = 10;
  repeated uint32 prompt_token_ids = 11;
  bool return_token_ids = 12;
  bool return_logprobs = 13;
}

message PrepareInferenceRequest {
  FrozenExecutionInput input = 1;
  NegotiatedReasoningTuple tuple = 2;
  WorkerLoadedBinding expected_binding = 3;
  string expected_service_incarnation = 4;
  bytes expected_loaded_instance_id = 5;
}

message PrepareInferenceProof {
  string request_id = 1;
  string controller_session_id = 2;
  NegotiatedReasoningTuple tuple = 3;
  WorkerLoadedBinding actual_binding = 4;
  string service_incarnation = 5;
  bytes loaded_instance_id = 6;
}

message PreparationRedemption {
  bytes authorization = 1;
}

message PrepareInferenceResponse {
  PrepareInferenceProof proof = 1;
  bytes authorization = 2;
  uint64 authorization_ttl_ms = 3;
}
```

Only `orchard.worker.v1.WorkerRuntimeService` owns the protobuf RPC:

```proto
rpc PrepareInference(cluster.v1.PrepareInferenceRequest)
    returns (cluster.v1.PrepareInferenceResponse);
```

`NodeRuntimeService` gains no `PrepareInference` RPC. That sentence records
protobuf service ownership only. `ExecuteInferenceRequest` gains only:

```proto
cluster.v1.PreparationRedemption preparation_redemption = 14;
```

Rules:

- Every request and proof message member is required semantically; required
  strings are non-empty. `expected_loaded_instance_id` and proof
  `loaded_instance_id` are exactly 16 raw bytes.
- `FrozenExecutionInput` is the frozen snapshot of `ExecuteInferenceRequest`
  fields 1–13. Redemption is valid only when those execution fields exactly
  match the prepared snapshot, plus the exact tuple, binding, service
  incarnation, and loaded-instance ID.
- Authorization is exactly 32 random bytes, worker-owned, memory-only, never
  logged or persisted, and has a positive Worker-monotonic TTL. It binds the
  complete frozen input, tuple, binding, request ID, controller session ID,
  service incarnation, and loaded-instance ID.
- Redemption is atomic before model invocation. Expiry, cancellation, worker
  restart, unload or replacement, mismatch, duplicate redemption, or any
  already-consumed authorization fails pre-acceptance as `runtime_incompatible`,
  with no invocation, content, or usage.
- A successful new load generates exactly one 16-byte raw CSPRNG
  `loaded_instance_id`. A load replacement, load start, unload start, failed
  destructive unload, or worker teardown invalidates the prior identity,
  evidence, and authorization. An already-loaded idempotent acknowledgement
  does not create a new instance identity.
- An unconsumed duplicate `PrepareInference` whose complete request is
  byte-identical to the original returns the same proof and authorization, with
  the then-remaining TTL and no TTL extension. A changed, expired, invalidated,
  or consumed preparation fails closed.

### Terminal usage and typed event

```proto
message Failed {
  string code = 1;
  string message = 2;
  bool retryable = 3;
  TokenUsage usage = 4;
}
```

`Failed.usage` is singular message presence: absent means missing
terminal-usage evidence; present `{0,0,0}` is known zero. Legacy workers may
omit it. Negotiated terminal conformance requires exact usage rather than
treating absence as zero.

No typed reasoning `InferenceEvent` is added or reserved now. `InferenceEvent`
remains tags 1–8 unchanged.

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

The owner-confirmed protobuf RPC owner is recorded in §2.1: only
`orchard.worker.v1.WorkerRuntimeService` declares `PrepareInference`.
`NodeRuntimeService` gains no `PrepareInference` RPC. That sentence records
protobuf service ownership only.

The Controller validates the proof before it accepts the attempt as running and before it forwards execution. Only the matching execution request can redeem the authorization. Expiry, cancellation, duplicate redemption, worker restart, or loaded-instance replacement invalidates it. A proof or authorization failure must leave backend invocation, content emission, and usage emission at zero and fails through the existing pre-acceptance `runtime_incompatible` contract with `retry_decision = not_retryable`.

This closes the stream-event time-of-check/time-of-use gap while retaining Node Agent ownership of `Accepted`: negotiated `Accepted` is emitted only after preparation has been promoted and its authorization is redeemed. The authorization, preparation identifier, selected profile, and worker incarnation are attempt-local and are not retry identity.

## 5. Usage and retry boundaries

Issue #327 owns the presence-aware wire representation of exact cumulative totals. A present terminal total is known, including a present zero; an absent `Failed.usage` is missing evidence and must not normalize to zero. Reasoning-token subsets remain Worker-internal.

Issue #328 owns durable `output_usage_status` persistence and Controller lower-bound synthesis. This change does not add either behavior or change terminal conformance mapping.

Automatic retry pins all eleven tuple fields and must use a different endpoint with a fresh proof for that same tuple; it never rerenders, renegotiates, or downgrades. An operator retry reuses `requests.canonical_request["reasoning"]` as its only frozen reasoning source when full capture made that value available. If it is absent or malformed, the retry fails closed with `retry_source_unavailable`; it must not reconstruct the contract from historical messages or add a database column.

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
