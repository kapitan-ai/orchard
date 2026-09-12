## Context

`WorkerStatusResponse` in `proto/orchard/worker/v1/worker_runtime.proto` uses fields 1-9.
Fields `ready`, `max_concurrency`, and `supports_prompt_token_ids` gate behavior today; `memory_budget` and `prefix_cache` are documented observe-only.
The Node Agent calls `GetStatus` on demand from `Orchard.Node.WorkerRuntimeAdapter.wait_for_worker_ready/3`, `Orchard.Node.WorkerProcess.status/2`, `Orchard.Node.WorkerProcess.worker_request_limit/1`, and `Orchard.Node.ModelManager.runtime_health_and_memory_budgets/1`; there is no background poller and no retained status snapshot.
Subprocess custody lives in `Orchard.Node.WorkerRuntimeAdapter`, `Orchard.Node.WorkerProcessLifecycle` (`process_identity/1`), and `Orchard.Node.RuntimeProcessReaper`.
No process-level incarnation exists; the only restart tracking is the per-model crash counter in `Orchard.Node.ModelManager`.
The MLX worker builds the response in `WorkerRuntimeServicer.GetStatus` (`native/orchard_worker_mlx/src/orchard_worker_mlx/service.py`) and exposes `orchard_worker_mlx.__version__`; the installed `mlx` version is available through `importlib.metadata`.
Issue #327's incarnation and artifact-identity encoding is not yet accepted (`define-reasoning-output-contract/tasks.md` item 3.1 is open).

Constraints: additive wire change only; existing wire numbers and semantics preserved; no gating change; no Runtime Endpoint projection; no provider-name or OS-name inference (ADR 0026); all bindings generated from the neutral source with drift checks (ADR 0025, PR #352).

## Goals / Non-Goals

Goals:

- One additive envelope on `GetStatus` carrying protocol and provider identity, indivisible profiles, and a non-secret incarnation.
- A Node Agent-owned classifier and evaluator with a deterministic evidence taxonomy and no behavioral authority.
- MLX populates the envelope truthfully; the stub backend exercises every taxonomy branch in provider-neutral conformance.
- Fixtures and descriptor golden prove additive decoding across the two schema revisions.

Non-goals:

- Reasoning tuples, acceptance proof, parser, projection, usage, retry, events, `runtime_incompatible` (#327).
- Runtime Endpoint projection, Controller persistence, scheduler input, host capability-provider seam (#266 items 3-5).
- Console, CLI, packaging, lifecycle, Linux, CUDA, ROCm, new provider support claims, public API.

## Decisions

### D1. Envelope placement: one nested message at `WorkerStatusResponse.capabilities = 10`

```proto
message WorkerCapabilities {
  uint32 protocol_major = 1;          // required, >= 1
  uint32 protocol_minor = 2;          // required, >= 0; additive revisions bump minor
  string provider_id = 3;             // required token, e.g. "mlx"
  string provider_version = 4;        // required, non-empty, bounded
  string implementation_version = 5;  // required, non-empty, bounded (worker package version)
  string service_incarnation = 6;     // required token, non-secret, unique per process start
  repeated WorkerCapabilityProfile profiles = 7;
  // reserved 8;  loaded_binding — see D7
}

message WorkerCapabilityProfile {
  string profile_id = 1;              // required token, unique within response
  string artifact_format = 2;         // required token
  string acceleration = 3;            // required token
  string device_binding = 4;          // required token
  string memory_semantics = 5;        // required token
  uint32 max_concurrency = 6;         // required, >= 1
  repeated string runtime_features = 7;    // set; sorted unique tokens
  repeated string cache_capabilities = 8;  // set; sorted unique tokens
}
```

Rationale: a nested message gives clean presence (`nil` means `absent`) without proto3 `optional`, keeps the legacy fields untouched, and lets the whole envelope be classified as one unit.
Alternative rejected: top-level scalar fields on `WorkerStatusResponse` (no unit presence, harder to classify as a whole).
Alternative rejected: proto3 `optional` scalars (adds `proto3_optional` descriptor features to the golden and generator surface for no gain once "zero means missing" is defined below).

Field numbers are proposed here and authorized only by owner acceptance of this design.

### D2. Presence semantics: omitted envelope is `absent`; a present envelope with a zero or empty required field is `malformed`

Because proto3 scalars have no presence, a required scalar's zero value inside a present envelope is a structural defect and classifies as `malformed`.
`protocol_minor = 0` is valid (it is not a required-nonzero field).
Empty `profiles` is valid and simply proves nothing (every query yields `unsupported`).

Token grammar for all identifier strings: `^[a-z0-9][a-z0-9_.-]{0,63}$`.
Version strings: non-empty, at most 128 bytes, printable ASCII.
Bounded repeated fields: at most 64 profiles, 64 features, and 64 cache capabilities per profile; exceeding a bound is `malformed`.
The Node Agent never logs or stores the raw bytes of a malformed envelope, only the field path that failed: a `malformed` snapshot carries `envelope: nil` and `detail: <field path>`, so telemetry derived from it reports the classification and path but no provider-supplied identifier.
`duplicate_or_conflicting` and `incompatible` snapshots have passed structural validation and retain the decoded envelope for diagnostics.
On the worker side, the servicer copies the backend's envelope without validating it, but it never lets capability construction fail `GetStatus`: any backend value that cannot be represented faithfully (non-dict envelope, non-list or non-dict profiles, out-of-range integers, unencodable strings) is emitted as a present envelope with `protocol_major = 0`, which the Node Agent classifies as `malformed` rather than `absent`.

### D3. Compatibility: protocol major must equal the Node Agent's supported major; provider identity is diagnostic only

The Node Agent supports `protocol_major = 1`.
Any other major is `incompatible`.
Any minor is accepted; a minor greater than the Node Agent's known minor is compatible but may carry unrecognised vocabulary (see D5 `unknown`).
Provider identity and versions are recorded for diagnostics and telemetry and are never a compatibility input, per ADR 0026's ban on provider-name inference.
Alternative rejected: a provider allow-list (re-encodes MLX as the default provider).

### D4. Canonical profile identity and indivisibility

A profile's canonical tuple is `(artifact_format, acceleration, device_binding, memory_semantics, max_concurrency, sorted(runtime_features), sorted(cache_capabilities))`.
Two rules, both fail-closed for the whole response as `duplicate_or_conflicting`:

1. `profile_id` must be unique within the response.
2. The canonical tuple must be unique within the response.

Rule 1 makes the loaded binding and telemetry unambiguous; rule 2 prevents two identifiers from claiming one capability set with different names.
Repeated fields inside a profile are sets attached to that one profile; they do not combine across profiles.
Queries are evaluated against whole profiles only, so no cross-profile Cartesian product can be inferred.
Alternative rejected: deriving identity purely from the tuple with no wire `profile_id` (would force the loaded binding to reference a profile by index or by re-sending the tuple).

### D5. Evidence taxonomy and deterministic precedence

Classification happens at two moments.

At receipt (once per `GetStatus` response, inside `WorkerRuntimeAdapter.get_status/2`):

1. `absent` — envelope omitted.
2. `malformed` — any D2 structural rule fails.
3. `duplicate_or_conflicting` — any D4 rule fails, or a loaded binding references an unadvertised `profile_id`.
4. `incompatible` — D3 major mismatch.
5. `valid` — retained with receipt time and custody identity.

At evaluation (per query against the retained snapshot):

1. `absent` — no retained snapshot, or the snapshot was invalidated (D6).
2. `stale` — `now - received_at_monotonic_ms > freshness_window_ms`.
3. The receipt classification if it was not `valid` (`malformed`, `duplicate_or_conflicting`, `incompatible`).
4. `unknown` — no profile matches, and at least one profile that fails to match does so only because it carries a component value outside the Node Agent's known vocabulary for that dimension.
5. `unsupported` — no profile matches and rule 4 does not apply.
6. `{:supported, profile_id, service_incarnation}`.

Rationale for ordering: liveness (`absent`, `stale`) is evaluated before the retained validity verdict because invalid-but-fresh and invalid-and-stale should not produce different diagnostics for the same defect; query-level results come last because they only make sense over fresh valid compatible evidence.
Known vocabulary per dimension lives in `Orchard.Node.WorkerCapabilityEvidence` as module attributes seeded with the values the MLX worker emits; extending it is an additive code change, not a contract change.

### D6. Freshness and invalidation are Node Agent-owned

`WorkerProcess` retains the latest snapshot as `%{classification, envelope, received_at_monotonic_ms, custody: {os_pid, process_identity}, service_incarnation}` and replaces it on every successful `GetStatus`.
Receipt time is `System.monotonic_time(:millisecond)` at decode; provider-supplied timestamps are never read for freshness.
Default `freshness_window_ms` is 15_000, configured as `worker_capabilities_freshness_window_ms` inside the existing `:orchard_node_agent, :runtime` keyword list and read through the `Orchard.Node.runtime_value/2` pattern that other worker settings such as `worker_ready_timeout_ms` already use.
Invalidation (snapshot discarded, evaluation returns `absent`) occurs on: `WorkerProcess` handling `{:exit_status, ...}` from the worker port or `{:gun_down, ...}` from the UDS channel (both already map to `:runtime_worker_exited`); the `WorkerProcess` `unload_model` call before it delegates to `state.adapter.unload_model`; the `WorkerProcess` `load_model` call before it delegates to `state.adapter.load_model`; and a successful `GetStatus` whose `service_incarnation` differs from the retained one (the new snapshot replaces the old one; the incarnation change is emitted as telemetry).
`service_incarnation` is generated by the worker at process start as 16 random bytes hex-encoded; it is not derived from any secret and is safe to log.

### D7. Loaded binding is deferred in this change

Because #327's incarnation and artifact-identity encoding is not accepted at design time, field 8 (`loaded_binding`) is reserved in the proto comment and not added.
The message shape recorded for the later additive change is `WorkerLoadedBinding { string model_id; string model_version; string artifact_digest; string selected_profile_id; }`, where `artifact_digest` must be whichever exact identity #327 accepts.
#327 acceptance alone does not lift the deferral. `define-negotiated-reasoning-runtime-encoding` is documentation-only, and its §1 condition 3 additionally requires a separate accepted OpenSpec schema package and durable `docs/decisions/**` record. Once those are accepted before implementation of this change begins, the owner may lift the deferral and the implementer adds field 8 under that recorded design with the D5 rule already written.

### D8. Local proof surface

New module `Orchard.Node.WorkerCapabilityEvidence` (pure functions, fully unit-testable without a worker):

- `classify(%WorkerCapabilities{} | nil, received_at_ms, custody) :: snapshot` — the adapter extracts `capabilities` from the decoded `WorkerStatusResponse` and passes only the envelope, so the classifier stays independent of the surrounding legacy status fields
- `evaluate(snapshot | nil, query, now_ms, opts) :: result` — `opts` requires `freshness_window_ms`; the caller supplies it from `Orchard.Node.worker_capabilities_freshness_window_ms/0`
- `canonical_tuple/1`, `known_vocabulary/0`

Query shape: `%{artifact_format, acceleration, device_binding, memory_semantics, min_concurrency, runtime_features: [..], cache_capabilities: [..]}`; a profile matches when every scalar dimension is inside the known vocabulary and equals the query, `max_concurrency >= min_concurrency`, and every requested feature and cache capability is present in the profile's sets.
A profile carrying a value outside the known vocabulary on any scalar dimension can never be a proof; it yields `unknown` when every other matching condition holds, which is the fail-closed direction for a provider the Node Agent has not yet learned.

Access: `WorkerProcess.capability_snapshot/1` and `ModelManager.evaluate_worker_capability/3` for tests and diagnostics.
Telemetry: `[:orchard, :node, :worker_capabilities, :classified]` with metadata `%{model_id, version, classification, provider_id, protocol_major, protocol_minor, profile_count, incarnation_changed}` and `[:orchard, :node, :worker_capabilities, :evaluated]` with `%{model_id, version, result}`.
Neither the snapshot nor any result is written into `StatusResponse`, `Observation`, `PlacementCapacity`, `RuntimeHealth`, or any Controller-visible structure.

### D9. Fixture meaning

- Existing `python_worker_status_response.pb` stays as the previous-revision fixture and must decode with `capabilities == nil`.
- New `python_worker_status_response_capabilities.pb` is the current-revision fixture encoded by the Python binding.
- New `elixir_worker_capabilities.pb` is a `WorkerCapabilities` message encoded by the Elixir binding and decoded by Python.
- The descriptor golden gains the two new messages and field 10.

These fixtures prove additive wire decoding across two schema revisions.
They do not widen `SPEC.md` §13.1, which still binds node agent `N` to bundled worker `N` only.

### D10. Interaction with live status values

No existing field changes meaning.
`classify_worker_status/1`, `status_max_concurrency/1`, `aggregate_supports_prompt_token_ids/2`, `health_from_status_result/2`, and `placement_capacity/4` are not modified.
A `WorkerStatusResponse` with a `malformed` envelope still yields the same readiness, capacity, and health as one without an envelope.
This is asserted by a regression test that compares the full `WorkerProcess.status/2` map minus the snapshot for both inputs, and by `NodeRuntimeStub` end-to-end assertions on `StatusResponse` and `EnsureModelLoadedResponse`.
Four of the five named functions are `defp`, so the regression exercises them through their public callers rather than by name.

### D11. Python backend and fixture mechanics

The `Backend` protocol's `status()` return (`backends.py`) gains an optional `capabilities` entry that `WorkerRuntimeServicer.GetStatus` copies into the envelope when present; `MlxBackend` always supplies it, and `StubBackend` accepts an injected value so conformance tests can drive every taxonomy branch including omission.
Fixtures are hand-built in `tests/test_worker_runtime_proto_contract.py` (as `_python_worker_status_fixture()` is today) and in the Elixir contract test; `scripts/generate-worker-runtime-bindings.sh` regenerates bindings and the descriptor golden but not `.pb` fixtures, and this change does not alter that.

## Risks / Trade-offs

- [Zero-means-missing rejects a legitimately zero `protocol_minor` if a future rule is misread] → `protocol_minor` is explicitly excluded from the nonzero rule; tests cover `minor = 0`.
- [Bounded lengths and grammars could reject a future legitimate provider token] → bounds are generous, documented in the proto, and changing them is an additive minor bump.
- [Retaining a snapshot introduces the first cached worker status; a stale-but-cached value could be misread as live] → the snapshot is never projected into any live status path (D8, D10) and `stale` is classified before any query result.
- [The `unknown` rule requires a vocabulary table that will drift from providers] → the table is diagnostic only; drift produces `unknown` rather than a false proof, which is the fail-closed direction.
- [Deferring the loaded binding leaves a reserved field number that a later change might renumber] → the proto comment reserves field 8 and D7 fixes the shape; the OpenSpec archive records it.
- [Adding fields to `WorkerStatusResponse` triggers every consuming lane] → this is intended by `portability-validation`; the MLX acceptance lane must run.

## Migration Plan

1. Accept this design (owner). No code before acceptance.
2. Add the proto messages and field 10; regenerate bindings; update descriptor golden and fixtures; run `mix proto.check.worker` and the drift script.
3. Add `Orchard.Node.WorkerCapabilityEvidence` with unit tests covering every taxonomy branch and precedence.
4. Wire decode into `WorkerRuntimeAdapter.get_status/2`, snapshot custody and invalidation into `WorkerProcess`, and diagnostic access into `ModelManager`.
5. Populate the envelope in the MLX worker and the stub backend; add conformance cases for each branch.
6. Run the full Elixir and native workflows and the dependency-selected lanes.

Rollback: the change is additive; reverting the Node Agent decode leaves an older Node Agent that ignores field 10, and reverting the worker leaves a newer Node Agent that classifies `absent`. Neither direction changes behavior because the evaluator gates nothing.

## Open Questions

None outstanding.
The owner accepted D1-D11 and the eight decisions below on 2026-09-02 under #354.
At acceptance #327 had no accepted incarnation or artifact-identity encoding, so D7's deferral of the loaded binding stands and field 8 remains reserved.

Decisions accepted:

1. Confirm D1 placement and field numbers (10; profile message tags as listed).
2. Confirm D3: provider identity is diagnostic only; only protocol major gates compatibility.
3. Confirm D4 dual identity rule (unique `profile_id` and unique canonical tuple).
4. Confirm D5 precedence, in particular `stale` before the retained validity verdict.
5. Confirm D7: defer the loaded binding, or lift the deferral if #327 has been accepted by then.
6. Confirm the default `freshness_window_ms = 15_000` and its placement as `worker_capabilities_freshness_window_ms` under the existing `:runtime` config list.
7. Confirm D8 module name, query shape, and telemetry event names.
8. Confirm D9 fixture set and that `SPEC.md` §4.10 gains one sentence naming the envelope as non-gating until cutover.
