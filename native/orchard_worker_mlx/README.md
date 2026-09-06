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

Residual: MLX-LM's `sharded_load` falls back to `{"trust_remote_code": True}` for the tokenizer whenever `tokenizer_config` is omitted or empty, so its model-side `trust_remote_code=False` does not cover the tokenizer by itself.
Orchard does not reach that path today; issue #116 sharded loading must pass an explicit `{"trust_remote_code": False}` tokenizer config rather than relying on the upstream default.

## Tool calling qualification

The worker buffers each complete model-native tool block, delegates interpretation to the pinned MLX-LM parser, and emits only validated function names and JSON argument objects.
Raw model wrappers never become public arguments.
Cancellation, incomplete framing, invalid parser results, and unrequested names cannot publish the affected block.

Qualify each exact model/runtime/client combination before declaring tool support:

1. Record the immutable model revision, manifest identity, effective context and concurrency, MLX-LM Git revision, parser identity, client version, and API path.
2. Verify the bundle declares tool capability and the loaded tokenizer exposes a supported parser.
3. Run the pinned-parser regression tests and the real-template continuation test documented in `../orchard_tokenizer/README.md`.
4. Through Chat Completions, require the client to call a local tool against a synthetic fixture, validate its arguments, return the result with the matching call ID, and reproduce an unpredictable fixture value in the final answer.
5. Exercise cancellation and recovery, malformed/truncated calls, and sequential tool turns; distinguish protocol failures from model choices.

`mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` at revision `6e302ea604ad9ab206367e2c501d1571023e7b6d` is a qualification candidate with a `qwen3_coder` parser.
The initial profile uses a 16K context and one concurrent request.
It is not a qualified OpenCode profile until the real client round trip passes.
Chat Completions qualification does not establish Responses API compatibility.

## Proto contract

The provider-neutral Worker Runtime proto lives at:

```
proto/orchard/worker/v1/worker_runtime.proto
```

This defines the internal node-agent ↔ worker gRPC contract (`WorkerRuntimeService`).
It is owned outside this provider implementation and imports shared cluster types from `proto/cluster/v1/`.

### Generated bindings

| Surface | Location | Generation |
|---------|----------|------------|
| Python messages | `src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2.py` | `mise exec -- mix proto.gen.worker` |
| Python gRPC stubs | `src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2_grpc.py` | `mise exec -- mix proto.gen.worker` |
| Elixir modules | `apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex` | `mise exec -- mix proto.gen.worker` |
| Descriptor golden | `proto/orchard/worker/v1/worker_runtime.descriptor.pb` | `mise exec -- mix proto.gen.worker` |

### Regenerate bindings

From the repo root:

```bash
mise exec -- mix proto.gen.worker
```

This runs the `grpcio-tools` version pinned by `proto/orchard/worker/tooling/uv.lock` and `protoc-gen-elixir` 0.16.0 with the correct include paths.
It generates both language surfaces from the one neutral schema.
The provider package carries only the protobuf and gRPC runtime dependencies needed to consume its generated bindings.

The Elixir generator output is mechanically mapped to the existing `Orchard.Node.Worker.V1.*` namespace and existing `Orchard.Cluster.V1.*` imported types.
No message, field, RPC, package, or service definition is maintained by that mapping.

### Drift validation

From the repo root:

```bash
mise exec -- mix proto.check.worker
scripts/test-worker-runtime-binding-drift.sh
```

The first command regenerates every committed Python and Elixir binding plus the descriptor golden into a temporary root and byte-compares the results.
The second command introduces drift only in a temporary fixture and proves the checker rejects it.

### Workflow rules

1. Edit the `.proto` source first.
2. Run `mise exec -- mix proto.gen.worker` to regenerate every binding and the descriptor golden.
3. Run `mise exec -- mix proto.check.worker` and the reciprocal compatibility tests.
4. Commit the canonical schema and every generated output together.
