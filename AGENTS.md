# AGENTS.md — Orchard v2

Orchard is a sovereign on-prem LLM orchestration platform for Apple Silicon macOS. Elixir/OTP + Postgres.

## Build Contract

**SPEC.md** is the normative build contract. Every implementation decision must trace to a section in the spec. If the spec doesn't cover something, ask before improvising.

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

## LiveView Console Conventions

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

Run these in order for Elixir/OTP changes:

1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix dialyzer`
5. `mix test`
6. `mix test --cover`

Rules:

- Treat compiler warnings, Credo findings, and Dialyzer issues as blockers unless the user explicitly accepts an exception.
- Add `@spec` definitions for public functions and types for shared/core domain modules.
- Every bug fix MUST include a regression test.
- Every spec-defined behavior change SHOULD include or update tests that cite the relevant `SPEC.md` section in test names, comments, or surrounding notes.
- For state machines, APIs, scheduling, quotas, auth, and persistence flows, cover both happy-path and failure-path behavior.

### Code quality plugins (ex_slop + ex_dna)

Two Credo plugins enforce code quality standards specific to AI-assisted development. Both run as part of `mix credo --strict`.

- **ex_slop** — detects AI-generated code patterns (blanket rescues, narrator docs, obvious comments, identity passthroughs, step comments, etc.). 20 checks enabled; 3 skipped (2 Ecto-specific, 1 GenServer).
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
- When adding new modules, run `mix credo --strict` before committing — the plugins catch patterns that are invisible during normal development.

See `docs/code-quality.md` for detailed tuning rationale, suppression patterns, and guidance on evolving the check configuration.

### Python/native workflow

For code under `native/`, use `uv`-managed tooling only. Prefer **Ruff** for formatting/linting and **ty** for static typing. Run these in order once the package is configured:

1. `uv run ruff format`
2. `uv run ruff check`
3. `uvx ty check`
4. `uv run pytest`
5. `uv run pytest --cov`

Rules:

- Never use `python`, `python3`, `pip`, or `pip3` directly.
- Keep tooling configuration in each package’s `pyproject.toml` where supported, plus any minimal tool-specific config files when required.
- Do not introduce an alternate Python toolchain without updating this guide and the relevant project config.
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

**Start with:** `bin/dev`

This single command creates the dev database if needed, runs migrations, sets
the dev gRPC port to 50071 (avoiding conflict with the packaged BEAM on 50061),
and starts `iex -S mix phx.server`.

When to bypass `bin/dev`:
- `iex -S mix` — BEAM without HTTP server (one-off scripts, migrations)
- `iex -S mix phx.server` — manual server start with custom env vars
- `mix test` — test suite (uses its own DB and port 50071 via `test.exs`)

See `docs/m1-local-dev.md` for full environment setup and configuration.

## Packaging (PKG)

**Build installer with:** `./scripts/build-pkg.sh`

This script automates the complete PKG build process:
- Python venv setup (tokenizer + MLX worker)
- Elixir releases (controller, node-agent, CLI)
- Asset compilation and dependency resolution
- Staging with correct permissions
- PKG creation with naming convention: `Orchard-<version>-<date>-<sha>.pkg`

**Build options:**
```bash
./scripts/build-pkg.sh                    # Standard build
./scripts/build-pkg.sh --clean          # Deep clean (slow, reproducible)
./scripts/build-pkg.sh --allow-dirty    # Build with uncommitted changes
./scripts/build-pkg.sh /custom/output   # Custom output directory
```

**When to build:**
- Cutting a release for distribution
- Testing packaging changes
- Validating the full installer workflow

**When NOT to build:**
- During normal development (use `bin/dev`)
- Quick CLI testing (use `mix compile` + `iex -S mix`)

See `packaging/pkg/README.md` for full PKG operator documentation and `packaging/pkg/README.md#building-the-pkg` for detailed build instructions.

## Key Files

| File | Purpose |
|------|---------|
| SPEC.md | Normative build contract |
| AGENTS.md | This file — agent operating guide |
| README.md | High-level product and roadmap overview |
| mix.exs | Umbrella project root |
| docs/code-quality.md | ex_slop + ex_dna plugin reference and tuning guide |
