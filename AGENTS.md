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

## Key Files

| File | Purpose |
|------|---------|
| SPEC.md | Normative build contract |
| AGENTS.md | This file — agent operating guide |
| README.md | High-level product and roadmap overview |
| mix.exs | Umbrella project root |
