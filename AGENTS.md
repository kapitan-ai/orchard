# AGENTS.md — Orchard v2

Sovereign on-prem LLM orchestration platform for Apple Silicon macOS. Elixir/OTP + Postgres.

## Build Contract

**SPEC.md** is the normative build contract. Every implementation decision must trace to a section in the spec. If the spec doesn't cover something, ask before improvising.

## Architecture (from SPEC.md)

- **Language**: Elixir/OTP (umbrella app)
- **Database**: Postgres (sole persistence + coordination layer)
- **APIs**: `/v1/responses` (canonical), `/v1/chat/completions` (facade)
- **Internal comms**: gRPC over mTLS
- **Packaging**: native macOS DMG/PKG + launchd
- **Clustering**: Postgres advisory locks + gRPC heartbeats (HA-lite)
- **Inference**: MLX via NIF/Port (Apple Silicon native)

## Milestones

| Milestone | Scope |
|-----------|-------|
| M0 | Skeleton: umbrella, Postgres, health check |
| M1 | Single-node inference (MLX NIF, `/v1/responses`) |
| M2 | Governance (tenants, API keys, RBAC, quotas) |
| M3 | Multi-model orchestration (scheduler, placement, model FSM) |
| M4 | Chat/completions facade, streaming, tool-use relay |
| M5 | Observability (Prometheus, OTel, structured logs) |
| M6 | Native packaging (DMG/PKG, launchd, Keychain) |
| M7 | HA-lite (active/standby, advisory locks, fencing) |

## Conventions

- Follow Elixir community conventions (mix format, credo, dialyzer)
- Tests: ExUnit, aim for spec-traceable acceptance tests per milestone
- Commits: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- Config: `config/` for compile-time, `config/runtime.exs` for runtime

## Key Files

| File | Purpose |
|------|---------|
| SPEC.md | Normative build contract (2,855 lines) |
| AGENTS.md | This file — agent operating guide |
| mix.exs | Umbrella project root |

## Context

- Previous iteration (v1): `~/Hacks/kapitan-orchard/` (Rust + Kafka, being superseded)
- ops-kb research entry: `~/Hacks/ops-kb/docs/research/orchard-v2-sovereign-llm-spec.md`
- DEVONthink: UUID `20DB89CF-C2B5-46CB-9215-F5FEEEDCA994`
