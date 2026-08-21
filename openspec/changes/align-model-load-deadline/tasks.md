# Tasks: align model-load deadline with cold-start stage cap

## 1. Contract and validation

- [x] 1.1 Confirm `proposal.md` and `design.md` trace to the cited `SPEC.md` sections.
- [x] 1.2 Run strict OpenSpec validation for the new change package.

## 2. Deadline alignment

- [x] 2.1 Move effective load-deadline computation into `RequestDispatcher`.
- [x] 2.2 Stop stamping the absolute Request deadline into `EnsureModelLoadedRequest` in `RequestOrchestrator`.
- [x] 2.3 Derive gRPC and BEAM transport timeouts from the same effective deadline.
- [ ] 2.4 Record the limiting constraint (`:cold_stage_budget` vs `:request_budget`) in dispatch metrics/attempt evidence.

## 3. Error normalization

- [x] 3.1 Normalize integer gRPC status `4` and atom `:deadline_exceeded` to `:node_timeout` in `grpc_node_runtime_client.ex`.
- [x] 3.2 Extend `ModelLoadFailure` to treat `{:rpc_error, integer, _}` and bare `:timeout` as timeout-category failures.
- [x] 3.3 Keep `load_timeout` in the `inference_attempt_failure.ex` model-load code allowlist.
- [x] 3.4 Bound the local-BEAM `safe_apply` branch and return `:beam_node_timeout` on timeout.

## 4. Node Agent hardening

- [x] 4.1 Reject late load-completion results that arrive after all waiters have expired.
- [x] 4.2 Ensure artifact caching is preserved but runtime placement is not marked loaded without an owner.

## 5. Regression tests

- [x] 5.1 Dispatch: effective load deadline equals `min(timeout_at, now + model_load_timeout_ms)`.
- [x] 5.2 Model-load failure: integer gRPC status 4 → `timeout` category.
- [ ] 5.3 Chat completions: non-streaming 504 and streaming SSE `load_timeout` with no `[DONE]`.
- [ ] 5.4 Request-timeout-during-load path persists `state=timed_out`.
- [x] 5.5 BEAM client: local-node timeout enforcement.
- [x] 5.6 Node Agent: late completion after waiter expiry does not leave a loaded placement.
- [ ] 5.7 End-to-end cold-load timeout with cap < actual load < Request deadline for both gRPC and BEAM.

## 6. Quality and handoff

- [x] 6.1 Run `mise exec -- mix format`.
- [x] 6.2 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 6.3 Run `mise exec -- mix credo --strict`.
- [x] 6.4 Run `mise exec -- mix dialyzer`.
- [x] 6.5 Run affected test slices first, then full `mise exec -- mix test`.
- [x] 6.6 Run `mise exec -- mix test --cover` on affected test slices.
- [x] 6.7 Re-run OpenSpec strict validation.
- [x] 6.8 Open stacked PR with sanitized summary and no raw logs/secrets.
