# cluster/v1 proto workflow

This directory is the source of truth for the internal Orchard controller ↔ node-agent RPC contract described in `SPEC.md`.

## Milestone scope

- **S1** wires the gRPC/protobuf toolchain and documents generation.
- **S2** fills the real M1 runtime contract.
- `membership.proto` remains deferred until the cluster-join lifecycle work in later milestones.

The seed definitions in `common.proto`, `events.proto`, and `runtime.proto` are intentionally minimal. They exist so Orchard can standardize the code generation workflow and compile against shared generated modules before the full M1 runtime surface lands.

## Elixir toolchain

Orchard standardizes on:

- [`protobuf`](https://hex.pm/packages/protobuf) for generated message modules
- [`grpc`](https://hex.pm/packages/grpc) for generated service and stub modules
- `protoc` as the checked-in `.proto` compiler input

### Prerequisites

Install the local compiler and Elixir plugin:

```bash
brew install protobuf
mix escript.install hex protobuf 0.16.0
```

`mix proto.gen` validates that the installed Elixir generator version matches Orchard’s pinned `protoc-gen-elixir` version.

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
mix proto.gen
```

The alias wraps this underlying `protoc` invocation:

```bash
protoc \
  -I proto \
  --plugin=protoc-gen-elixir="$HOME/.mix/escripts/protoc-gen-elixir" \
  --elixir_out=plugins=grpc,package_prefix=Orchard:apps/orchard_shared/lib \
  proto/cluster/v1/common.proto \
  proto/cluster/v1/events.proto \
  proto/cluster/v1/runtime.proto
```

Notes:

- `package_prefix=Orchard` keeps generated modules under the Orchard namespace (`Orchard.Cluster.V1.*`).
- `membership.proto` is intentionally excluded until its contract is defined.
- Re-run `mix proto.gen` whenever the checked-in proto files change.

## Python toolchain

Python code generation is documented now so the later native packages can adopt the same checked-in proto source of truth. This section is **forward-looking in S1**: the repository does not yet contain the package skeletons needed to run these commands successfully.

### When this becomes actionable

Start using this workflow once the native package scaffolds exist in S6 (or earlier if a package is added specifically for shared RPC generation).

### Intended Python output locations

The future native package layout should generate checked-in Python modules under package-owned source trees, for example:

```text
native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/
```

### Future package prerequisites

Inside the owning Python package, use `uv`-managed tooling only and add the codegen dependency there:

```bash
uv add --dev grpcio-tools
```

### Future Python generation command

Once the package skeleton exists, run the generation step from the repository root or from the package environment that owns the output path:

```bash
uv run python -m grpc_tools.protoc \
  -I proto \
  --python_out=native/orchard_worker_mlx/src/orchard_worker_mlx/generated \
  --grpc_python_out=native/orchard_worker_mlx/src/orchard_worker_mlx/generated \
  proto/cluster/v1/common.proto \
  proto/cluster/v1/events.proto \
  proto/cluster/v1/runtime.proto
```

Notes:

- The exact package destination becomes active once the native packages are created.
- `membership.proto` remains deferred and is not part of the Python generation set yet.
- Until the package skeleton exists, treat this as a documented target workflow rather than a runnable S1 command.

## Workflow rules

- Edit `.proto` files in this directory first.
- Regenerate Elixir/Python outputs from the updated proto source.
- Commit generated Elixir modules alongside the proto changes that require them.
- Keep Orchard-specific naming in generated Elixir modules via the `Orchard` package prefix.
