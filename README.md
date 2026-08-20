<p align="center">
  <img src="apps/orchard_controller/priv/static/images/orchard-mark.svg" alt="Orchard" width="96" height="96">
</p>

<h1 align="center">Orchard</h1>

<h3 align="center">Your LLMs. Your hardware. Your rules.</h3>

<p align="center">
  Sovereign on-prem LLM orchestration for 1–4 Apple Silicon Macs — OpenAI-compatible
  APIs, multi-tenant governance, and native macOS operations. No cloud, no Kubernetes.
</p>

<p align="center">
  <a href="VERSION"><img alt="Version" src="https://img.shields.io/badge/version-0.5.0--dev-1565C0"></a>
  <a href="#status--roadmap"><img alt="Status" src="https://img.shields.io/badge/status-pre--release%20(pilot)-FDD835"></a>
  <a href="#deployment-modes"><img alt="Platform" src="https://img.shields.io/badge/platform-Apple%20Silicon%20macOS-000000?logo=apple&logoColor=white"></a>
  <a href="#use-it-from-your-code"><img alt="OpenAI-compatible" src="https://img.shields.io/badge/API-OpenAI--compatible-412991?logo=openai&logoColor=white"></a>
  <a href="https://github.com/ml-explore/mlx"><img alt="MLX" src="https://img.shields.io/badge/inference-MLX--LM-FF6F00"></a>
  <a href="#tech-stack"><img alt="Postgres" src="https://img.shields.io/badge/Postgres-16%2B-4169E1?logo=postgresql&logoColor=white"></a>
  <a href="#license"><img alt="License" src="https://img.shields.io/badge/license-Proprietary-6B7280"></a>
</p>

<p align="center">
  <a href="https://github.com/kapitan-ai/orchard/actions/workflows/required-validation.yml"><img alt="Orchard CI" src="https://github.com/kapitan-ai/orchard/actions/workflows/required-validation.yml/badge.svg?branch=main"></a>
  <a href="docs/tooling.md"><img alt="Elixir" src="https://img.shields.io/badge/Elixir-1.20.0--otp--29-4B275F?logo=elixir&logoColor=white"></a>
  <a href="docs/tooling.md"><img alt="Erlang/OTP" src="https://img.shields.io/badge/Erlang%2FOTP-29.0.2-A90533?logo=erlang&logoColor=white"></a>
  <a href="mise.toml"><img alt="mise pinned" src="https://img.shields.io/badge/toolchain-mise--pinned-0F766E"></a>
  <a href="SPEC.md"><img alt="Spec-traced" src="https://img.shields.io/badge/build-spec--traced-2563EB"></a>
  <a href="openspec/README.md"><img alt="OpenSpec" src="https://img.shields.io/badge/OpenSpec-strict%20validation-2563EB"></a>
</p>

---

## Why Orchard

Teams that cannot send prompts to a cloud provider still want the developer
experience of one. Orchard turns a handful of Macs you already own into a
governed inference service: your applications keep talking to an
OpenAI-compatible endpoint, while every token, key, and request stays inside
your network and under your audit trail.

- **Sovereign by construction** — inference runs on your hardware, behind your
  firewall, with no cloud inference dependency.
- **Drop-in for existing code** — point any OpenAI SDK at your controller and
  change the base URL and key.
- **Governed, not just exposed** — organizations, tenants, RBAC, API keys,
  deny-by-default model access, and audit logs are part of the product, not an
  afterthought. Full configurable quota policy is still being completed.
- **Operable by one person** — a signed `Orchard.app` DMG, launchd-managed
  services, a guided `orchardctl init`, and a web Console. No Kubernetes, no
  containers, no message broker.
- **Apple Silicon native** — models execute on [MLX](https://github.com/ml-explore/mlx),
  Apple's native ML stack, on the Macs you already have.

## Who it's for

- Regulated or air-gap-leaning teams (finance, defence, healthcare, public
  sector) that need self-hosted LLM inference with an auditable access model.
- Platform teams who want one internal inference endpoint shared by several
  product teams, with per-tenant keys and model grants.
- Small labs and studios with Apple Silicon capacity that should serve the whole
  team instead of one laptop.

## What you get

**Inference API**

- `/v1/responses` as the canonical abstraction, `/v1/chat/completions` as a
  compatibility facade, both with SSE streaming and client-disconnect
  cancellation.
- `/v1/models` scoped to what the calling tenant is actually granted.
- Every request lifecycle transition, deadline, and attempt outcome persisted in
  Postgres for diagnostics and accounting.

**Governance**

- Organizations and tenants, cluster-admin bootstrap, and role-based operator
  access.
- Tenant-direct API keys, API Clients for service-account-owned tokens (with
  bulk provisioning), and tenant-scoped admission controls. Full configurable
  per-tenant quota policy is specified but not yet shipped.
- Deny-by-default Tenant-to-Model access grants — a loaded model serves nobody
  until it is explicitly granted.
- A TLS-only Developer Portal where invited, named Portal Users mint, list, and
  revoke their own keys without filing a ticket with an operator.

**Operations**

- Console (Phoenix LiveView): cluster overview, nodes, models and model hub,
  tenants, keys, request inspection, settings, and a built-in playground.
- `orchardctl`: guided first run, node trust and enrollment, admission review,
  node lifecycle (cordon, drain, decommission), model import and access grants,
  request diagnostics with scheduler explanations, cluster status, TLS and
  transport setup, upgrades, and redacted support bundles.
- Prometheus exposition on `/metrics`, health and readiness endpoints, and
  request-correlated logs; structured logging and OpenTelemetry tracing are
  specified but not yet shipped.

**Packaging**

- `Orchard.app` DMG with an app-owned, root-authorized service lifecycle, plus a
  universal macOS PKG with install-time role selection (`all`, `controller`,
  `node-agent`).
- Packaged controller installs use operator-managed external PostgreSQL 16+;
  managed Postgres is not available in this build. There is no broker, cache, or
  extra control-plane store to operate.

## Use it from your code

Once an operator has granted your tenant a model and issued you a key, Orchard
is an OpenAI-compatible endpoint:

```bash
curl -N -X POST https://orchard.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ORCHARD_API_KEY" \
  -d '{
    "model": "your-model@v1",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

```python
from openai import OpenAI

client = OpenAI(base_url="https://orchard.internal/v1", api_key=ORCHARD_API_KEY)
client.responses.create(model="your-model@v1", input="Hello!")
```

Operators install from the release media and follow
[`packaging/dmg/README.md`](packaging/dmg/README.md) or
[`packaging/pkg/README.md`](packaging/pkg/README.md); contributors run from
source with `make dev` (see [`docs/local-dev.md`](docs/local-dev.md)).

## Status & roadmap

Orchard is **pre-release** (`0.5.0-dev`) and currently runs internal pilots. It
is built from a normative contract ([`SPEC.md`](SPEC.md)); features land as
spec-traced slices.

Working today: authenticated `/v1/models`, `/v1/chat/completions` with SSE, a
bounded `/v1/responses` slice, tenant model grants, tenant-direct API tokens,
bulk API Client provisioning, the Developer Portal, the Console, Prometheus
metrics, and — on the operations side — node trust initialization, secure
single-node enrollment and join, admission review, node lifecycle execution
(cordon, drain, decommission; maintenance previews only), request diagnostics
with scheduler explanations, cluster and control-plane status, and redacted
support bundles.

Not yet operator-usable: multi-node cluster bootstrap beyond the one-controller
one-node enrollment tracer, broader production multi-node scheduling, full
configurable tenant quota policy, Active/Standby failover, and managed Postgres
— packaged controller installs require an external PostgreSQL 16+ server.

| Milestone | Scope | State |
|-----------|-------|-------|
| M0 | Skeleton and packaging foundation | Complete |
| M1 | Single-node inference MVP (models, chat completions, SSE, MLX worker) | Complete |
| M2 | Responses API and governance core | Partial (quota policy incomplete) |
| M3 | Node lifecycle and cluster join | Partial (enrollment/lifecycle tracer) |
| M4 | Multi-node scheduler and placements | In progress (broader production scheduling pending) |
| M5 | Observability and diagnostics | Partial (metrics floor, diagnostics) |
| M6 | Security hardening and air-gap | Partial (transport/certificate slices) |
| M7 | Upgrade safety and Active/Standby controller | Planned |

## Architecture

```
Clients (SDKs / curl / apps)
        │
   HTTPS / SSE
        │
   Controller (Elixir/OTP)
   ├── Inference API    ── `/v1/responses` canonical, `/v1/chat/completions` facade
   ├── Auth / RBAC      ── API Tokens, API Clients + tenant admission controls
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
- Target Active/Standby model: exactly one active leader via Postgres advisory
  locks, with no active/active consensus. Failover is not yet operator-usable.

Transport defaults and guardrails for source development are documented in
[`docs/local-dev.md`](docs/local-dev.md);
[`docs/architecture.md`](docs/architecture.md) maps the repo and runtime
boundaries.

## Tech stack

| Layer | Choice |
|-------|--------|
| Language | Elixir/OTP (umbrella app) |
| Database | Postgres 16+ |
| Inference | MLX-LM runtime adapter managed by the node agent |
| Runtime endpoint transport | Runtime Endpoint Interface (first-party BEAM adapter; gRPC compatibility adapter) |
| APIs | Phoenix/Plug with SSE streaming |
| Console | Phoenix LiveView |
| Packaging | `Orchard.app` DMG (app-owned service lifecycle) + PKG + launchd |
| CLI | `orchardctl` |
| Toolchain | mise-pinned Erlang/OTP, Elixir, Python, uv, Node.js, npm, and OpenSpec |

## Deployment modes

1. **All-in-one** — a single Mac runs everything: controller, node agent, and
   worker.
2. **Controller + workers** — one Mac as the control plane, 1–3 Macs as worker
   nodes.
3. **Active/Standby (target)** — up to 2 controllers with exactly 1 active
   leader, still within the overall 1–4 Mac limit. Failover is not yet
   operator-usable.

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

- [`docs/operator-journey.md`](docs/operator-journey.md) — current and target
  operator journeys, friction baseline, recovery points, and ordered
  improvement slices.
- [`packaging/dmg/README.md`](packaging/dmg/README.md) — `Orchard.app` DMG
  verification and app-owned service lifecycle.
- [`packaging/pkg/README.md`](packaging/pkg/README.md) — install, roles,
  transport, and TLS runbook.
- [`docs/pilots/README.md`](docs/pilots/README.md) — pilot start bar and
  runbook.

For contributors:

- [`SPEC.md`](SPEC.md) — the normative build contract; every implementation
  decision traces back to it, and it governs the roadmap and target behavior.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — human collaboration workflow.
- [`AGENTS.md`](AGENTS.md) — the canonical automation and agent workflow guide
  ([`CLAUDE.md`](CLAUDE.md) imports it for Claude Code).
- [`docs/README.md`](docs/README.md) — the collaborator docs hub, including
  architecture, tooling, local development, process, design, and the product
  glossary.
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
