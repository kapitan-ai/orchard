# AGENTS.md — Orchard v2

Orchard is a sovereign on-prem LLM orchestration platform for Apple Silicon macOS. Elixir/OTP + Postgres.

## Build Contract

**SPEC.md** is the top-level normative Orchard build contract. Every
implementation decision must trace to `SPEC.md`, tests, product docs, a
decision record, or an explicitly approved issue/PR decision.

If `SPEC.md`, docs, OpenSpec materials, tests, or implementation disagree
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

Investigation notes, smoke evidence documents, and slice plans are transient:
do not commit them as standalone repo documents. Promote their durable
conclusions into `SPEC.md`, docs, decisions, tests, or code, and record
execution evidence in the relevant pull request or issue.

Durable conclusions belong in this repo: `SPEC.md`, `docs/**`,
`docs/decisions/**`, tests, code, or approved OpenSpec materials.

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

## OpenSpec Workflow

OpenSpec is initialized as Orchard's collaborator-reviewable change-intent
workflow under `SPEC.md`. Use it for substantial behavior, architecture, API,
security/governance, node lifecycle, scheduling, packaging, or
collaborator-owned changes.

Rules:

- `SPEC.md` remains the apex product contract.
- OpenSpec change packages live in `openspec/changes/<change-id>/`.
- Each OpenSpec change should include `proposal.md`, `tasks.md`, and spec
  deltas; add `design.md` when the change has technical ambiguity, migration
  risk, security/performance concerns, or cross-module impact.
- Before implementation or PR handoff, run
  `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate <change-id> --type change --strict --no-interactive`.
- After archiving or syncing accepted behavior, run
  `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive`.
- Review generated main specs for placeholder prose such as `Purpose TBD`;
  strict validation accepts some incomplete prose that still needs human review.
- Do not mirror large sections of `SPEC.md` into OpenSpec specs.
- Do not commit generated `.codex/`, `.claude/`, prompt exports, local context
  stores, tool session identifiers, or machine-local execution evidence.

## Architecture (from SPEC.md)

- **Language**: Elixir/OTP (umbrella app)
- **Database**: Postgres (sole persistence + coordination layer)
- **APIs**: `/v1/responses` (canonical abstraction), `/v1/chat/completions` (compatibility facade)
- **Internal comms**: BEAM-first Runtime Endpoints for admitted first-party services; certificate-authenticated gRPC control and compatibility paths
- **Packaging**: approved macOS native distribution profile of a signed `Orchard.app` inside a DMG plus launchd; native PKG is not a supported current distribution channel
- **Clustering**: Postgres advisory locks + authenticated Runtime Endpoint observations (Active/Standby control plane)
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
| M7 | Upgrade safety and Active/Standby controller |
| M8 | Portable Orchard control-plane core and Linux Controller profile |

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

## Agent Command Surface

Prefer the repo command surface when it exists. `Makefile` targets are thin
aliases over documented `mise exec --` commands; they do not define product
truth or validation policy.

Authority order:

1. `SPEC.md`, this `AGENTS.md`, and product docs define behavior and workflow.
2. `docs/tooling.md` defines pinned runtime/tool versions.
3. `Makefile` provides convenience entrypoints only.

If a `Makefile` target and the docs disagree, treat the docs as authoritative
and fix the `Makefile`.

Recommended targets:

- `make setup` — install pinned repo dependencies.
- `make dev` — run source dev in the foreground.
- `make dev-controller` — run the source-dev controller host in the foreground.
- `make dev-node-agent` — run the source-dev node-agent host in the foreground.
- `make openspec` — run pinned OpenSpec validation.
- `make format` — run Elixir formatter.
- `make test` — run the default test suite.
- `make check-elixir` — run the full Elixir quality workflow.

`make dev` must remain a foreground/blocking command equivalent to
`mise exec -- bin/dev`. Do not background the dev server from `make dev`. If
background operation is needed, use explicit targets such as `dev-bg`,
`dev-stop`, and `dev-status` with PID/log handling.

Do not assume packaged Orchard BEAM processes under
`/Library/Application Support/Orchard/` mean source dev is running. Source dev
uses the repo checkout and defaults to HTTP `:4000` plus gRPC `:50071`.

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

### Swift/macOS app workflow

For code under `packaging/app/`, use the host Xcode Command Line Tools and Swift toolchain required by the package manifest.
Run these from the umbrella root:

1. `xcrun swift-format format --in-place --recursive packaging/app/Sources packaging/app/Tests`
2. `xcrun swift-format lint --recursive packaging/app/Sources packaging/app/Tests`
3. `swift build --package-path packaging/app`
4. `swift test --package-path packaging/app`
5. `swift test --package-path packaging/app --enable-code-coverage`
6. `scripts/test-app-service-lifecycle.sh`
7. `scripts/test-build-app.sh`
8. `scripts/test-app-signing.sh`
9. `scripts/test-build-dmg.sh`

Run `ORCHARD_TEST_REAL_AMORE=1 scripts/test-build-dmg.sh` only for the credential-free local Amore assembly smoke.
Developer ID signing, notarization, stapling, publication, and system-root lifecycle mutations remain explicit credential or authorization gates.

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

**Start with:** `make dev` when a `Makefile` is available; otherwise
`mise exec -- bin/dev`.

This single command creates the dev database if needed, runs migrations, sets
the dev gRPC port to 50071 (avoiding conflict with the packaged BEAM on 50061),
and starts `iex -S mix phx.server`.

For source-dev cluster roles, use `mise exec -- bin/dev-controller` for the
Phoenix/controller host and `mise exec -- bin/dev-node-agent` for a
node-agent-only worker host.
The split-role scripts default to BEAM Runtime Endpoint transport when
`ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` is unset.
The current validated two-Mac smoke pattern starts `mise exec -- bin/dev-node-agent`
on each worker host with `ORCHARD_BEAM_NODE_NAME=orchard_node_agent@<ipv4>` and a
shared owner-only `ORCHARD_BEAM_COOKIE_FILE`, then starts
`mise exec -- bin/dev-controller` on the controller host with
`ORCHARD_BEAM_NODE_NAME=orchard_controller@<controller-ipv4>`, the same cookie
file, and `ORCHARD_RUNTIME_ENDPOINT_TARGETS=orchard_node_agent@<worker-ipv4>`.
Use `ORCHARD_BEAM_EPMD_PORT=43690` or another shared nonstandard port when a host
already has EPMD on `4369`.
Use `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`,
`ORCHARD_NODE_AGENT_LISTEN_HOST=0.0.0.0`, and
`ORCHARD_RUNTIME_CLIENT_TARGETS=<worker-ip>:50071` only for the gRPC compatibility
opt-out path.

`mise exec -- bin/source-dev-peer-grant` drives the experimental
one-Controller/one-Node BEAM Peer Grant tracer (certificate-bound scoped grants,
certificate-authenticated grant delivery, owner-only Node custody, and TLS 1.3
Distribution launch without the shared cookie). It is source-development only;
the current two-Mac app-installed path still uses the shared-cookie first cut above. See
the "Source-dev BEAM Peer Grant tracer" section in `docs/local-dev.md`.

When to bypass `bin/dev`:
- `mise exec -- iex -S mix` — BEAM without HTTP server (one-off scripts, migrations)
- `mise exec -- iex -S mix phx.server` — manual server start with custom env vars
- `mise exec -- mix test` - test suite (uses its own DB and defaults to port 50071 via `test.exs`; override with `ORCHARD_TEST_NODE_AGENT_PORT` when another worktree owns that port)

See `docs/local-dev.md` for full environment setup and configuration.

## macOS Distribution

The approved macOS native distribution profile is the signed and notarized DMG containing `Orchard.app`.
Do not describe Orchard as having a supported public binary, and do not treat source availability as a licensing change.
`SPEC.md` §11 owns the source-availability contract and `packaging/dmg/README.md` owns the release gates.
Use the Swift/macOS app workflow above and `packaging/dmg/README.md` for current build and verification guidance.

Native PKG is not a supported distribution channel, release artifact, operator
workflow, or validation gate.
The app retains legacy PKG receipt detection only to prevent silent ownership
takeover of an existing installation; it must not be used to claim support.
Any future native package requires a fresh accepted OpenSpec proposal and a
separate implementing pull request that updates the normative contract,
security posture, operator documentation, and validation gates.

## Key Files

| File | Purpose |
|------|---------|
| SPEC.md | Normative build contract |
| AGENTS.md | This file — agent operating guide |
| CLAUDE.md | Claude Code import shim for AGENTS.md |
| README.md | High-level product overview |
| CONTRIBUTING.md | Human collaborator workflow |
| CONTEXT-MAP.md | Domain-modeling discovery map for glossary context |
| Makefile | Thin convenience command index over `mise exec --` |
| mise.toml | Pinned local toolchain contract |
| docs/glossary/CONTEXT.md | Shared Orchard product glossary |
| docs/tooling.md | mise, validation command, and local tool guidance |
| docs/local-dev.md | Source development setup and smoke-test guidance |
| docs/process.md | Artifact lifecycle and process guidance |
| docs/architecture.md | Contributor architecture and repo-boundary orientation |
| docs/decisions/ | ADR-style durable decisions |
| goals/README.md | Local goal package policy |
| openspec/README.md | Initialized OpenSpec change workflow |
| mix.exs | Umbrella project root |
| docs/code-quality.md | ex_slop + ex_dna plugin reference and tuning guide |
| docs/agents/ | Per-repo config for Matt Pocock engineering skills (issue tracker, triage labels, domain docs) |

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `kapitan-ai/orchard` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Multi-context map at root: `CONTEXT-MAP.md` → `docs/glossary/CONTEXT.md`; decisions in `docs/decisions/`. See `docs/agents/domain.md`.
