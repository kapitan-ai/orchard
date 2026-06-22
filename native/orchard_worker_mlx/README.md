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
mise exec -- uv sync --directory native/orchard_worker_mlx --extra mlx
```

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
