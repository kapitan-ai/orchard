# Orchard

[![Elixir 1.20.0-otp-29](https://img.shields.io/badge/Elixir-1.20.0--otp--29-4B275F)](docs/tooling.md)
[![Erlang/OTP 29.0.2](https://img.shields.io/badge/Erlang%2FOTP-29.0.2-A90533)](docs/tooling.md)
[![mise pinned](https://img.shields.io/badge/toolchain-mise--pinned-0F766E)](mise.toml)
[![OpenSpec strict validation](https://img.shields.io/badge/OpenSpec-strict%20validation-2563EB)](openspec/README.md)

**Your LLMs. Your hardware. Your rules.**

Orchard is a sovereign on-prem LLM orchestration platform for 1–4 Apple Silicon macOS machines. It runs inference on your own hardware, behind your own firewall, with no cloud dependency.

## Where to start

- [`SPEC.md`](SPEC.md) is the normative build contract.
- [`docs/README.md`](docs/README.md) is the collaborator docs hub.
- [`docs/architecture.md`](docs/architecture.md) maps the repo and runtime boundaries.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) covers human collaboration workflow.
- [`docs/local-dev.md`](docs/local-dev.md) covers source-dev setup.
- [`packaging/pkg/README.md`](packaging/pkg/README.md) covers the current PKG runbook.

## Target product capabilities

Defined by `SPEC.md`, Orchard is being built to:

- orchestrate LLM inference across 1–4 Mac nodes using [MLX](https://github.com/ml-explore/mlx);
- expose OpenAI-compatible APIs with `/v1/responses` as the canonical abstraction and `/v1/chat/completions` as a compatibility facade;
- support multi-tenant RBAC, API Token and API Client scoping, quotas, and audit logs;
- ship as native macOS PKG/DMG media with launchd services and no Kubernetes requirement;
- support managed Postgres in a future local-container mode while also supporting external Postgres.

Current packaged controller-bearing installs require external Postgres. Managed
Postgres is not available in current builds; the shipped
`orchard-managed-postgres` helper is an operator-safe guard that prints external
database setup guidance and exits non-zero for operational invocations. DMG
media remains reserved for future work.

## Architecture

```
Clients (SDKs / curl / apps)
        │
   HTTPS / SSE
        │
   Controller (Elixir/OTP)
   ├── Inference API    ── `/v1/responses` canonical, `/v1/chat/completions` facade
   ├── Auth / RBAC      ── API Tokens, API Clients + tenant quotas
   ├── Scheduler        ── Runtime Endpoint selection, queueing, fairness
   ├── Dispatch         ── Runtime Endpoint operations + stream relay
   └── Observability    ── Prometheus, OTel, structured logs
        │
   Runtime Endpoint Interface
        │
   Runtime Endpoint adapter(s)
   ├── gRPC compatibility adapter (current default)
   └── first-party BEAM adapter (default-off rollout)
        │
   Node Agent Runtime Endpoint(s)
   ├── Model cache + verification
   ├── Worker supervisor
   └── MLX runtime (Apple Silicon native)
        │
     Postgres (sole persistence + coordination layer)
```

**Key design rules:**

- All durable state lives in Postgres.
- Controller runtime execution uses the Runtime Endpoint Interface.
- The current `NodeRuntimeService` gRPC path is a compatibility adapter, not the durable domain contract.
- First-party BEAM communication is implemented behind explicit guardrails and must not become durable cluster truth.
- Source-dev uses the gRPC compatibility adapter by default until BEAM Runtime Endpoint transport is explicitly promoted after accepted two-Mac smoke evidence.
- Source-dev BEAM is available only through the explicit split-role `bin/dev-controller` and `bin/dev-node-agent` flow while all-in-one `bin/dev` remains the gRPC default.
- Explicit Source-dev BEAM mode does not automatically retry a failed request through gRPC compatibility.
- Workers are local to node agents and are never exposed on the network.
- Token streams always pass through the controller for governance and accounting.
- HA-lite only: exactly one active leader, active/standby via Postgres advisory locks, no active/active consensus.

## Tech stack

| Layer | Choice |
|-------|--------|
| Language | Elixir/OTP (umbrella app) |
| Database | Postgres |
| Inference | MLX-LM runtime adapter managed by the node agent |
| Runtime endpoint transport | Runtime Endpoint Interface with current gRPC compatibility adapter, explicit split-role first-party BEAM mode, and recorded two-Mac smoke evidence awaiting separate default promotion |
| APIs | Phoenix/Plug (loopback HTTP in source dev; HTTPS + SSE in packaged installs) |
| Packaging | DMG, PKG, launchd |
| CLI | `orchardctl` |
| Toolchain | mise-pinned Erlang/OTP, Elixir, Python, uv, Node.js, npm, and OpenSpec |

### Current transport behavior

- **Source dev:** controller runs on loopback HTTP (`127.0.0.1:4000`); CORS
  disabled unless explicitly configured
- **Packaged installs:** controller defaults to degraded loopback HTTP
  (`ORCHARD_TRANSPORT_MODE=plain_http_localhost`) until an operator selects
  `direct_https` or `reverse_proxy`; legacy `ORCHARD_TLS_*` variables are
  one-release compatibility shims
- **Provider-neutral TLS:** the PKG installer does not generate or procure
  production certificates by default. Operators can use reverse-proxy TLS
  termination, direct HTTPS with operator cert/key paths, proprietary/paid CAs,
  internal PKI or air-gapped HTTPS, or explicit local-CA helper output from
  `orchardctl tls init` for dev-lab bootstrap.
- **Forwarded headers:** reverse-proxy mode trusts `x-forwarded-*` only from
  loopback by default; non-loopback proxy binds require `ORCHARD_TRUSTED_PROXIES`.
- **CORS:** explicit origin allowlist via `ORCHARD_CORS_ORIGINS` (empty =
  disabled)

See [docs/tooling.md](docs/tooling.md) for required local toolchain setup,
[docs/local-dev.md](docs/local-dev.md) for dev setup, and
[packaging/pkg/README.md](packaging/pkg/README.md) for operator transport
configuration, including nginx/Caddy/Traefik snippets.

### Building releases

For distribution or testing the packaged installer:

```bash
mise exec -- ./scripts/build-pkg.sh
```

This creates a native macOS PKG installer following the naming convention
`Orchard-<version>-<date>-<git-sha>.pkg`. Use `--clean` for reproducible
builds from scratch, or `--allow-dirty` for development builds.

**Prerequisites:** run `make setup` from the repo root, or run
`mise trust && mise install` plus the setup commands in
[`docs/local-dev.md`](docs/local-dev.md), before building. You also need the
macOS packaging tools. The script validates dependencies and provides helpful
errors if anything is missing.

See [packaging/pkg/README.md](packaging/pkg/README.md#building-the-pkg) for
full build documentation.

## Deployment modes

These are the target product topologies defined by `SPEC.md`:

1. **All-in-one** — single Mac runs everything (controller + node agent + worker + managed Postgres)
2. **Controller + workers** — 1 Mac as control plane, 1–3 Macs as worker nodes; Postgres is either managed on the controller host or operator-managed externally
3. **HA-lite** — up to 2 controllers with exactly 1 active leader, still within the overall 1–4 Mac deployment limit, with operator-managed endpoint failover

Current packaged controller-bearing installs require External Database Mode
until Managed Database Mode is implemented and enabled; the managed Postgres
helper is a guard only.

The macOS PKG uses a universal payload with role selection at install time. Seed `/Library/Application Support/Orchard/support/.install-role.request` with `all`, `controller`, or `node-agent` before running `installer`; the installed marker is `/Library/Application Support/Orchard/support/.install-role`. Source development has matching split-role scripts: `bin/dev-controller` for the controller host and `bin/dev-node-agent` for worker hosts.

## Roadmap

| Milestone | Scope |
|-----------|-------|
| M0 | Skeleton and packaging foundation (umbrella, Postgres, launchd, `/health/live`, `/health/ready`) |
| M1 | Single-node inference MVP (`GET /v1/models`, `POST /v1/chat/completions`, SSE streaming, MLX worker; compatibility-first while the internal canonical abstraction remains Responses-based) |
| M2 | Responses API and governance core (public `POST /v1/responses`, tenants, API Tokens, API Clients, quotas, audit, idempotency) |
| M3 | Node lifecycle and cluster join (bootstrap/cert join, heartbeats, pools, cordon/drain/maintenance) |
| M4 | Multi-node scheduler and placements (tiered scoring, queueing, `EnsureModelLoaded`, pre-first-token retry) |
| M5 | Observability and diagnostics (Prometheus, OTel tracing, structured logs, support bundles) |
| M6 | Security hardening and air-gap (mTLS, cert renewal, retention modes, offline import/install) |
| M7 | Upgrade safety and HA-lite controller (leadership locks, migration ownership, rolling upgrades, `orchardctl upgrade plan`) |

## Status

Pre-release.
Building from spec.
The current source tree includes authenticated
`/v1/models`, `/v1/chat/completions`, a bounded `/v1/responses` slice, tenant-direct API Tokens, and bulk API Client provisioning for service-account-owned API Tokens.
Full M2 quota behavior remains in progress.
An initial cluster-admin `/admin/v1` node-admission surface (candidate review, rejection, rejection clearance, and admission) is present ahead of its M3 milestone, but is not yet operator-usable because cluster bootstrap and first-admin credential provisioning are not yet implemented.
The roadmap and target behavior are governed by `SPEC.md` §14.

Some SPEC-required CLI paths are present before their milestone implementation:
`orchardctl cluster init`, `orchardctl node join`, `orchardctl nodes admit`,
and `orchardctl requests inspect` return command-specific deferred-status
errors with the current supported path. `orchardctl support bundle create`
creates a local diagnostic `.tar.gz` with bounded redacted logs, redacted
config, service status, node snapshots, and request summaries.

## Spec

[`SPEC.md`](SPEC.md) is the normative build contract — every implementation decision traces back to it.

## Contributing And Workflow

This repository is the collaborator-facing source of truth for Orchard.
Historical coordination/workbench notes may inform work, but active guidance
must be rewritten into this repo before it counts as Orchard truth.

- [`SPEC.md`](SPEC.md) is the top-level normative build contract.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) explains human collaboration workflow.
- [`AGENTS.md`](AGENTS.md) is the canonical automation and agent workflow guide; [`CLAUDE.md`](CLAUDE.md) imports it for Claude Code.
- [`docs/glossary/CONTEXT.md`](docs/glossary/CONTEXT.md) defines Orchard's shared product language.
- [`docs/README.md`](docs/README.md) is the collaborator docs hub.
- [`docs/architecture.md`](docs/architecture.md) explains repo and runtime boundaries.
- [`docs/tooling.md`](docs/tooling.md) explains the required mise toolchain and local accelerator tools.
- [`docs/local-dev.md`](docs/local-dev.md) explains source development setup and smoke checks.
- [`docs/process.md`](docs/process.md) explains artifact lifecycle and review gates.
- [`openspec/README.md`](openspec/README.md) explains the initialized OpenSpec
  change workflow subordinate to `SPEC.md`.

Active local `goals/<slug>/` packages are transient execution scaffolding and
are ignored by default.

## Background

Orchard is a ground-up rewrite of [Kapitan Orchard](https://github.com/najibninaba/kapitan-orchard) (v1: Rust + Kafka + Redis + Tauri). The rewrite replaces the distributed streaming architecture with Elixir/OTP + Postgres for simpler operations, better fault tolerance, and native macOS integration.

## License

Proprietary. All rights reserved.
