# Orchard

[![Elixir 1.20.0-otp-29](https://img.shields.io/badge/Elixir-1.20.0--otp--29-4B275F)](docs/tooling.md)
[![Erlang/OTP 29.0.2](https://img.shields.io/badge/Erlang%2FOTP-29.0.2-A90533)](docs/tooling.md)
[![mise pinned](https://img.shields.io/badge/toolchain-mise--pinned-0F766E)](mise.toml)
[![OpenSpec strict validation](https://img.shields.io/badge/OpenSpec-strict%20validation-2563EB)](openspec/README.md)

**Your LLMs. Your hardware. Your rules.**

Orchard is a sovereign on-prem LLM orchestration platform for 1–4 Apple Silicon
macOS machines. It runs inference on your own hardware, behind your own
firewall, with no cloud dependency.

## What Orchard does

- Orchestrates LLM inference across 1–4 Mac nodes using
  [MLX](https://github.com/ml-explore/mlx), Apple Silicon's native ML stack.
- Exposes OpenAI-compatible APIs: `/v1/responses` as the canonical abstraction,
  `/v1/chat/completions` as a compatibility facade, both with SSE streaming.
- Governs access with multi-tenant RBAC, API Tokens, API Clients, quotas, and
  audit logs.
- Ships as a native macOS PKG with launchd services — no Kubernetes, no
  containers required.
- Uses Postgres as the sole persistence and coordination layer (external
  Postgres today; a managed local mode is planned).

## Status

Pre-release. Orchard is built from a normative contract
([`SPEC.md`](SPEC.md)); features land as spec-traced slices.

Working today: authenticated `/v1/models`, `/v1/chat/completions` with SSE, a
bounded `/v1/responses` slice, tenant-direct API Tokens, and bulk API Client
provisioning for service-account-owned tokens. On the operations side,
`orchardctl` provides node admission review, node lifecycle previews and
execution (cordon, drain, decommission; maintenance previews only), request
diagnostics with
scheduler explanations, read-only cluster and control-plane status, and
redacted support bundle creation, alongside a Console UI for the same
cluster-management surfaces.

Not yet operator-usable: multi-node cluster bootstrap and join, the multi-node
scheduler, and managed Postgres (packaged controller installs require an
external database).

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
   ├── first-party BEAM adapter
   └── gRPC compatibility adapter
        │
   Node Agent Runtime Endpoint(s)
   ├── Model cache + verification
   ├── Worker supervisor
   └── MLX runtime (Apple Silicon native)
        │
     Postgres (sole persistence + coordination layer)
```

**Design rules:**

- All durable state lives in Postgres — no separate message broker or cache to
  operate.
- Controller-to-node communication goes through the Runtime Endpoint
  Interface, with a first-party BEAM adapter and a gRPC compatibility adapter.
- Workers are local to node agents and are never exposed on the network.
- Token streams always pass through the controller for governance and
  accounting.
- Active/Standby only: exactly one active leader, active/standby via Postgres
  advisory locks, no active/active consensus.

Transport defaults and guardrails for source development are documented in
[`docs/local-dev.md`](docs/local-dev.md);
[`docs/architecture.md`](docs/architecture.md) maps the repo and runtime
boundaries.

## Tech stack

| Layer | Choice |
|-------|--------|
| Language | Elixir/OTP (umbrella app) |
| Database | Postgres |
| Inference | MLX-LM runtime adapter managed by the node agent |
| Runtime endpoint transport | Runtime Endpoint Interface (first-party BEAM adapter; gRPC compatibility adapter) |
| APIs | Phoenix/Plug with SSE streaming |
| Packaging | `Orchard.app` DMG (app-owned service lifecycle) + PKG + launchd |
| CLI | `orchardctl` |
| Toolchain | mise-pinned Erlang/OTP, Elixir, Python, uv, Node.js, npm, and OpenSpec |

## Deployment modes

1. **All-in-one** — a single Mac runs everything: controller, node agent, and
   worker.
2. **Controller + workers** — one Mac as the control plane, 1–3 Macs as worker
   nodes.
3. **Active/Standby** — up to 2 controllers with exactly 1 active leader, still within
   the overall 1–4 Mac limit, with operator-managed endpoint failover.

All controller-bearing installs currently require an external Postgres
database. The macOS PKG uses a universal payload with role selection
(`all`, `controller`, or `node-agent`) at install time; see
[`packaging/pkg/README.md`](packaging/pkg/README.md) for the operator runbook.

### Transport and TLS

Packaged installs start on degraded loopback HTTP until an operator selects
direct HTTPS or reverse-proxy mode. TLS is provider-neutral: bring
reverse-proxy termination, operator-supplied certificates, internal PKI, or
the local-CA helper (`orchardctl tls init`) for dev-lab bootstrap. CORS is an
explicit origin allowlist, disabled by default. Full transport configuration,
including nginx/Caddy/Traefik snippets, is in
[`packaging/pkg/README.md`](packaging/pkg/README.md).

### Building the installer

```bash
mise exec -- ./scripts/build-pkg.sh
```

This produces `Orchard-<version>-<date>-<git-sha>.pkg`. Run `make setup`
first; see [`packaging/pkg/README.md`](packaging/pkg/README.md#building-the-pkg)
for full build documentation.

## Documentation

For operators:

- [`packaging/pkg/README.md`](packaging/pkg/README.md) — install, roles,
  transport, and TLS runbook.

For contributors:

- [`SPEC.md`](SPEC.md) — the normative build contract; every implementation
  decision traces back to it, and it governs the roadmap and target behavior.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — human collaboration workflow.
- [`AGENTS.md`](AGENTS.md) — the canonical automation and agent workflow guide
  ([`CLAUDE.md`](CLAUDE.md) imports it for Claude Code).
- [`docs/README.md`](docs/README.md) — the collaborator docs hub, including
  architecture, tooling, local development, process, and the product glossary.
- [`openspec/README.md`](openspec/README.md) — the OpenSpec change workflow
  subordinate to `SPEC.md`.

## Background

Orchard is a ground-up rewrite of
[Kapitan Orchard](https://github.com/najibninaba/kapitan-orchard)
(v1: Rust + Kafka + Redis + Tauri). The rewrite replaces the distributed
streaming architecture with Elixir/OTP + Postgres for simpler operations,
better fault tolerance, and native macOS integration.

## License

Proprietary. All rights reserved.
