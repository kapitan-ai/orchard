# Orchard Tooling

Orchard uses `mise` as the required local toolchain manager for source
development, validation, and package builds.

`mise.toml` is the product repo contract for language runtimes and developer
tools that affect build output, warnings, generated code, Python environments,
and packaging behavior. Do not rely on global Homebrew, system, uv-managed, or
shell-specific runtime versions when working in this repo.

## Platform scope

The documented complete development and validation workflow currently runs on the supported Apple Silicon macOS platform profile.
The accepted Linux Controller profile is a Milestone 8 target and does not yet have a supported bootstrap, packaging, or deployment path; required CI does run a Linux portable Orchard control-plane core validation lane, which is validation coverage rather than Linux Controller profile support.
Portable tools such as mise, Erlang, Elixir, Node.js, npm, and Postgres remain part of that target.
Ordinary portable Orchard control-plane core compilation no longer invokes `xcrun` or builds Orchard's own Darwin helpers; Apple's C toolchain is a build prerequisite for explicit macOS host-artifact builds and validation.
Dependency compilation on the current macOS profile still requires a working host C compiler for third-party NIFs such as `argon2_elixir`.
Swift, DMG assembly, Developer ID signing, notarization, stapling, launchd, and Keychain steps apply to the macOS native distribution profile, and MLX steps apply to the macOS MLX Node runtime profile.

Required validation runs broad portable Orchard control-plane core compilation, static analysis, tests, coverage, tokenizer validation, and provider-neutral conformance on Linux.
Separate macOS lanes prove host lifecycle, Orchard.app/DMG behavior, and MLX runtime behavior.
`scripts/ci/classify-required-validation-paths.sh` selects which lanes a pull request runs from its changed paths, unknown paths select every lane, and `scripts/ci/evaluate-required-validation.sh` backs the single required `Required Orchard validation gate` check by demanding success from every selected lane and `skipped` from every unselected one.
Credential-free signing-contract validation may run in normal CI, while Developer ID signing, notarization, stapling, and publication remain credentialed release-only operations.

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
| Node.js | `24.17.0` | Repository-local OpenSpec and Phoenix asset CLI runtime |
| npm | `11.13.0` | Package manager for root tool and asset pins |
| OpenSpec | `@fission-ai/openspec@1.9.0` | OpenSpec change/spec validation |
| esbuild | `0.25.0` | Phoenix JavaScript asset bundling CLI |
| Tailwind CSS | `4.3.3` | Phoenix CSS asset build CLI |

The mise environment also sets:

| Variable | Value | Purpose |
|----------|-------|---------|
| `UV_PYTHON` | `3.11` | Direct `uv` to the repo Python line |
| `UV_NO_MANAGED_PYTHON` | `1` | Prevent silent uv Python downloads |

`uv` remains the package and virtualenv manager for `native/**`. `mise` owns
the Python interpreter version that `uv` is allowed to use.

For macOS host-artifact validation, Apple's C toolchain is required outside mise, the same way the Swift and signing tools are.
Ordinary `mix compile` does not build Orchard's Darwin helpers, but compiling third-party NIF dependencies such as `argon2_elixir` still needs a working host C compiler.
Run `make macos-native-helpers` when source development needs the retained terminal-custody or launchd lifecycle helpers in the development CLI application.
On Darwin hosts the `make test`, `make cover`, and `make check-elixir` workflows stage test helpers automatically; on Linux they skip staging because the helpers are Darwin-only, and the Linux portable lane excludes the retained `macos` tag instead.
Run `make macos-native-test-helpers` first only when invoking `mix test` directly for retained macOS paths.
The explicit builder owns sources under `packaging/macos/native_helpers` and stages binaries into the selected `orchard_cli` application `priv` directory.
Payload assembly invokes the same builder before producing the packaged CLI release.
Install the Xcode Command Line Tools with `xcode-select --install` if `xcrun clang --version` fails.

## Standard Commands

Either activate mise in your shell or prefix commands with `mise exec --`.
Documentation and automation should prefer the explicit form when reproducible
tool resolution matters.

```bash
ERL_AFLAGS="-ssl protocol_version \"['tlsv1.2']\"" mise exec -- mix local.hex --if-missing --force
ERL_AFLAGS="-ssl protocol_version \"['tlsv1.2']\"" mise exec -- mix local.rebar --if-missing --force
ERL_AFLAGS="-ssl protocol_version \"['tlsv1.2']\"" mise exec -- mix deps.get
mise exec -- uv sync --locked --directory native/orchard_tokenizer
mise exec -- uv sync --locked --directory native/orchard_worker_mlx
mise exec -- npm ci --ignore-scripts
mise exec -- bin/dev
```

The root `Makefile` provides thin aliases over these pinned commands for common
workflows:

```bash
make setup
make dev
make dev-controller
make dev-node-agent
make openspec
make validate-product-version
make check-elixir
```

Use the documented `mise exec --` commands as the authority when a Makefile
target and this guide disagree.

`make validate-product-version` is a read-only normal source validation command.
It validates the exact root `VERSION` grammar and requires the umbrella plus every discovered first-party OTP application to report the same Product Version.
Passing this command does not establish or require a release transition, tag, candidate, artifact, credential, or publication state.

Elixir validation:

```bash
mise exec -- mix format
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix dialyzer
make test
make cover
```

The last two steps use the Make wrappers because they stage the retained macOS
test helpers before Mix runs. Substitute `mise exec -- mix test` and
`mise exec -- mix test --cover` only after `make macos-native-test-helpers`.

Portable-boundary and macOS native-helper proofs:

```bash
scripts/test-portable-core-compilation.sh
scripts/test-build-macos-native-helpers.sh
```

The first forces a first-party umbrella recompile behind an `xcrun` tripwire and rejects any newly emitted or changed Orchard Darwin helper artifact.
The second exercises the explicit helper builder and proves a production-only build excludes the test-only terminal helper.
Run both when changing umbrella compile configuration, the retained helper sources, or the helper builder.

Required CI lane proofs:

```bash
scripts/test-linux-portable-core.sh
scripts/test-provider-neutral-conformance.sh
scripts/ci/test-classify-required-validation-paths.sh
scripts/ci/test-required-validation-gate.sh
```

`scripts/test-linux-portable-core.sh` runs the Linux portable lane's tests, coverage, tokenizer checks, and non-accelerator Worker Runtime checks; it excludes the `integration`, `macos`, `mlx_smoke`, and `mlx_benchmark` tags and refuses to run on Darwin.
`scripts/test-provider-neutral-conformance.sh` runs the focused Worker Runtime, Runtime Endpoint, capability, lifecycle-invariant, and scheduler contract tests against the prepared test database.
The two `scripts/ci/test-*` proofs are the trigger matrix and fail-closed aggregate tests; run them on any host when changing the classifier, the evaluator, or `.github/workflows/required-validation.yml`.

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

Swift and macOS app validation use the host Xcode Command Line Tools because Apple platform signing and packaging tools are outside mise:

```bash
xcrun swift-format format --in-place --recursive packaging/app/Sources packaging/app/Tests
xcrun swift-format lint --recursive packaging/app/Sources packaging/app/Tests
swift build --package-path packaging/app
swift test --package-path packaging/app
swift test --package-path packaging/app --enable-code-coverage
scripts/test-app-service-lifecycle.sh
scripts/test-build-app.sh
scripts/test-app-signing.sh
scripts/test-build-dmg.sh
```

The last command uses the deterministic local Amore substitute by default.
Set `ORCHARD_TEST_REAL_AMORE=1` only for the credential-free local Amore DMG assembly smoke.
Developer ID signing, notarization, stapling, draft publication, and system-root lifecycle changes require their separately documented credentials or interactive authorization.

Static typing for native packages should be run through package-pinned dev
dependencies once configured. Do not make a floating `uvx ty` invocation a
required gate; add `ty` to the relevant `pyproject.toml` first, then run it as
`mise exec -- uv run --directory native/<package> ty check`.

MLX extras remain opt-in because they pull the real inference stack:

```bash
mise exec -- uv sync --locked --directory native/orchard_worker_mlx --extra mlx
```

The default `pytest` run above skips `tests/test_mlx_import_smoke.py` because the `mlx` extra is absent.
When refreshing the `transformers`/`mlx-lm` pins, exercise the import and remote-code security guards with the exact locked extra installed:

```bash
mise exec -- uv run --locked --directory native/orchard_worker_mlx --extra mlx \
  pytest tests/test_mlx_import_smoke.py
```

The resolved-environment guard verifies the exact MLX-LM source revision, loader signatures, tokenizer registration, and explicit model and tokenizer distrust on the sharded loading surface without downloading a model.
See the "MLX-LM security baseline" section of `native/orchard_worker_mlx/README.md` for the pinned revision, the remote-code controls, and the residual the guard asserts against.

Shared distribution-neutral payload builds should run through the same toolchain:

```bash
mise exec -- ./scripts/build-payload.sh
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
  `proto/cluster/v1/{common,events,peer_grant,runtime}.proto` into
  `apps/orchard_shared/lib/cluster/v1/`.
- `mix proto.gen.worker` generates Python bindings for the shared cluster protos
  and `native/orchard_worker_mlx/proto/orchard/worker/v1/worker_runtime.proto`
  into `native/orchard_worker_mlx/src/orchard_worker_mlx/generated/`.
- The node-agent Elixir worker binding is maintained manually; see
  `native/orchard_worker_mlx/README.md`.

## Node Policy

Orchard has a minimal first-party npm workflow for repository-local OpenSpec
validation and the Phoenix asset CLI binaries used by source dev. The root npm
dependencies are the pinned OpenSpec CLI plus pinned `esbuild`, `tailwindcss`,
and `@tailwindcss/cli` versions in `package.json` / `package-lock.json`.

The root `.npmrc` sets `save-exact=true`; keep Node tool dependencies exact and
commit the resulting `package-lock.json` changes.

Phoenix asset builds still run through the Mix `esbuild` and `tailwind`
wrappers, but those wrappers point at the npm-managed binaries under
`node_modules/.bin` to avoid first-run binary downloads from inside
`mix phx.server`. Do not add general app JavaScript dependencies, broader asset
builds, or an alternate Node workflow without updating `mise.toml`,
`package.json`, `package-lock.json`, and this document.

Install the pinned Node package tools from the repo root:

```bash
mise exec -- npm ci --ignore-scripts
```

Run OpenSpec through the pinned npm script:

```bash
OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive
```

## Tools Outside mise

Some dependencies are host services or Apple platform tools and are not managed
by mise:

- PostgreSQL local or external service
- Protobuf compiler (`protoc`) and the pinned `protoc-gen-elixir` escript for
  Elixir proto generation
- Xcode Command Line Tools and macOS distribution tools such as `codesign`,
  `xcrun`, `hdiutil`, and `notarytool`

Native PKG tools and scripts are not part of the current supported toolchain or
release gates.
Any future native package requires a fresh accepted OpenSpec proposal and a
separate implementing pull request before its tools become required.
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
| RepoMix | Linux/headless context packs, RepoPrompt fallback, scoped second-model review inputs | Keep generated packs in ignored local paths such as `/tmp`; cite original repo files and lines, not generated pack lines |
| codemap | Cheap source and diff orientation | Treat output as orientation, not contract truth |
| ast-grep | Structural search and refactors | Keep edits traceable to product files and tests |
| Refero | UI and visual design research | Do not copy private research artifacts into product docs |
| Superpowers | Planning, debugging, verification discipline | Do not commit generated local plans unless rewritten as product docs |
| No Mistakes | Significant workstream validation, smoke checks, and push or PR gate driving | Configure the tool-owned `~/.no-mistakes/config.yaml`; do not commit gate repos, logs, evidence, prompt exports, or machine-specific paths |
| Exa | Web research when current external facts are needed | Cite external sources in product-facing docs when relevant |

No Mistakes is configured outside the repo in `~/.no-mistakes/config.yaml`.
For significant Orchard No Mistakes gates, prefer the Claude native agent with the Opus model as the independent reviewer, because `agent_args_override` is a global-only No Mistakes setting.
Use `no-mistakes doctor`, `no-mistakes axi`, and `no-mistakes axi run --help` as cheap smoke checks before starting an expensive gate run.

Agents should follow `AGENTS.md` for when to use these tools.
Claude Code reads that same guide through root `CLAUDE.md`.
If an accelerator is unavailable, fall back to repo files, tests, and standard git commands
without making the accelerator a collaborator requirement.

For substantial agentic work, use RepoPrompt as a review and iteration layer
when available: bind it to the relevant Orchard workspace roots, gather context,
ask for plan/review second opinions, address the findings, and repeat until the
remaining risks are explicit. Keep RP session IDs, prompt exports, routing
notes, generated reports, and local evidence out of committed Orchard source
unless they are rewritten as standalone product-facing artifacts.

Use RepoMix as a lightweight optional fallback when RepoPrompt is unavailable, unsuitable for the current task, or not available in a Linux/headless workflow.
RepoMix is useful for building scoped context packs for Codex threads, second-model review prompts, architecture scans, and PR review preparation.
It is an accelerator only, not a pinned Orchard toolchain dependency; generated packs are snapshots and are not product truth.
Do not commit RepoMix outputs, local prompt packs, generated gap reviews, or transient model responses.
Promote durable conclusions into `SPEC.md`, `docs/**`, `docs/decisions/**`, tests, code, or accepted OpenSpec materials.

Prefer precise file lists over broad repository dumps:

```bash
rg --files \
  -g 'SPEC.md' \
  -g 'AGENTS.md' \
  -g 'docs/local-dev.md' \
  -g 'openspec/changes/<change-id>/**' \
  -g 'apps/orchard_controller/lib/orchard/<area>/**' \
  -g 'apps/orchard_controller/test/orchard/<area>/**' |
repomix --stdin \
  --output /tmp/orchard-repomix-TOPIC.xml \
  --style xml \
  --output-show-line-numbers \
  --token-count-tree 1000 \
  --top-files-len 20 \
  --token-budget 180000
```

For broad orientation, run RepoMix with `--no-files` first, inspect the token tree, then generate a narrower pack.
Use `--compress` for architecture discovery and module-shape questions, but prefer full packs for correctness review, security review, or bug diagnosis where implementation details matter.
For PR review, consider `--include-diffs` and `--include-logs --include-logs-count 10` after checking that the resulting pack remains scoped and non-sensitive.
Keep RepoMix security checks enabled unless a specific local diagnostic requires otherwise.

Agents should report the local RepoMix version when relying on a pack:

```bash
repomix --version
npm view repomix version
```

`--token-budget` may exit non-zero when a pack is too large while still writing the output file.
Treat that as a failed guardrail, narrow the pack, and regenerate before using it as review context.
`--split-output` can fail when a large top-level entry exceeds the requested split size, so do not rely on it as the primary way to make oversized packs manageable.
When citing evidence from RepoMix-assisted work, cite the original Orchard file paths and line numbers rather than the generated pack.

## Version Changes

Toolchain bumps must be intentional. For any change to `mise.toml`:

1. Update this document in the same branch.
2. Explain the reason in the PR.
3. Run the affected validation gates under `mise exec --`.
4. For Erlang/OTP or Elixir bumps, run the full Elixir workflow.
5. For Python or uv bumps, run both native package workflows.
6. For Node, npm, or OpenSpec bumps, run the first-party Node workflow that
   required the pin.

If a toolchain bump changes product behavior or packaging behavior, state the
`SPEC.md` impact and update the relevant docs, tests, or decision record.
