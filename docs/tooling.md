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
Separate macOS lanes prove host lifecycle, packaging contracts, Orchard.app and DMG assembly, and MLX runtime behavior.
Native Orchard.app and DMG distribution is paused under `SPEC.md` §11.0, so `scripts/ci/resolve-app-distribution-lane.sh` reads the committed `packaging/distribution-control` and reports `app_distribution=false`; CI then skips the assembly lane, and the gate expects that skip.
`scripts/ci/classify-required-validation-paths.sh` selects which lanes a pull request runs from its changed paths, unknown paths select every lane, and `scripts/ci/evaluate-required-validation.sh` backs the single required `Required Orchard validation gate` check by demanding success from every selected lane and `skipped` from every unselected one.
Credential-free signing-contract validation may run in normal CI, while Developer ID signing, notarization, stapling, and publication remain credentialed release-only operations.

## Required Toolchain

Run these commands from the repo root:

```bash
brew install mise
mise trust
mise install
```

Required CI bootstraps mise `2026.9.2` through explicit `version` inputs in `.github/workflows/required-validation.yml`.
This bootstrap pin is separate from the runtime and developer-tool pins in `mise.toml`.
Update every mise-action invocation together only after the matching platform release assets and signed checksums are published.

The approved immutable action SHA and required bootstrap sites live in
[`../.github/mise-action-pin.json`](../.github/mise-action-pin.json). Update that
record only as part of a reviewed pin change with upstream provenance; workflow
invocations are consumers, never the authority for their own consistency check.
`mise exec -- npm run check:mise-action-pins` parses workflow YAML and checks all
actual mise-action steps in workflow files, including dormant jobs, against that record. It also
requires one invocation in each retained bootstrap job. The OpenSpec validation
lane runs this check and `mise exec -- npm run test:mise-action-pins` after the
existing root npm install. Its failure fails the existing required aggregate.
The check uses the direct pinned `yaml` dependency already present at the same
version in the root lockfile; comments and shell strings are not invocations.
It does not scan local composite actions; none currently exist. Moving a required
bootstrap into one fails the retained-site check and needs a reviewed update.

The pinned toolchain currently covers:

| Tool | Pin | Purpose |
|------|-----|---------|
| Erlang/OTP | `29.1.1` | BEAM runtime, compiler, Dialyzer PLTs, releases |
| Elixir | `1.20.0-otp-29` | Mix, umbrella compilation, tests, releases |
| Python | `3.11.15` | Native tokenizer and MLX worker packages |
| uv | `0.11.23` | Python package sync, virtualenvs, native tests |
| Node.js | `24.17.0` | Repository-local OpenSpec and Phoenix asset CLI runtime |
| npm | `11.13.0` | Package manager for root tool and asset pins |
| OpenSpec | `@fission-ai/openspec@1.13.1` | OpenSpec change/spec validation |
| esbuild | `0.28.2` | Phoenix JavaScript asset bundling CLI |
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
Run `make macos-native-helpers` when source development needs the retained terminal-custody or launchd lifecycle helpers, or the Transport publication helper, in the development CLI application.
On Linux, `make linux-native-helpers` builds the Transport publication helper with the host C compiler (`cc`, or `CC`) for source development.
`orchardctl transport enable-local-https` refuses before TLS generation when `orchard-transport-publish` is absent from the CLI application `priv` directory; no Mix step builds it implicitly.
On Darwin hosts the `make test`, `make cover`, and `make check-elixir` workflows stage the macOS test helpers automatically and run every test; on Linux hosts they stage the Linux Transport publication helpers and exclude the retained `macos` tag.
Run `make macos-native-test-helpers` (Darwin) or `make linux-native-test-helpers` (Linux) first when invoking `mix test` directly.
Node Agent host-inventory probe tests tagged `gnu_timeout` run real processes under a GNU coreutils `timeout` guardian, so GNU coreutils is a required host test prerequisite on every host.
The Node Agent test helper checks fixed absolute paths in order and uses the first one whose `--version` identifies GNU coreutils `timeout`; it never searches `PATH` and installs nothing.
Linux coreutils provides `/usr/bin/timeout`, which is checked first.
On macOS, `brew install coreutils` installs g-prefixed tools such as `gtimeout` and a `libexec/gnubin` directory with unprefixed names, and may also link an unprefixed `timeout` into the Homebrew `bin` directory when that does not conflict.
The helper checks each of these under both `/opt/homebrew` and `/usr/local`: `bin/timeout`, `bin/gtimeout`, and `opt/coreutils/libexec/gnubin/timeout`.
Those tests always run; without a verified GNU guardian they fail with install guidance rather than being skipped.
The explicit macOS builder owns sources under `packaging/macos/native_helpers` plus the shared `packaging/native_helpers/orchard_transport_publish.c`, and stages binaries into the selected `orchard_cli` application `priv` directory.
`scripts/build-linux-native-helpers.sh` is the Linux counterpart for the shared Transport helper only.
Both builders stage the fault-injecting `orchard-transport-publish-test` only with `--include-test-helper`, and a production-only build removes it; payload assembly never ships it.
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

The last two steps use the Make wrappers because they stage the host's test helpers before Mix runs and exclude macOS-only tests on non-Darwin hosts.
Substitute `mise exec -- mix test` and `mise exec -- mix test --cover` only after `make macos-native-test-helpers` (Darwin) or `make linux-native-test-helpers` (Linux).

Portable-boundary and macOS native-helper proofs:

```bash
scripts/test-portable-core-compilation.sh
scripts/test-build-macos-native-helpers.sh
```

The first forces a first-party umbrella recompile behind an `xcrun` tripwire and rejects any newly emitted or changed Orchard native helper artifact, including `orchard-transport-publish*`.
The second exercises the explicit helper builder and proves a production-only build excludes the test-only terminal and Transport publication helpers.
It also runs the lifecycle process-snapshot syscall regressions with LLVM coverage, including inaccessible unrelated processes and fail-closed BEAM identity checks.
Run both when changing umbrella compile configuration, the retained helper sources, or the helper builder.

Transport publication second-UID proof (SPEC.md §10.7, ADR 0036):

```bash
scripts/test-transport-publication-second-uid.sh
```

It builds the helpers into a disposable tree, pauses the test helper inside the private stage under child umasks `0022`, `0077`, `0002`, and `0000`, and proves the `nobody` account cannot read, list, or write the stage but can read the published `ca.crt` and `endpoint.json`.
It also exercises real ACL refusal, foreign-owned ancestry refusal, root-owned custody, and, on Linux, the production helper's tmpfs refusal.
On Linux, the focused Transport tests and the production-helper checks need `TMPDIR` (or `/tmp`) on ext4; the test-only helper's tmpfs acceptance does not qualify tmpfs hosts.
It requires passwordless `sudo -n` and an existing `nobody` account, changes no sudoers, users, mounts, or grants, and fails rather than skipping when either is missing.
Before it, the Linux portable and macOS host CI lanes run the focused Transport, TLS, and publication tests with `--include integration`, so Transport-invoked TLS generation runs real OpenSSL inside the private stage; those tests pass `--no-trust` or stop before any trust-store change.
On Linux it also needs `setfacl` from the `acl` package.
Fixtures live under the canonical temporary directory (`/private/tmp` on Darwin), never under the home directory or checkout, because the helper refuses ACL-bearing or symlinked ancestry.

Required CI lane proofs:

```bash
scripts/test-linux-portable-core.sh
scripts/test-provider-neutral-conformance.sh
scripts/ci/test-classify-required-validation-paths.sh
scripts/ci/test-required-validation-gate.sh
scripts/ci/test-linux-portable-validation-report.sh
mise exec -- npm run check:mise-action-pins
mise exec -- npm run test:mise-action-pins
```

`scripts/test-linux-portable-core.sh` runs the Linux portable lane's tests, coverage, tokenizer checks, and non-accelerator Worker Runtime checks; it excludes the `integration`, `macos`, `mlx_smoke`, and `mlx_benchmark` tags and refuses to run on Darwin.
It builds no native helpers, so run `make linux-native-test-helpers` first; the CI lane stages them in a separate step.
`scripts/test-provider-neutral-conformance.sh` runs the focused Worker Runtime, Runtime Endpoint, capability, lifecycle-invariant, and scheduler contract tests against the prepared test database.
The first two `scripts/ci/test-*` proofs are the trigger matrix and fail-closed aggregate tests; run them on any host when changing the classifier, the evaluator, or `.github/workflows/required-validation.yml`.

The Linux portable lane also uploads a bounded validation report, which is diagnostic only.
Validation is unchanged: the lane runs the same commands with the same arguments, order, exclusions, and fail-fast behavior, and the required gate still reads job results.
When `ORCHARD_LINUX_PORTABLE_REPORT_DIR` is set, `scripts/test-linux-portable-core.sh` streams each command's output to stdout, parses a private temporary copy, and deletes that copy.
If the capture `tee` stops early, the rest of the output is still drained to stdout, so the command never sees a broken pipe; only bytes the failed `tee` had already read may be missing from the log, and that step's capture is recorded as failed.
When a command exits on its own, the script's exit status is that command's status, and a reporting failure only prints a warning.
When the run is interrupted by SIGINT or SIGTERM in this mode, the script finishes the current command and then exits with 130 or 143, whatever that command returned, and the report records the interruption as `unknown`.
The report file holds only allowlisted `key=value` facts: source, head, and base SHAs, event and run attempt, public runner image, the configured toolchain from `mise current`, the versions reported by Erlang/OTP, Elixir, and uv, and the version of each package's existing `.venv` Python found through `uv python find` (probes never install tools, run Python directly, or create environments; an absent or incompatible environment, or a fallback interpreter outside the package `.venv`, is `unknown`), the numeric PostgreSQL `server_version_num` from a read-only `SHOW`, committed lockfile SHA-256 before and after setup, the existing Dialyzer PLT cache hit or miss with a SHA-256 of its unchanged key, and each command's label, exit status, and elapsed time.
For test commands it also records the ExUnit seed and result totals that were already printed, pytest totals, coverage totals, and up to 20 failure identities per command, given as module and file location or pytest node ID with parameters removed.
It never holds raw output, assertion payloads, passing-test names, environment values, credentials, or absolute paths.
A changed lockfile is reported but does not fail the lane.
Facts accumulate in an unpublished staging file.
The finalize step accepts only the fixed staging vocabulary, then validates, bounds, and redacts the facts and publishes `report.txt` with a single rename.
The upload runs only when that step succeeded and confirmed `report.txt` is a regular file, so a failed or interrupted finalize uploads nothing.
`report.result` is `success` only when all ten commands are recorded in order with valid facts and status 0, every suite summary was recognized, every metadata fact is known, and the job had not failed or been cancelled.
It is `failure` only when a command recorded a known nonzero exit status and the run was neither interrupted nor cancelled; `tests.result` and `tests.first_failed_step` still record that command outcome.
An interrupted run, unrecognized output, a malformed or missing fact, or an unexpected key gives `unknown`, and a hard cancellation can leave no artifact at all; treat a missing artifact as unknown too.
`scripts/ci/test-linux-portable-validation-report.sh` drives the lane script with disposable `uname` and `mise` stubs and proves the exact command order, the stop at each failing command, the host guard, a failing capture `tee`, interrupt handling, report completeness, the upload receipt, report bounds, and redaction on any host.
Run it in the foreground, because its interrupt cases need a trappable SIGINT, and set `ORCHARD_TEST_BASH=/bin/bash` to repeat it under macOS bash 3.2.

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
scripts/test-distribution-control.sh
```

The last command proves the distribution pause guards with fixture trees and fake tools, and never assembles an app or DMG.
While `packaging/distribution-control` is paused, do not run `scripts/test-build-app.sh`, `scripts/test-app-signing.sh`, or `scripts/test-build-dmg.sh`; they assemble an app bundle and a disk image, and the guarded entrypoints refuse with exit status `78`.
After an approved resume, run them after the commands above.
`scripts/test-build-dmg.sh` uses the deterministic local Amore substitute by default.
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

The default `pytest` run above skips every test that imports the real MLX stack because the `mlx` extra is absent.
That covers `tests/test_mlx_import_smoke.py`, the pinned-parser checks in `tests/test_mlx_tool_calling.py`, and the shared tool-argument fixture check in `tests/test_generation.py` that `proto/cluster/v1/README.md` describes.
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
  `proto/cluster/v1/{common,events,peer_grant,reasoning,runtime}.proto` into
  `apps/orchard_shared/lib/cluster/v1/`.
- `proto/orchard/worker/v1/worker_runtime.proto` is the sole authoritative Worker Runtime schema.
- `mix proto.gen.worker` generates committed Python messages and gRPC stubs under `native/orchard_worker_mlx/src/orchard_worker_mlx/generated/`, the committed Elixir messages, service, and stub at `apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex`, the shared Elixir cluster modules under `apps/orchard_shared/lib/cluster/v1/` (byte-identical to `mix proto.gen`), the descriptor-set golden beside the canonical schema, and the Elixir preparation wire fixture encoded from `scripts/support/worker-runtime-preparation-fixture.exs`.
- Worker generation uses the provider-neutral Python tool environment and lock under `proto/orchard/worker/tooling/` and requires `protoc-gen-elixir` 0.16.0.
  Install the Elixir generator through the pinned Mix toolchain with `mise exec -- mix escript.install hex protobuf 0.16.0`.
- `mix proto.check.worker` regenerates every committed output into a temporary root, including the shared Elixir cluster modules that encode the preparation fixture, and fails when any output is missing or byte-different.
  `scripts/test-worker-runtime-binding-drift.sh` proves that deliberate drift is rejected without modifying the checkout.
- Descriptor and reciprocal Python/Elixir semantic fixtures live under `proto/orchard/worker/v1/` and are exercised by provider-neutral validation.
  `fixtures/n_minus_1/worker_runtime.descriptor.pb` is a pinned, hand-maintained N-1 golden: the descriptor set from pre-reasoning baseline `126eb1bcbf89e1ef9bab913407196128b5b71ca4`. It is not a generator output; replace it only when the supported N-1 revision changes.

## Node Policy

Orchard has a minimal first-party npm workflow for repository-local OpenSpec
validation and the Phoenix asset CLI binaries used by source dev. The root npm
dependencies are the pinned OpenSpec CLI plus pinned `esbuild`, `tailwindcss`,
`@tailwindcss/cli`, and the `yaml` parser for the CI action-pin check in
`package.json` / `package-lock.json`.

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
- GNU coreutils `timeout` for the Node Agent host-inventory probe tests
  (Linux coreutils `/usr/bin/timeout`; on macOS `brew install coreutils`,
  found as `timeout`, `gtimeout`, or the coreutils `gnubin` `timeout`)
- POSIX ACL tools `/usr/bin/getfacl` and `/usr/bin/setfacl` on Linux for CLI
  output-path ACL inspection and its tests (Ubuntu `acl` package)
- A host C compiler for the explicit native-helper builders, including the
  Linux Transport publication helper (`cc`, or `CC`; Ubuntu `build-essential`)
- Protobuf compiler (`protoc`) and the pinned `protoc-gen-elixir` escript for
  Elixir proto generation
- Xcode Command Line Tools and macOS distribution tools such as `codesign`,
  `xcrun`, `hdiutil`, and `notarytool`

Native PKG tools and scripts are not part of the current supported toolchain or
release gates.
Any future native package requires a fresh accepted OpenSpec proposal and a
separate implementing pull request before its tools become required.
- model bundles and local MLX smoke-test data. `scripts/prepare-mlx-smoke-bundle.sh`
  writes the pinned Qwen3 bundle under `~/.cache/orchard/mlx-smoke-bundles/` and
  is not a mise, CI, or `make test` gate. Prove the helper without a HuggingFace
  download via `scripts/test-prepare-mlx-smoke-bundle.sh`.
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
