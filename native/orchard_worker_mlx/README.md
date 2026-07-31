# orchard_worker_mlx

Orchard's MLX worker runtime package — a gRPC service that owns model loading,
inference generation, and health probing for Apple Silicon (MLX) backends.

## Entrypoints

- project script (run from `native/orchard_worker_mlx/`): `mise exec -- uv run orchard-worker-mlx`
- dev-only repo wrapper from the repo root: `mise exec -- native/orchard_worker_mlx/bin/orchard-worker-mlx`

See `../../docs/tooling.md` for the required mise and uv workflow.

## Responsibility boundary

The worker owns local model loading, generation, prefix-cache/runtime telemetry,
and MLX backend integration. The node agent supervises the worker process and is
the network-reachable boundary for controller dispatch. Public clients never call
this service directly.

See `../../docs/architecture.md` for the broader runtime map.

## Backend modes

The standalone CLI supports `--backend stub` and `--backend mlx`. The CLI
defaults to `stub` for hermetic local checks; the node-agent source and packaged
runtime defaults `ORCHARD_WORKER_BACKEND` to `mlx`. Install MLX extras before
using the real backend:

```bash
mise exec -- uv sync --locked --directory native/orchard_worker_mlx --extra mlx
```

The CLI also supports `--generation-mode stream|batch`. The stub backend uses
`stream` when no generation mode is provided and rejects `batch`; the node-agent
source and packaged runtime configs mirror that by resolving
`ORCHARD_WORKER_BACKEND=stub` to stream mode when
`ORCHARD_WORKER_GENERATION_MODE` is unset.
In node-agent runtime, batch mode can admit concurrent same-model requests up to the worker-reported effective request limit.
That limit is configured with `ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL` or, when set to `auto`, `ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL`.
The worker `GetStatus` path reports overlapping `Generate` calls and effective worker capacity through `WorkerStatusResponse.active_request_count` and `WorkerStatusResponse.max_concurrency`.
The node-agent publishes aggregate capacity through cluster `StatusResponse.active_request_count` and `StatusResponse.max_concurrency`, plus loaded-placement capacity through `StatusResponse.runtime_model_placements`.
Aggregate capacity is the conservative limit the node agent enforces across loaded workers, while each loaded placement keeps its own reported capacity.

## MLX-LM security baseline

The `mlx` extra pins MLX-LM commit `ab1806e8f5d6aa035973af194a1b9198ab4754dc`.
The reviewed source range contains 15 commits and 35 changed files after the `v0.31.3` tag.
The dependency still reports version `0.31.3`, so the full Git revision and committed uv lock are the runtime provenance authority.
Transformers remains constrained to `>=5.7,<5.13` until its broader compatibility matrix is accepted separately.

Orchard rejects model configurations containing `model_file` before upstream loading.
The production loader also passes `trust_remote_code=False` for model loading and `tokenizer_config_extra={"trust_remote_code": False}` for tokenizer loading.
Resolved-environment tests verify the same explicit settings on MLX-LM's sharded loading surface.
These controls reduce dynamic-code exposure but do not make model execution a security sandbox.

## Proto contract

The worker runtime proto lives at:

```
native/orchard_worker_mlx/proto/orchard/worker/v1/worker_runtime.proto
```

This defines the internal node-agent ↔ worker gRPC contract (`WorkerRuntimeService`).
It imports shared cluster types from `proto/cluster/v1/`.

### Generated bindings

| Surface | Location | Generation |
|---------|----------|------------|
| Python messages | `src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2.py` | `mise exec -- mix proto.gen.worker` |
| Python gRPC stubs | `src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2_grpc.py` | `mise exec -- mix proto.gen.worker` |
| Elixir modules | `apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex` | Manual (see below) |

### Regenerate Python bindings

From the repo root:

```bash
mise exec -- mix proto.gen.worker
```

This runs `grpc_tools.protoc` under `uv` with the correct include paths.

### Elixir binding

The Elixir binding at `worker_runtime.pb.ex` uses the namespace `Orchard.Node.Worker.V1.*`,
which does not match what `protoc-gen-elixir` auto-generates from the proto package
`orchard.worker.v1` (which produces `Orchard.Orchard.Worker.V1.*` with the `Orchard`
package prefix). **Update it by hand** when the proto changes.

### Workflow rules

1. Edit the `.proto` source first.
2. Run `mise exec -- mix proto.gen.worker` to regenerate Python bindings.
3. Manually update the Elixir binding to match.
4. Commit proto source and all generated outputs together.

### Drift risk

The manual Elixir binding can drift from the proto source. To mitigate:
- Always update `worker_runtime.pb.ex` in the same commit as proto changes.
- Review the proto field list against the Elixir struct in code review.
- Long-term: consider renaming the proto package or adding a CI check that
  diffs proto field names against the Elixir module definition.
