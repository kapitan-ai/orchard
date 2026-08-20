# Align model-load deadline with cold-start stage cap and fix timeout error mapping (#222)

## Why

Issue #222 reports a first-cold inference failure under the Request deadline.
Reproduction on `tamingsari` with a 7B MLX model showed that the **controller** abandons
`EnsureModelLoaded` after the cold-start stage cap (`max_cold_start_ms`, 15 s by default),
while the **Node Agent** keeps loading until the absolute Request deadline (~120 s).
The first request therefore fails, but the model becomes resident and the next request
succeeds warm. The user-visible failure is also misreported as HTTP 500
`internal_error` instead of a clean load-timeout error.

This is two confirmed defects, not an undersized timeout:

1. **Deadline misalignment.** `EnsureModelLoadedRequest.deadline_unix_ms` carries the
   absolute Request deadline, not the stage cap.
2. **Error normalization defect.** grpc-elixir 0.11.5 returns deadline expiry as
   integer status `4`, but the controller only matches atom `:deadline_exceeded`,
   so the timeout falls through to the internal catch-all.

## What changes

- Rewrite `EnsureModelLoadedRequest.deadline_unix_ms` at dispatch to the effective
  load-operation deadline:
  `min(request.timeout_at, now + schedule.model_load_timeout_ms)`.
- Derive the controller transport timeout from the same value for gRPC and BEAM.
- Stop stamping the absolute Request deadline into the load request at the orchestrator.
- Normalize integer and atom gRPC deadline statuses to `:node_timeout`.
- Treat `{:rpc_error, integer, msg}` and bare `:timeout` as timeout failures in
  `ModelLoadFailure`.
- Ensure `load_timeout` is retained by `inference_attempt_failure.ex` model-load
  code normalization.
- Bound the local-BEAM `safe_apply` branch so it honors the explicit `timeout:` and
  returns `:beam_node_timeout` on expiry.
- Harden the Node Agent so a load completion that arrives after all valid waiters
  have expired does not leave the worker marked `PLACEMENT_STATE_LOADED`.

## Out of scope

- Raising the static `max_cold_start_ms` default (15 s).
- Adding an `ORCHARD_MAX_COLD_START_MS` environment variable.
- Host-calibrated cold-tier eligibility (follow-up OpenSpec capability).
- Introducing an execution-reserve setting or changing the absolute Request deadline
  contract.

## SPEC.md impact

This change clarifies and enforces the existing contract in:

- §7.5.3 `deadline_unix_ms` semantics for `EnsureModelLoadedRequest`;
- cold-tier eligibility and the `max_cold_start_ms` stage cap;
- dispatch/model-load failure normalization;
- the Request-deadline stage-deadline wording.

No absolute Request deadline behavior is relaxed.

## Rollout

Deploy controllers before node agents. Old Node Agents already honor a shorter
`deadline_unix_ms`; old controllers would continue to send the absolute Request
deadline.

## Delivery state

Issue #222 owns this fix.
