# Architecture Guide

This guide orients collaborators to Orchard's repo and runtime boundaries. It is
not a replacement for [`../SPEC.md`](../SPEC.md), which remains the normative
product/system/build contract.

## Authority and status

- **Normative target:** `SPEC.md` defines the architecture, API contracts,
  state machines, persistence rules, packaging requirements, and roadmap.
- **Current source-dev reality:** this repo contains the Elixir umbrella apps,
  native helper packages, proto contracts, launchd/pkg assets, and validation
  workflows used to build toward that target.
- **Current packaged/operator limitation:** controller-bearing packaged installs
  require an external PostgreSQL server today. Managed Postgres is specified as
  a target mode but is not implemented.

When this guide and `SPEC.md` disagree, treat the branch as blocked until the
conflict is reconciled. `SPEC.md` wins until explicitly updated.

## System at a glance

Orchard is an on-prem LLM orchestration platform for 1–4 Apple Silicon Macs.
The target topology is:

```text
Public clients
  -> Controller (Phoenix/Elixir public APIs, Console, admission, scheduling)
     -> Postgres for durable state and coordination
     -> Node Agent(s) over internal gRPC/mTLS
        -> Worker Runtime subprocesses for local MLX inference
```

Core design rules from `SPEC.md`:

- all durable state lives in Postgres;
- public API traffic terminates at the controller;
- token streams pass through the controller;
- node agents are the network-reachable worker-node boundary;
- worker runtimes are local subprocesses, not public services;
- cross-node control traffic uses gRPC over mTLS in the target product.

## Repository map

| Path | Boundary |
|---|---|
| `apps/orchard_controller/` | Controller release: public APIs, Console, Repo, admission, scheduling, dispatch, governance, observability surfaces. |
| `apps/orchard_node_agent/` | Node-agent release: node-local runtime endpoint, model acquisition/cache, worker supervision, status/diagnostics. |
| `apps/orchard_cli/` | `orchardctl` CLI: operator/admin automation for source dev and packaged installs. |
| `apps/orchard_shared/` | Shared generated proto modules, domain structs, helpers, licensing/build metadata. |
| `native/orchard_tokenizer/` | Python helper for prompt rendering, exact token counts, and safe-tokenization support. |
| `native/orchard_worker_mlx/` | Python MLX worker runtime package and node-agent ↔ worker proto. |
| `proto/cluster/v1/` | Controller ↔ node-agent cluster RPC proto source. |
| `packaging/` | PKG, launchd, reserved DMG/container assets, signing/build runbooks. |
| `docs/` | Contributor-facing orientation, tooling, process, design, and durable decisions subordinate to `SPEC.md`. |

Use [`glossary/CONTEXT.md`](glossary/CONTEXT.md) as the shared vocabulary glossary.

## Runtime flow orientation

### Target public inference

This is the full-product target flow. Current source-dev paths may use implicit
tenant/no-auth behavior until governance milestones are complete.

1. Client calls a public `/v1` endpoint on the controller.
2. Controller authenticates, canonicalizes, renders/tokenizes, admits, and
   persists request state.
3. Scheduler chooses a node/runtime target.
4. Controller dispatches to a node agent.
5. Node agent ensures a worker/model is ready and streams worker events back.
6. Controller relays SSE/JSON to the client and finalizes usage/state.

`/v1/responses` is the target canonical abstraction. `/v1/chat/completions` is
the compatibility facade. See `SPEC.md` §3 and §7 for normative behavior.

### Node and worker runtime

The node agent owns worker subprocess lifecycle. The worker runtime owns local
model loading/generation details. Public clients never talk to workers directly.

Cluster RPC and worker RPC are separate contracts:

- `proto/cluster/v1/` describes controller ↔ node-agent messages/services.
- `native/orchard_worker_mlx/proto/` describes node-agent ↔ worker messages/services.

### Persistence and coordination

Postgres is the sole persistence and coordination layer. In the target product,
managed Postgres is one supported topology; in the current packaged flow,
controller-bearing installs require operator-provided external Postgres.

## Where to make changes

- Public API or Console behavior: start in `apps/orchard_controller/` and check
  `SPEC.md`, [`DESIGN.md`](DESIGN.md), and tests.
- Node-local runtime, worker supervision, or model acquisition: start in
  `apps/orchard_node_agent/` and `native/orchard_worker_mlx/`.
- Shared wire/domain types: start with proto or `apps/orchard_shared/`, then
  regenerate/check downstream bindings.
- CLI/operator automation: start in `apps/orchard_cli/` and
  [`../packaging/pkg/README.md`](../packaging/pkg/README.md).
- Toolchain/validation: use [`tooling.md`](tooling.md) and
  [`local-dev.md`](local-dev.md).
- Durable design decisions not already fixed by `SPEC.md`: add an ADR under
  [`decisions/`](decisions/).
