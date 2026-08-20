# Design: align model-load deadline with cold-start stage cap

## Context

The controller has always computed a per-attempt model-load stage cap:

```elixir
model_load_timeout =
  min(
    context.model_load_timeout_cap_ms,           # e.g. max_cold_start_ms
    remaining_request_timeout_ms(context.deadline_ms)
  )
```

<ref_snippet file="/Users/najib/Hacks/orchard/.worktrees/issue-222-first-cold/apps/orchard_controller/lib/orchard/dispatch/request_dispatcher.ex" lines="798-803" />

This cap is passed as the RPC `timeout:` to the Runtime Endpoint client
(<ref_snippet file="/Users/najib/Hacks/orchard/.worktrees/issue-222-first-cold/apps/orchard_controller/lib/orchard/dispatch/request_dispatcher.ex" lines="1294-1297" />),
but the `EnsureModelLoadedRequest` itself carries the absolute Request deadline:

```elixir
deadline_unix_ms: deadline_ms   # ~120 s
```

<ref_snippet file="/Users/najib/Hacks/orchard/.worktrees/issue-222-first-cold/apps/orchard_controller/lib/orchard/inference/request_orchestrator.ex" lines="1748-1756" />

The Node Agent derives its waiter expiry, load budget, and worker timeout from that
field (<ref_snippet file="/Users/najib/Hacks/orchard/.worktrees/issue-222-first-cold/apps/orchard_node_agent/lib/orchard/node/model_manager.ex" lines="788-791" />),
so it continues loading long after the controller has abandoned the request.

## Decision: rewrite `deadline_unix_ms` at dispatch

The dispatcher owns the effective load deadline because it already computes the
stage cap and must account for queue time and remaining Request time. The
orchestrator will stop stamping the absolute Request deadline into the load request.

```elixir
effective_load_deadline_unix_ms =
  min(schedule.timeout_at, System.system_time(:millisecond) + model_load_timeout_ms)
```

This value is written into `EnsureModelLoadedRequest.deadline_unix_ms` right before
`do_ensure_model_loaded/5`. The transport timeout (monotonic) is derived from the same
computation.

We do **not** add a new `load_timeout_ms` proto field. `deadline_unix_ms` originally
carried exactly this meaning; restoring it keeps the contract transport-independent
and avoids dual-field precedence rules during rolling upgrades.

## Decision: canonical timeout identity

A model-load stage timeout becomes:

- HTTP/SSE code: `load_timeout`
- Attempt outcome: `failed`, failure class `model_load_failure`, code `load_timeout`
- Persisted request: `state=failed`, `http_status=504`, `error_code="load_timeout"`

If the load could not start because the absolute Request deadline was already
exhausted, the outcome is `request_timeout` / `state=timed_out` instead.

## Decision: gRPC and BEAM error normalization

- `grpc_node_runtime_client.ex`: accept both atom `:deadline_exceeded` and integer
  status `4` as `:node_timeout`; do the same for `unavailable`/`cancelled`/`resource_exhausted`.
- `model_load_failure.ex`: handle `{:rpc_error, integer_status, msg}` and bare
  `:timeout` as timeout-category failures, not internal errors.
- `inference_attempt_failure.ex`: keep `load_timeout` in the model-load code allowlist.
- `beam_client.ex`: local-node `safe_apply` must respect `timeout:` and return
  `:beam_node_timeout`; remote `:rpc.call` already does.

## Decision: Node Agent late-completion race

If the load task finishes after all waiters have expired, the result must not mark
`PLACEMENT_STATE_LOADED`. The artifact may remain cached, but the runtime placement
must only become resident when a valid waiter or explicit preload owns it.

## Test plan

- Dispatch tests: effective load deadline equals the stage cap and is ≤ Request deadline.
- Model-load failure tests: integer gRPC status 4 maps to `timeout` category.
- Chat completion controller tests: streaming and non-streaming 504 / `load_timeout`.
- BEAM client tests: local-node timeout enforcement.
- Node Agent tests: late completion after waiter expiry does not mark loaded.
- End-to-end cold-load timeout test (gRPC and BEAM): cap < actual load < Request
  deadline; verify `load_timeout`, no execution, no residual warm placement.

## Files likely to change

- `apps/orchard_controller/lib/orchard/dispatch/request_dispatcher.ex`
- `apps/orchard_controller/lib/orchard/dispatch/grpc_node_runtime_client.ex`
- `apps/orchard_controller/lib/orchard/inference/model_load_failure.ex`
- `apps/orchard_controller/lib/orchard/inference/inference_attempt_failure.ex`
- `apps/orchard_controller/lib/orchard/inference/request_orchestrator.ex`
- `apps/orchard_controller/lib/orchard/runtime_endpoint/beam_client.ex`
- `apps/orchard_node_agent/lib/orchard/node/model_manager.ex`
- Corresponding test files.
