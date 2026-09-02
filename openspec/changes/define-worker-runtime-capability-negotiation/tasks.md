## 1. Design Acceptance

- [x] 1.1 Run strict OpenSpec validation for this change and resolve every finding.
- [x] 1.2 Obtain owner acceptance of design decisions D1-D10 and the eight open questions on #354; record the decisions in `design.md` and on the issue.
- [x] 1.3 Confirm whether #327's incarnation and artifact identity is accepted; record the D7 loaded-binding disposition.

## 2. Schema And Generated Bindings

- [x] 2.1 Add `WorkerCapabilities` and `WorkerCapabilityProfile` messages and `WorkerStatusResponse.capabilities = 10` to `proto/orchard/worker/v1/worker_runtime.proto` with documented grammar, bounds, non-gating comment, and the reserved `loaded_binding` field 8 note.
- [x] 2.2 Regenerate Python and Elixir bindings with `mise exec -- mix proto.gen.worker`; confirm `Orchard.Node.Worker.V1.WorkerCapabilities` and `WorkerCapabilityProfile` exist and the legacy module surface is unchanged.
- [x] 2.3 Update the descriptor golden and extend the literal descriptor assertions in `worker_runtime_proto_contract_test.exs` and `test_worker_runtime_proto_contract.py` for the new messages and field 10.
- [x] 2.4 Add `python_worker_status_response_capabilities.pb` and `elixir_worker_capabilities.pb` fixtures; keep `python_worker_status_response.pb` as the previous-revision fixture asserting `capabilities == nil`.
- [x] 2.5 Run `mise exec -- mix proto.check.worker` and `scripts/test-worker-runtime-binding-drift.sh` clean.

## 3. Node Agent Evidence Classifier And Evaluator

- [x] 3.1 Create `Orchard.Node.WorkerCapabilityEvidence` with `classify/3`, `evaluate/4`, `canonical_tuple/1`, and `known_vocabulary/0`, with `@spec` on every public function.
- [x] 3.2 Unit-test receipt classification: `absent`, each `malformed` rule (zero major, empty tokens, bad grammar, bound overflow, zero `max_concurrency`), `minor = 0` valid, `duplicate_or_conflicting` for both identity rules, `incompatible` major.
- [x] 3.3 Unit-test evaluation precedence: `absent` after invalidation, `stale` before retained invalid verdict, `unknown` vs `unsupported`, Cartesian-combination rejection, exact-profile proof naming `profile_id` and `service_incarnation`.
- [x] 3.4 Add `worker_capabilities_freshness_window_ms` (default 15_000) to the `:orchard_node_agent, :runtime` config list via the `Orchard.Node.runtime_value/2` pattern and test the override.

## 4. Node Agent Wiring And Custody

- [ ] 4.1 Decode the envelope in `Orchard.Node.WorkerRuntimeAdapter.get_status/2` into a classified snapshot with monotonic receipt time and custody identity; never retain raw malformed bytes.
- [ ] 4.2 Retain and replace the snapshot in `Orchard.Node.WorkerProcess`; invalidate on `{:exit_status, ...}` and `{:gun_down, ...}` (the existing `:runtime_worker_exited` paths), before delegating `unload_model` and `load_model` to the adapter, and on incarnation change; expose `capability_snapshot/1`.
- [ ] 4.3 Expose `Orchard.Node.ModelManager.evaluate_worker_capability/3` for diagnostics and tests without touching `StatusResponse`, `Observation`, `PlacementCapacity`, or `RuntimeHealth`.
- [ ] 4.4 Emit `[:orchard, :node, :worker_capabilities, :classified]` and `[:orchard, :node, :worker_capabilities, :evaluated]`; add them to the telemetry allow-list test.
- [ ] 4.5 Add the non-gating regression: `WorkerProcess.status/2` minus the snapshot is identical for an absent envelope and a malformed envelope, and `classify_worker_status/1`, `status_max_concurrency/1`, `aggregate_supports_prompt_token_ids/2`, `health_from_status_result/2`, and `placement_capacity/4` are unchanged.
- [ ] 4.6 Add `NodeRuntimeStub` end-to-end tests in `orchard_node_agent_test.exs` for envelope present, absent, malformed, and incarnation change across a simulated worker restart.

## 5. MLX Worker And Provider-Neutral Conformance

- [x] 5.1 Generate `service_incarnation` once per process start in the MLX worker (16 random bytes, hex) and expose it through the backend status.
- [x] 5.2 Populate `WorkerCapabilities` in `WorkerRuntimeServicer.GetStatus` with `protocol_major = 1`, `protocol_minor = 1`, `provider_id = "mlx"`, `provider_version` from installed `mlx`, `implementation_version` from `orchard_worker_mlx.__version__`, and one exact MLX profile.
- [x] 5.3 Add an optional `capabilities` entry to the `Backend.status()` contract; `MlxBackend` always supplies it and `StubBackend` accepts an injected value so conformance can drive every taxonomy branch; add pytest cases for the populated envelope, an omitted envelope, and each malformed and duplicate variant.
- [x] 5.4 Run `ruff format`, `ruff check`, `pytest`, and `pytest --cov` for `native/orchard_worker_mlx`.

## 6. Documentation And SPEC Reconciliation

- [x] 6.1 Add one sentence to `SPEC.md` §4.10 naming the additive capability envelope on `GetStatus` and stating that its local evaluation is diagnostic-only until the separately reviewed cutover.
- [x] 6.2 Update Node Agent and MLX provider docs describing the envelope, the taxonomy, invalidation triggers, and the deferred loaded binding.
- [ ] 6.3 Update #266 and #354 to record the delivered slice without claiming normalized evidence, scheduling authority, or a wider version window.

## 7. Validation And Review

- [ ] 7.1 Run `make check-elixir` (format, compile with warnings as errors, credo strict, dialyzer, macOS test helpers, test, cover) clean.
- [ ] 7.2 Run the dependency-selected portable binding, provider-neutral conformance, Node Agent, MLX, and Apple Silicon MLX acceptance lanes; confirm the aggregate gate passes.
- [ ] 7.3 Run exact-head review on the final commit and address every finding.
- [ ] 7.4 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and review the generated `worker-runtime-providers` main spec for placeholder prose such as `Purpose TBD`.
