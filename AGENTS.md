# AGENTS.md — Orchard v2

Orchard is a sovereign on-prem LLM orchestration platform for Apple Silicon macOS. Elixir/OTP + Postgres.

## Build Contract

**SPEC.md** is the top-level normative Orchard build contract. Every
implementation decision must trace to `SPEC.md`, tests, product docs, a
decision record, or an explicitly approved issue/PR decision.

If `SPEC.md`, docs, future OpenSpec materials, tests, or implementation disagree
about product behavior, treat the PR as blocked until the branch reconciles the
conflict. `SPEC.md` wins until explicitly updated.

## Single-Repo Source Of Truth

This repository is the active source of truth for Orchard product code, docs,
plans, decisions, tests, and agent workflow. The deprecated/frozen
`orchard-workbench` may be useful historical context, but active Orchard work
must not require it. If old planning material becomes durable product guidance,
rewrite it as standalone Orchard documentation before committing it here.
Transient RP exports may live in ignored local paths such as `/prompt-exports/`,
but must not be committed.

Local tools may accelerate work, but they do not own product truth. Do not
commit raw prompt exports, local execution evidence, active goal packages,
interview JSON, annotation state, tool session identifiers, credentials, DSNs,
or machine-specific paths.

Durable conclusions belong in this repo: `SPEC.md`, `docs/**`,
`docs/decisions/**`, tests, code, or future verified OpenSpec materials.

## Planning And Local Goals

Use the lightest process that protects the Orchard contract.

Small changes may go directly through issue/PR review:

- typo and documentation clarifications
- small internal refactors with no behavior change
- straightforward bug fixes with regression tests
- tactical UI changes that follow `docs/DESIGN.md`

For behavior-changing or architecture-significant work, state the `SPEC.md`
impact before implementation. If a durable decision is needed and is not already
fixed by `SPEC.md`, add or update a decision record under `docs/decisions/**`.

`goals/<slug>/` packages are transient local execution scaffolding. They are not
durable product truth unless their conclusions are promoted into standalone
repo docs, decisions, tests, or code.

Keep only these on `main`:

- `goals/README.md`
- `goals/_template/**`

Do not commit active `goals/<slug>/` packages, raw interview JSON, review JSON,
metadata JSON, local evidence logs, local paths, or tool session identifiers.
If goal material becomes durable, promote the conclusion into `SPEC.md`,
product docs, decisions, tests, or code.

## Architecture (from SPEC.md)

- **Language**: Elixir/OTP (umbrella app)
- **Database**: Postgres (sole persistence + coordination layer)
- **APIs**: `/v1/responses` (canonical abstraction), `/v1/chat/completions` (compatibility facade)
- **Internal comms**: gRPC over mTLS
- **Packaging**: native macOS DMG/PKG + launchd
- **Clustering**: Postgres advisory locks + gRPC heartbeats (HA-lite)
- **Inference**: MLX-LM runtime adapter managed by the node agent (Apple Silicon native)

## Milestones

| Milestone | Scope |
|-----------|-------|
| M0 | Skeleton and packaging foundation |
| M1 | Single-node inference MVP (`GET /v1/models`, `POST /v1/chat/completions`, SSE, MLX worker) |
| M2 | Responses API and governance core |
| M3 | Node lifecycle and cluster join |
| M4 | Multi-node scheduler and placements |
| M5 | Observability and diagnostics |
| M6 | Security hardening and air-gap |
| M7 | Upgrade safety and HA-lite controller |

## Conventions

- Follow Elixir community conventions
- Prefer small, spec-traceable changes over broad speculative refactors
- Tests should trace back to milestone and spec behavior where possible
- Commits: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- Config: `config/` for compile-time, `config/runtime.exs` for runtime
- Toolchain: use the pinned `mise.toml` contract; see `docs/tooling.md`

## Tooling Guidance

Required product toolchain setup lives in `docs/tooling.md`. Keep `AGENTS.md`
focused on contribution workflow and link out for pinned runtime versions,
`mise exec --` command forms, Python/uv policy, Node policy, and local agent
accelerator guidance.

Agent accelerators such as RepoPrompt, codemap, ast-grep, Refero, Superpowers,
and Exa may help with discovery, review, design, and research. Discover their
available roles/workflows live before assuming a stale tool surface. They do not
own product truth and must not become required human collaborator dependencies.

## LiveView Console Conventions

### Console UI Design Guidance

For Orchard Console UI/UX changes, read `docs/DESIGN.md` before editing LiveView templates, `OrchardConsole.CoreComponents`, Console CSS, or Console tests.

Authority order:
1. `SPEC.md` and this `AGENTS.md` govern product behavior, architecture, repo boundaries, and validation workflow.
2. `docs/brand-identity.md` governs palette, typography, logo, and brand semantics.
3. `docs/DESIGN.md` governs tactical UI execution: surfaces, input wells, sidebar/control rail, focus/error states, density, motion, accessibility semantics, and browser verification.

When changing Console UI, keep `docs/DESIGN.md` and the implementation in sync. Do not reference historical external plans, RP sessions, Oracle reviews, prompt exports, or local planning artifacts from product docs/code.

### Console Implementation Conventions

- **Forms**: Use `to_form(map, as: atom)` with plain maps, NOT `Ecto.Changeset`. Phoenix HTML 4.x `FormData` protocol does not implement for `Ecto.Changeset` in this project. For error rendering after a failed `Repo.insert`, convert the changeset manually:
  ```elixir
  defp changeset_to_form(%Ecto.Changeset{} = cs, as, defaults) do
    params = Map.merge(defaults, cs.params || %{})
    errors = Enum.map(cs.errors, fn {field, {msg, opts}} -> {field, {msg, opts}} end)
    to_form(params, as: as, errors: errors)
  end
  ```
- **Deferred mount**: Call DB/gRPC only inside `if connected?(socket)`. Disconnected render shows loading state via `state_message`.
- **Sensitive values**: Never put secrets in `data-*` attributes, flash, session, or URL params. Keep them in socket assigns only. JS hooks should read secrets from visible DOM elements via ID reference, not data attributes.
- **Multi-tenant scoping**: Always scope child-resource DB operations (revoke, update, delete) to the parent tenant from server-side assigns. Never trust `phx-value-*` IDs alone.

## Agent Contribution Workflow

When contributing code, agents MUST run the applicable quality workflow from the umbrella root and report what passed, failed, or is not yet wired for the current milestone.

### Elixir workflow

Run these in order for Elixir/OTP changes from the umbrella root:

1. `mise exec -- mix format`
2. `mise exec -- mix compile --warnings-as-errors`
3. `mise exec -- mix credo --strict`
4. `mise exec -- mix dialyzer`
5. `mise exec -- mix test`
6. `mise exec -- mix test --cover`

Rules:

- Treat compiler warnings, Credo findings, and Dialyzer issues as blockers unless the user explicitly accepts an exception.
- Add `@spec` definitions for public functions and types for shared/core domain modules.
- Every bug fix MUST include a regression test.
- Every spec-defined behavior change SHOULD include or update tests that cite the relevant `SPEC.md` section in test names, comments, or surrounding notes.
- For state machines, APIs, scheduling, quotas, auth, and persistence flows, cover both happy-path and failure-path behavior.

### Code quality plugins (ex_slop + ex_dna)

Two Credo plugins enforce code quality standards specific to AI-assisted development. Both run as part of `mise exec -- mix credo --strict`.

- **ex_slop** — detects AI-generated code patterns (blanket rescues, narrator docs, obvious comments, identity passthroughs, step comments, etc.). Orchard uses an explicit 20-check policy in `.credo.exs` rather than the upstream recommended bundle, so dependency upgrades cannot silently shift the quality gate.
- **ex_dna** — AST-level code duplication detection. Finds exact, renamed-variable, and near-miss structural clones. Configured at `min_mass: 80`.

Rules:

- New code MUST pass both plugins with zero findings before handoff.
- **Fix first, suppress last.** Prefer fixing the code (remove obvious comments, extract duplicated logic, document public functions) over suppression.
- When suppressing a false positive, use the narrowest scope and include a rationale:
  ```elixir
  # credo:disable-for-lines:3 ExSlop.Check.Readability.ObviousComment
  # Server ignored Range header — file is now corrupt.
  # Delete partial and restart from scratch.
  ```
- Do NOT suppress findings to avoid refactoring. If ex_dna flags genuine duplication, extract a shared module.
- When adding new modules, run `mise exec -- mix credo --strict` before committing — the plugins catch patterns that are invisible during normal development.

See `docs/code-quality.md` for detailed tuning rationale, suppression patterns, and guidance on evolving the check configuration.

### Python/native workflow

For code under `native/`, use the mise-pinned Python plus `uv`-managed package
environments only. Prefer **Ruff** for formatting/linting and **ty** for static
typing. Run these in order for each changed native package:

1. `mise exec -- uv run --directory native/<package> ruff format`
2. `mise exec -- uv run --directory native/<package> ruff check`
3. `mise exec -- uv run --directory native/<package> pytest`
4. `mise exec -- uv run --directory native/<package> pytest --cov`

Rules:

- Never use `python`, `python3`, `pip`, or `pip3` directly.
- Do not use unpinned `uvx` tools as required quality gates. When `ty` is added
  as a native package dev dependency, run it as
  `mise exec -- uv run --directory native/<package> ty check`.
- Keep tooling configuration in each package’s `pyproject.toml` where supported, plus any minimal tool-specific config files when required.
- Do not introduce an alternate Python toolchain without updating `mise.toml`,
  `docs/tooling.md`, this guide, and the relevant project config.
- Native helper changes SHOULD include tests for both protocol correctness and failure handling.

### Coverage expectations

- Run coverage for the changed surface before handoff.
- New modules and materially changed branches SHOULD ship with direct test coverage.
- Avoid handing off untested request-state, node-state, placement-state, auth, quota, or streaming behavior.
- If coverage tooling is not yet installed for a milestone, say so explicitly and include the setup work in the plan rather than silently skipping coverage.

### Execution discipline

- During iteration, run the smallest relevant test slice first, then rerun the broader affected suite before handoff.
- If dependencies or tool configuration change, rerun formatting, linting, typing, tests, and coverage afterward.
- In the final handoff, list the exact validation commands run and their outcomes.

## Dev Environment

**Start with:** `mise exec -- bin/dev`

This single command creates the dev database if needed, runs migrations, sets
the dev gRPC port to 50071 (avoiding conflict with the packaged BEAM on 50061),
and starts `iex -S mix phx.server`.

For source-dev cluster roles, use `mise exec -- bin/dev-controller` for the
Phoenix/controller host and `mise exec -- bin/dev-node-agent` for a
node-agent-only worker host. The current validated two-Mac smoke pattern is:
start `mise exec -- bin/dev-node-agent` on the worker host with
`ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0`, then start
`mise exec -- bin/dev-controller` on the controller host with
`ORCHARD_RUNTIME_CLIENT_TARGETS=<worker-ip>:50071`.

When to bypass `bin/dev`:
- `mise exec -- iex -S mix` — BEAM without HTTP server (one-off scripts, migrations)
- `mise exec -- iex -S mix phx.server` — manual server start with custom env vars
- `mise exec -- mix test` — test suite (uses its own DB and port 50071 via `test.exs`)

See `docs/local-dev.md` for full environment setup and configuration.

## Packaging (PKG)

**Build installer with:** `mise exec -- ./scripts/build-pkg.sh`

This script automates the complete PKG build process:
- Python venv setup (tokenizer + MLX worker)
- Elixir releases (controller, node-agent, CLI)
- Asset compilation and dependency resolution
- Staging with correct permissions
- PKG creation with naming convention: `Orchard-<version>-<date>-<sha>.pkg`

**Build options:**
```bash
mise exec -- ./scripts/build-pkg.sh                    # Standard build
mise exec -- ./scripts/build-pkg.sh --clean            # Deep clean (slow, reproducible)
mise exec -- ./scripts/build-pkg.sh --allow-dirty      # Build with uncommitted changes
mise exec -- ./scripts/build-pkg.sh /custom/output     # Custom output directory
```

**When to build:**
- Cutting a release for distribution
- Testing packaging changes
- Validating the full installer workflow

**When NOT to build:**
- During normal development (use `mise exec -- bin/dev`)
- Quick CLI testing (use `mise exec -- mix compile` + `mise exec -- iex -S mix`)

The PKG is role-aware through a universal payload. Seed
`/Library/Application Support/Orchard/support/.install-role.request` with
`all`, `controller`, or `node-agent` before `installer` to control which
LaunchDaemons are installed and managed. The persisted marker is
`/Library/Application Support/Orchard/support/.install-role`. Managed Postgres
is not installed or managed by default; controller hosts require external
Postgres configuration.

See `packaging/pkg/README.md` for full PKG operator documentation and `packaging/pkg/README.md#building-the-pkg` for detailed build instructions.

## Key Files

| File | Purpose |
|------|---------|
| SPEC.md | Normative build contract |
| AGENTS.md | This file — agent operating guide |
| README.md | High-level product and roadmap overview |
| CONTRIBUTING.md | Human collaborator workflow |
| CONTEXT-MAP.md | Domain-modeling discovery map for glossary context |
| mise.toml | Pinned local toolchain contract |
| docs/glossary/CONTEXT.md | Shared Orchard product glossary |
| docs/tooling.md | mise, validation command, and local tool guidance |
| docs/local-dev.md | Source development setup and smoke-test guidance |
| docs/process.md | Artifact lifecycle and process guidance |
| docs/decisions/ | ADR-style durable decisions |
| goals/README.md | Local goal package policy |
| openspec/README.md | Reserved structured-change workflow |
| mix.exs | Umbrella project root |
| docs/code-quality.md | ex_slop + ex_dna plugin reference and tuning guide |
