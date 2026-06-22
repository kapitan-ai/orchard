# Orchard Tooling

Orchard uses `mise` as the required local toolchain manager for source
development, validation, and package builds.

`mise.toml` is the product repo contract for language runtimes and developer
tools that affect build output, warnings, generated code, Python environments,
and packaging behavior. Do not rely on global Homebrew, system, uv-managed, or
shell-specific runtime versions when working in this repo.

## Required Toolchain

Run these commands from the repo root:

```bash
brew install mise
mise trust
mise install
```

The pinned toolchain currently covers:

| Tool | Pin | Purpose |
|------|-----|---------|
| Erlang/OTP | `29.0.2` | BEAM runtime, compiler, Dialyzer PLTs, releases |
| Elixir | `1.20.0-otp-29` | Mix, umbrella compilation, tests, releases |
| Python | `3.11.15` | Native tokenizer and MLX worker packages |
| uv | `0.11.23` | Python package sync, virtualenvs, native tests |
| Node.js | `24.17.0` | Repository-local OpenSpec CLI runtime |
| npm | `11.13.0` | Package manager bundled with pinned Node.js |
| OpenSpec | `@fission-ai/openspec@1.4.1` | OpenSpec change/spec validation |

The mise environment also sets:

| Variable | Value | Purpose |
|----------|-------|---------|
| `UV_PYTHON` | `3.11` | Direct `uv` to the repo Python line |
| `UV_NO_MANAGED_PYTHON` | `1` | Prevent silent uv Python downloads |

`uv` remains the package and virtualenv manager for `native/**`. `mise` owns
the Python interpreter version that `uv` is allowed to use.

## Standard Commands

Either activate mise in your shell or prefix commands with `mise exec --`.
Documentation and automation should prefer the explicit form when reproducible
tool resolution matters.

```bash
mise exec -- mix deps.get
mise exec -- uv sync --directory native/orchard_tokenizer
mise exec -- uv sync --directory native/orchard_worker_mlx
mise exec -- bin/dev
```

Elixir validation:

```bash
mise exec -- mix format
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix dialyzer
mise exec -- mix test
mise exec -- mix test --cover
```

Native validation:

```bash
mise exec -- uv run --directory native/orchard_tokenizer ruff format
mise exec -- uv run --directory native/orchard_tokenizer ruff check
mise exec -- uv run --directory native/orchard_tokenizer pytest
mise exec -- uv run --directory native/orchard_tokenizer pytest --cov

mise exec -- uv run --directory native/orchard_worker_mlx ruff format
mise exec -- uv run --directory native/orchard_worker_mlx ruff check
mise exec -- uv run --directory native/orchard_worker_mlx pytest
mise exec -- uv run --directory native/orchard_worker_mlx pytest --cov
```

Static typing for native packages should be run through package-pinned dev
dependencies once configured. Do not make a floating `uvx ty` invocation a
required gate; add `ty` to the relevant `pyproject.toml` first, then run it as
`mise exec -- uv run --directory native/<package> ty check`.

MLX extras remain opt-in because they pull the real inference stack:

```bash
mise exec -- uv sync --directory native/orchard_worker_mlx --extra mlx
```

Package builds should run through the same toolchain:

```bash
mise exec -- ./scripts/build-pkg.sh
```

## Generated Contracts

Cluster and worker proto bindings are generated through Mix aliases from the
repo root:

```bash
mise exec -- mix proto.gen
mise exec -- mix proto.gen.worker
```

- `mix proto.gen` additionally requires a host `protoc` binary and Orchard's
  pinned `protoc-gen-elixir` escript. Install the escript through the pinned
  Mix toolchain with `mise exec -- mix escript.install hex protobuf 0.16.0`.
- `mix proto.gen` generates Elixir controller ↔ node-agent cluster modules from
  `proto/cluster/v1/{common,events,runtime}.proto` into
  `apps/orchard_shared/lib/cluster/v1/`.
- `mix proto.gen.worker` generates Python bindings for the shared cluster protos
  and `native/orchard_worker_mlx/proto/orchard/worker/v1/worker_runtime.proto`
  into `native/orchard_worker_mlx/src/orchard_worker_mlx/generated/`.
- The node-agent Elixir worker binding is maintained manually; see
  `native/orchard_worker_mlx/README.md`.

## Node Policy

Orchard has a minimal first-party npm workflow for repository-local OpenSpec
validation. The only root npm dependency is the pinned OpenSpec CLI in
`package.json` / `package-lock.json`.

Phoenix asset builds still use the Mix-managed `esbuild` and `tailwind`
packages. Do not add general app JavaScript dependencies, asset builds, or an
alternate Node workflow without updating `mise.toml`, `package.json`,
`package-lock.json`, and this document.

Install the pinned Node package tools from the repo root:

```bash
mise exec -- npm ci --ignore-scripts
```

Run OpenSpec through the pinned npm script:

```bash
mise exec -- npm run openspec -- validate --all --strict --no-interactive
```

## Tools Outside mise

Some dependencies are host services or Apple platform tools and are not managed
by mise:

- PostgreSQL local or external service
- Protobuf compiler (`protoc`) and the pinned `protoc-gen-elixir` escript for
  Elixir proto generation
- Xcode Command Line Tools and macOS packaging tools such as `pkgbuild`,
  `pkgutil`, `codesign`, `xcrun`, and `notarytool`
- model bundles and local MLX smoke-test data
- operator signing identities, keychains, and notarization credentials

Document these in the relevant runbook or packaging guide rather than adding
them to `mise.toml`.

OpenSpec is initialized for collaborator-reviewable change packages and pinned
through the root npm workflow. For OpenSpec-backed branches, run the validation
commands in [`../openspec/README.md`](../openspec/README.md).

## Agent Accelerator Tools

Local agent tools may accelerate work, but they are not product build
dependencies and their raw outputs are not product truth. Orchard is the
canonical active repository; frozen or private coordination workspaces are
historical context only unless their conclusions are rewritten here as
standalone docs, decisions, tests, or code.

Common agent accelerators include:

| Tool | Use | Product boundary |
|------|-----|------------------|
| RepoPrompt | Context building, review, second opinions, durable investigations | Discover roles/workflows live; do not commit RP sessions, prompt exports, chat IDs, or routing notes |
| codemap | Cheap source and diff orientation | Treat output as orientation, not contract truth |
| ast-grep | Structural search and refactors | Keep edits traceable to product files and tests |
| Refero | UI and visual design research | Do not copy private research artifacts into product docs |
| Superpowers | Planning, debugging, verification discipline | Do not commit generated local plans unless rewritten as product docs |
| Exa | Web research when current external facts are needed | Cite external sources in product-facing docs when relevant |

Agents should follow `AGENTS.md` for when to use these tools. If an accelerator
is unavailable, fall back to repo files, tests, and standard git commands
without making the accelerator a collaborator requirement.

For substantial agentic work, use RepoPrompt as a review and iteration layer
when available: bind it to the relevant Orchard workspace roots, gather context,
ask for plan/review second opinions, address the findings, and repeat until the
remaining risks are explicit. Keep RP session IDs, prompt exports, routing
notes, generated reports, and local evidence out of committed Orchard source
unless they are rewritten as standalone product-facing artifacts.

## Version Changes

Toolchain bumps must be intentional. For any change to `mise.toml`:

1. Update this document in the same branch.
2. Explain the reason in the PR.
3. Run the affected validation gates under `mise exec --`.
4. For Erlang/OTP or Elixir bumps, run the full Elixir workflow.
5. For Python or uv bumps, run both native package workflows.
6. For future Node bumps, run the first-party Node workflow that required the
   pin.

If a toolchain bump changes product behavior or packaging behavior, state the
`SPEC.md` impact and update the relevant docs, tests, or decision record.
