# cluster/v1 proto workflow

This directory contains the checked-in proto sources used to generate Orchard's
controller ↔ node-agent RPC bindings. `SPEC.md` remains the normative contract;
if proto files, docs, tests, or implementation disagree with it, treat the
branch as blocked until reconciled.

## Scope and current status

This directory owns the controller ↔ node-agent cluster RPC contract. It does
not own the node-agent ↔ worker runtime contract; that lives under
`../../orchard/worker/v1/`.

`common.proto`, `events.proto`, `peer_grant.proto`, `runtime.proto`, and
`worker_recovery.proto` are active generated inputs.
`membership.proto` is present for the future cluster-join lifecycle slice but is
excluded from the current generation aliases until that contract is implemented.

`fixtures/` holds shared cross-language event fixtures described below.

## Cross-language event fixtures

`fixtures/generated_tool_argument_events.json` records the serialized
`InferenceEvent` stream a worker produces for generated tool-argument boundaries:
ordered multi-call success, an unrequested function name, non-object arguments,
and malformed or truncated blocks. Each scenario holds `events_base64`, the
deterministic serialized bytes of each event, and `arguments`, the exact argument
strings the worker publishes.

The MLX worker test
`test_spec_7_5_2_worker_events_match_shared_generated_argument_fixture` in
`native/orchard_worker_mlx/tests/test_generation.py` produces the recorded bytes:
it runs the same scenarios through `build_inference_event` and byte-compares the
result with this file. Elixir tests decode those bytes through
`Orchard.TestSupport.GeneratedToolArgumentFixture` in `apps/orchard_shared`, so
node-agent and controller tests assert against worker-produced events instead of
a second hand-written expectation.

That test reads `tool_call_start`, `tool_call_end`, and `parse_tool_call` from
the pinned MLX-LM `json_tools` parser, so it skips when the locked `mlx` extra is
absent. Run it with the extra installed before you trust the recorded bytes:

```bash
mise exec -- uv run --locked --directory native/orchard_worker_mlx --extra mlx \
  pytest tests/test_generation.py -k generated_argument_fixture
```

Do not hand-edit one side of that contract. When `events.proto`, the worker's
event encoding, or the pinned parser changes deliberately, re-record
`events_base64` from the producing test and commit the fixture with the change
that caused it.

## Elixir toolchain

Orchard standardizes on:

- [`protobuf`](https://hex.pm/packages/protobuf) for generated message modules
- [`grpc`](https://hex.pm/packages/grpc) for generated service and stub modules
- `protoc` as the checked-in `.proto` compiler input

### Prerequisites

Install the local compiler and Elixir plugin:

```bash
brew install protobuf
mise exec -- mix escript.install hex protobuf 0.16.0
```

`mise exec -- mix proto.gen` validates that the installed Elixir generator
version matches Orchard’s pinned `protoc-gen-elixir` version.

`orchard_shared` relies on `grpc`'s compatible protobuf runtime dependency at build/runtime; the pinned escript above is specifically for deterministic Elixir code generation.

### Elixir output location

Generated Elixir modules live in:

```text
apps/orchard_shared/lib/cluster/v1/
```

`orchard_shared` is the single owner of generated Elixir transport modules so the controller and node agent compile against one shared contract implementation.

### Generate Elixir modules

Use the repo-approved alias from the repository root:

```bash
mise exec -- mix proto.gen
```

The alias wraps this underlying `protoc` invocation:

```bash
protoc \
  -I proto \
  --plugin=protoc-gen-elixir="$HOME/.mix/escripts/protoc-gen-elixir" \
  --elixir_out=plugins=grpc,package_prefix=Orchard:apps/orchard_shared/lib \
  proto/cluster/v1/common.proto \
  proto/cluster/v1/events.proto \
  proto/cluster/v1/peer_grant.proto \
  proto/cluster/v1/runtime.proto \
  proto/cluster/v1/worker_recovery.proto
```

Notes:

- `package_prefix=Orchard` keeps generated modules under the Orchard namespace (`Orchard.Cluster.V1.*`).
- `membership.proto` is intentionally excluded until its contract is defined.
- Re-run `mise exec -- mix proto.gen` whenever the checked-in proto files change.

## Python worker codegen

The worker package consumes generated Python bindings for both this cluster RPC
surface and its own worker runtime RPC surface.

Generated Python modules live under:

```text
native/orchard_worker_mlx/src/orchard_worker_mlx/generated/
```

Run the repo-approved alias from the repository root:

```bash
mise exec -- mix proto.gen.worker
```

The alias runs `grpc_tools.protoc` through the provider-neutral locked uv environment under `proto/orchard/worker/tooling/`,
with `proto/` as the sole source include path.
It generates:

- `cluster/v1/*_pb2.py` and `cluster/v1/*_pb2_grpc.py` from the cluster protos the
  worker consumes: `common.proto`, `events.proto`, and `runtime.proto`;
- `orchard/worker/v1/*_pb2.py` and `orchard/worker/v1/*_pb2_grpc.py` from the
  worker runtime proto.

`membership.proto` remains deferred and is not part of the current Python
cluster generation set.

## Workflow rules

- Edit `.proto` files in this directory first.
- Regenerate Elixir/Python outputs from the updated proto source.
- Commit generated Elixir modules alongside the proto changes that require them.
- Keep Orchard-specific naming in generated Elixir modules via the `Orchard` package prefix.
