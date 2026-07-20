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
  a target mode but is not available in current builds; the packaged
  `orchard-managed-postgres` helper is an operator-safe guard, not a runtime
  service.
- **CLI operations:** `orchardctl nodes trust init` initializes the internal Node trust authority, `orchardctl nodes enrollment create --output PATH` issues an owner-only single-Node Enrollment Bundle from the active controller, and `orchardctl node join --enrollment-bundle PATH` redeems it with pinned controller trust, persisting the local Node identity and issued Node Certificate; the joined Node stays non-schedulable until explicit admission.
  `orchardctl cluster init` mints the first cluster-admin API Client credential as a local, one-shot, audited controller-host operation behind the leader-only write gate, delivering the token exactly once through a required `--output` One-time Secret Output path (never stdout), refusing a second init with `cluster_already_initialized`, and supporting `--force-new-admin --yes` recovery minting, `--client-name`, and `--json`.
  `orchardctl requests inspect <request-id>` reads the local controller Repo and renders the persisted scheduler explanation for a request, with stable human and `--json` output from the shared Operator API presenter.
  Broader request execution diagnostics beyond persisted scheduler explanations remain future work.
  `orchardctl cluster status` reads the local controller runtime and renders read-only cluster and control-plane status, with a `--json` mode that emits the shared `ControlPlaneStatus` payload plus a control-plane summary and no leadership-transfer or failover actions.
  `orchardctl nodes inspect`, `orchardctl nodes pending`,
  `orchardctl nodes admit`, and `orchardctl nodes reject` are implemented for
  the current node-admission-review slice, with stable JSON and human output,
  `--dry-run` previews, and `--yes` execution gating; `orchardctl nodes reject`
  additionally requires a nonblank `--reason`, and `orchardctl nodes admit`
  requires a nonblank `--capacity-policy-reason` and accepts an optional
  non-negative `--controller-dispatch-ceiling` that defaults to `1`, persisting
  the Controller Dispatch Ceiling atomically with admission.
  `orchardctl nodes inspect` also surfaces an observe-only runtime
  memory-budget block, at parity with the Console node-detail memory telemetry
  group, when a matching Runtime Endpoint snapshot reports memory-budget
  telemetry and failing open to omission otherwise.
  `orchardctl nodes inspect` surfaces a counterfactual dispatch-capacity block
  showing what F11 enforcement would decide; every capacity consumer stays on
  its current behavior in this non-enforcing slice.
  `orchardctl nodes cordon`, `orchardctl nodes uncordon`,
  `orchardctl nodes drain`, `orchardctl nodes cancel-drain`,
  `orchardctl nodes maintenance`, `orchardctl nodes resume`, and
  `orchardctl nodes decommission` add node lifecycle previews and execution on
  the shared Action Preview contract, gated by `--yes`, `--acknowledge`, and
  `--typed-node-id`; `orchardctl nodes cancel-drain` stops an in-progress drain
  and holds the node `cordoned`, allowed only from `draining` and otherwise
  reporting a `drain_not_running` blocker; `orchardctl nodes maintenance`
  previews only, with its `draining -> maintenance` execution deferred until
  drain completion can be verified.
  `orchardctl support bundle create` creates a local diagnostic archive
  with bounded redacted logs, redacted config, service status, node snapshots,
  shared cluster-management node status, and request summaries.

When this guide and `SPEC.md` disagree, treat the branch as blocked until the
conflict is reconciled. `SPEC.md` wins until explicitly updated.

## System at a glance

Orchard is an on-prem LLM orchestration platform for 1–4 Apple Silicon Macs.
The target topology is:

```text
Public clients
  -> Controller (Phoenix/Elixir public APIs, Console, admission, scheduling)
     -> Postgres for durable state and coordination
     -> Runtime Endpoint Interface
        -> first-party BEAM adapter as the split-role source-dev default and enrolled production target
        -> gRPC compatibility adapter as the explicit control, recovery, diagnostics, external-adapter, and opt-out path
        -> future external/provider adapters
     -> Node Agent(s)
        -> Worker Runtime subprocesses for local MLX inference
```

Core design rules from `SPEC.md`:

- all durable state lives in Postgres;
- public API traffic terminates at the controller;
- token streams pass through the controller;
- the Controller dispatches model runtime work through the Runtime Endpoint Interface;
- the current `NodeRuntimeService` gRPC/protobuf path is a compatibility adapter, not the durable domain contract;
- first-party BEAM communication is the split-role source-dev default and the enrolled production target behind explicit guardrails;
- split-role source dev uses BEAM by default through `bin/dev-controller` and `bin/dev-node-agent` launches;
- gRPC remains available as an explicit opt-out compatibility adapter with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`;
- all-in-one `bin/dev` remains the single-host gRPC default and rejects explicit BEAM mode;
- source-dev BEAM mode does not automatically fall back to gRPC compatibility for the same request;
- Console live runtime diagnostics use the same configured Runtime Endpoint target list as scheduler and dispatch, with explicit BEAM targets taking precedence over legacy gRPC runtime client targets;
- BEAM Runtime Endpoint targets validate BEAM node-name addresses and configured node UUIDs before scheduler or dispatch trusts endpoint identity;
- production BEAM uses OTP TLS distribution plus one scoped BEAM Peer Grant for each exact Controller-to-Node pair;
- Node Certificates remain durable identity anchors, while BEAM Peer Grants provide bounded transport authorization and never replace Node Admission;
- each Active/Standby Controller has a distinct identity, BEAM name, authorization root, and Peer Grant with each admitted Node;
- a Peer Grant proves Controller-instance membership, not advisory-lock leadership, so leader-only operations remain gated by Postgres before leaving the Controller;
- each Controller instance owns a durable membership identity, keyed by its certificate identity rather than by a single-row assumption, and a supervised membership owner republishes `last_seen_at` and the Controller's dispatch-capacity capability evidence on every heartbeat; that identity is durable cluster truth and is distinct from transient advisory-lock leadership;
- the membership identity is named by `ORCHARD_CONTROLLER_MEMBERSHIP_HOST` and is independent of the BEAM Peer Grant control listener, so toggling grants cannot move a Controller's durable canonical BEAM name;
- distributed Erlang membership is a high-trust code boundary rather than a per-function capability sandbox;
- node agents are the v1 first-party Runtime Endpoint boundary;
- worker runtimes are local subprocesses, not public services;
- Postgres remains durable truth for inventory, lifecycle state, Runtime Endpoint Observations, scheduling, and request state.

The current packaged multi-Mac first cut remains transitional.
It still uses one manually distributed shared cookie and explicit Controller target entries until the enrolled production Peer Grant path is implemented and passes packaged acceptance.
The source-development shared-cookie model remains separately documented and does not establish production Node identity or authorization.

In the enrolled production model, Postgres stores durable Controller-instance identity and one closed-state Peer Grant record per authorized Controller-to-Node pair.
Node Admission, its decision and audit event, and the initial `pending_delivery` grant records commit atomically before asynchronous certificate-authenticated delivery begins.
Each Controller derives only its own pair secrets from a protected Controller-local BEAM Authorization Root, while Postgres stores the grant scope, lifecycle, and a hash rather than the plaintext secret.
The Node retrieves the grant over certificate-authenticated control traffic, stores it in protected local identity state, and uses it with exact certificate validation to form the TLS distribution connection.
Rotation and revocation deliberately disconnect the old connection because OTP does not expire cookies or terminate established peers when certificate, allowlist, or grant state changes.

BEAM connection failure remains visible and never retries the same Runtime Endpoint operation through gRPC.
The gRPC/mTLS path remains available for enrollment, certificate lifecycle, Peer Grant delivery and recovery, diagnostics, explicit compatibility mode, future external adapters, and operator opt-out.

## Repository map

| Path | Boundary |
|---|---|
| `apps/orchard_controller/` | Controller release: public APIs, Console, Repo, admission, scheduling, dispatch, governance, observability surfaces. |
| `apps/orchard_node_agent/` | Node-agent release: node-local runtime endpoint, model acquisition/cache, worker supervision, status/diagnostics. |
| `apps/orchard_cli/` | `orchardctl` CLI: operator/admin automation for source dev and packaged installs. |
| `apps/orchard_shared/` | Shared generated proto modules, Runtime Endpoint domain structs, helpers, licensing/build metadata. |
| `native/orchard_tokenizer/` | Python helper for prompt rendering, exact token counts, and safe-tokenization support. |
| `native/orchard_worker_mlx/` | Python MLX worker runtime package and node-agent ↔ worker proto. |
| `proto/cluster/v1/` | Controller ↔ node-agent proto source: the current gRPC runtime-operations compatibility transport, the certificate-authenticated BEAM Peer Grant delivery control service, and future-adapter contracts. |
| `packaging/` | `Orchard.app` DMG with app-owned service lifecycle, PKG, launchd, signing/build runbooks. |
| `docs/` | Contributor-facing orientation, tooling, process, design, and durable decisions subordinate to `SPEC.md`. |

Use [`glossary/CONTEXT.md`](glossary/CONTEXT.md) as the shared vocabulary glossary.

## Runtime flow orientation

### Target public inference

This is the full-product target flow.
Current public `/v1/*` routes resolve either a tenant-direct Bearer API Token or a service-account-owned API Token whose API Client has tenant-scoped `inference_client` access.
Some direct internal tests/helpers still keep legacy tenant defaults until full quota policy is complete.

1. Client calls a public `/v1` endpoint on the controller.
2. Controller authenticates, canonicalizes, renders/tokenizes, admits, and
   persists request state.
3. Queue admission grants immediately or waits when lane capacity, live Runtime Endpoint capacity, live requested-model or placement capacity, or tenant active concurrency is exhausted.
4. Scheduler chooses a Runtime Endpoint.
5. Controller dispatches through the Runtime Endpoint Interface.
6. Node agent ensures a worker/model is ready and streams worker events back.
7. Controller relays SSE/JSON to the client and finalizes usage/state.

`/v1/responses` is the target canonical abstraction. `/v1/chat/completions` is
the compatibility facade. See `SPEC.md` §3 and §7 for normative behavior.

### Node and worker runtime

The node agent owns worker subprocess lifecycle. The worker runtime owns local
model loading/generation details. Public clients never talk to workers directly.
Node-agent status is mapped into Runtime Endpoint Observations for aggregate endpoint capacity and loaded-model Placement Capacity, including active requests and max concurrency.
Aggregate capacity is the conservative limit the node agent enforces across loaded workers, while each loaded placement reports its own active count and capacity.
The controller scheduler uses that capacity telemetry to avoid dispatching to full endpoints or full same-model placements.
Controller queue admission also consumes fresh Runtime Endpoint Observations as source-scoped capacity, waking queued loaded-placement or cold/no-placement work only from eligible, non-exhausted endpoints.
Invalid, ineligible, unavailable, or transport-failed observations clear stale endpoint-owned capacity sources before queued work can be promoted.
For BEAM Runtime Endpoint observations, queue capacity is published only when the target resolves back to the same persisted node identity.
Console Nodes live diagnostics probe the configured Runtime Endpoint targets rather than a separate legacy gRPC-only target list.
Scheduler and dispatch orchestration crashes after request validation terminalize the durable request as a failed `orchestration_error` with sanitized public error payloads instead of leaving it active.

Alongside that Node-owned limit, the controller persists its own durable per-Node Controller Dispatch Ceiling and a cluster-wide dispatch-capacity enforcement phase, and evaluates both through one pure shared evaluator.
The evaluator first normalizes the target's Controller-owned capacity management class — admitted inventory always resolves to `production_managed`, and an unmanaged source-development or compatibility class requires explicit configuration — and then returns one authority decision (`legacy_pre_cutover`, `f11_enforcing`, `unmanaged_source_development`, `unmanaged_compatibility`, or `fail_closed`) with that decision's available slots, Placement Capacity, and stable reason codes.
That evaluation is counterfactual today: the phase stays `pre_cutover`, the evaluator feeds diagnostics only, and scheduling, queue admission, and dispatch keep consuming the capacity telemetry described above.
See `SPEC.md` §4.6.2 and `docs/decisions/0013-controller-dispatch-capacity-authority.md` for the target authority boundary.

Runtime Endpoint and worker runtime contracts are separate:

- `proto/cluster/v1/` describes the current controller ↔ node-agent gRPC runtime-operations compatibility transport plus the certificate-authenticated `ControllerPeerGrantService` BEAM Peer Grant delivery control path.
- Runtime Endpoint domain structs describe the Controller-facing scheduler and dispatch contract.
- `Orchard.RuntimeEndpoint.BeamClient` and `Orchard.Node.RuntimeEndpoint` provide the split-role source-dev default first-party BEAM adapter and Node Agent facade.
- `native/orchard_worker_mlx/proto/` describes node-agent ↔ worker messages/services.

### Persistence and coordination

Postgres is the sole persistence and coordination layer. In the target product,
managed Postgres is one supported topology; in the current packaged flow,
controller-bearing installs require operator-provided external Postgres and the
managed Postgres helper remains a guard only.

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
