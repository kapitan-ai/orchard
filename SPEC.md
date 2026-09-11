# Orchard v2 - Technical Specification

This document is the normative implementation spec for Orchard, a sovereign on-prem LLM orchestration platform with a portable Orchard control-plane core and a supported **Apple Silicon macOS** platform profile.
It is intended for a coding agent that will build the system incrementally.
“MUST”, “SHALL”, and “MUST NOT” are mandatory requirements.
“SHOULD” is a strong recommendation.

The Apple Silicon macOS platform profile is the only currently supported platform profile.
Within that profile, the app-installed all-in-one topology and the validated source-development split-role topology are current, while packaged multi-Mac operation remains a first-cut rehearsal path with unresolved production acceptance gaps.
Current Controller-bearing installations require operator-provided external Postgres, Managed Database Mode remains future Milestone 6 work, and Active/Standby operation remains a Milestone 7 target.
The first accepted platform-expansion target is a Linux Controller Host with operator-provided external Postgres dispatching to admitted macOS Apple Silicon Nodes using the MLX runtime provider.
That Linux Controller profile SHALL NOT be represented as supported until the Milestone 8 acceptance contract passes.

Named Console authentication and shared management authorization in §10.11 are an accepted implementation target, not currently implemented behavior or a completed command-family migration.
The current pre-cutover baseline still uses shared Console Basic Auth and anonymous Console audit actors, and the credential family still includes local Controller-runtime CLI authority.
That baseline SHALL remain explicitly distinguished from the target until the implementation, compatibility, and cutover gates in §10.11 pass.

Unless otherwise noted, implementation-facing names in this spec use the Orchard namespace: `Orchard.*` for Elixir modules, `orchard_*` for OTP apps and repositories, `orchard-*` for binaries/daemons, `orchardctl` for the CLI, and `com.orchard.*` for bundle identifiers, launchd labels, and similar platform identifiers. This naming policy does not apply to OpenAI-compatible wire protocol fields, endpoints, event names, or error envelopes, which SHALL remain unchanged for compatibility.

The platform exposes **OpenAI-compatible** inference APIs. Internally, it SHALL treat **`/v1/responses` as the canonical inference abstraction** and implement **`/v1/chat/completions` as a compatibility facade**, because OpenAI currently recommends the Responses API for new projects while keeping Chat Completions supported, and streaming is based on server-sent events. ([OpenAI Developers][1])

---

## 1. System Architecture

### 1.1 Topology contracts and status

Current and accepted deployment modes:

1. **All-in-one single node**

   * current app-installed topology
   * 1 Mac runs:

     * control plane
     * node agent
     * local worker runtime
   * current builds require operator-provided external Postgres
   * Managed Database Mode remains future Milestone 6 work and is not part of the topology identity

2. **Controller + worker nodes**

   * current and validated for source development
   * packaged private-network operation remains a first-cut rehearsal path with unresolved production acceptance gaps
   * 1 Mac runs control plane
   * 1–3 Macs run node agent + local workers
   * current builds require operator-provided external Postgres

3. **Active/Standby control plane target**

   * accepted Milestone 7 design that is not currently operator-usable
   * 2 controller instances maximum
   * exactly 1 active leader at a time
   * remains within the overall 1–4 Mac deployment limit
   * active/standby coordination via Postgres advisory lock
   * requires external VIP, reverse proxy, or operator-managed endpoint failover

Accepted platform-expansion target:

4. **Linux Controller + macOS inference Nodes**

   * 1 Linux Controller Host runs the portable Orchard control-plane core
   * Postgres is operator-provided and external
   * 1–3 admitted Apple Silicon macOS Nodes run Node Agents and MLX Worker Runtimes
   * the Linux Controller Host is not a schedulable Node unless it separately satisfies Node admission and capability requirements
   * final Linux distribution format, host manager, managed Postgres, and Linux accelerator Nodes remain deferred
   * support SHALL NOT be declared before Milestone 8 acceptance completes

### 1.2 Core design rules

* No Kubernetes.
* No active/active controller mode in v1.
* All durable state SHALL live in Postgres.
* The portable Orchard control-plane core SHALL consist of the platform-neutral behavior of `orchard_shared`, `orchard_controller`, `orchard_node_agent`, and portable `orchard_cli`, together with the provider-neutral contracts on which they depend.
* `orchard_shared`, `orchard_controller`, `orchard_node_agent`, and portable `orchard_cli` code SHALL depend only on portable contracts for platform-neutral behavior.
* Platform host adapters, runtime-provider implementations, platform packaging, and vendor SDKs SHALL depend inward on portable contracts and MUST NOT become unconditional compile dependencies of the portable umbrella.
* A Controller Host and a schedulable Node are distinct roles.
* Controller runtime execution SHALL use the Runtime Endpoint Interface.
* Runtime Endpoint semantics are transport-independent.
* The gRPC/protobuf `NodeRuntimeService` remains the compatibility transport and a candidate protocol for future non-BEAM adapters.
* First-party Orchard Controller and Node Agent source-dev services SHALL use BEAM Distribution as the default live Controller-to-Node Agent Runtime Endpoint transport when the endpoint is an admitted first-party Orchard service.
* Source-dev split-role `bin/dev-controller` and `bin/dev-node-agent` SHALL default to BEAM Runtime Endpoint transport when `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` is unset.
* Source-dev gRPC compatibility remains available on port `50071` through explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
* Accepted two-Mac smoke evidence SHALL remain recorded before and after BEAM Runtime Endpoint transport is promoted as the source-dev default.
* When BEAM Runtime Endpoint transport is selected, Orchard MUST NOT retry the same request through gRPC compatibility as an automatic fallback.
* Console live runtime diagnostics SHALL use the configured Runtime Endpoint target list; explicit BEAM Runtime Endpoint targets SHALL take precedence over legacy gRPC runtime client targets.
* Production first-party BEAM Distribution MUST use OTP TLS distribution, exact Node and Controller Certificate validation, trusted inventory, and an active Controller-to-Node BEAM Peer Grant.
* A Node Certificate is the durable Node identity anchor; a BEAM Peer Grant is bounded transport authorization and MUST NOT be treated as Node identity.
* Production BEAM MUST NOT use one shared cluster cookie as identity or authorization.
* Production BEAM MUST be explicitly enabled, network-restricted, limited to admitted first-party Orchard services, and fail closed when certificate, inventory, Peer Grant, or admission state is missing or invalid.
* BEAM Runtime Endpoint targets MUST carry a valid BEAM node-name address (`service@host`) as an atom or binary; a configured `node_id`, when present, MUST be a UUID and MUST match observed endpoint metadata before scheduler or dispatch may trust that candidate identity.
* External Runtime Endpoints MUST NOT join the first-party BEAM mesh.
* All public API traffic SHALL terminate at the controller.
* Token streams SHALL always pass through the controller so governance, accounting, cancellation, and audit behavior are centralized.
* Node agents SHALL be the only network-reachable component on worker nodes.
* Local worker runtimes SHALL never be exposed directly on the LAN/WAN.

### 1.3 Architecture diagram

```text
                         +----------------------+
                         |  Public Clients      |
                         |  SDKs / curl / apps  |
                         +----------+-----------+
                                    |
                           HTTPS / SSE / JSON
                                    |
                     +--------------v----------------+
                     |  Controller (Elixir/OTP)      |
                     |  macOS now; Linux target     |
                     |  - Public Inference API       |
                     |  - Operator API               |
                     |  - Admin API                  |
                     |  - Auth/RBAC                  |
                     |  - Admission                  |
                     |  - Scheduler                  |
                     |  - Dispatch                   |
                     |  - Request FSMs               |
                     |  - Metrics/Tracing/Logs       |
                     +---------+-----------+-------------------+
                               |           |
                        SQL / TLS          Runtime Endpoint Interface
                               |           |
                     +---------v--+   +---v---------------------------+
                     | Postgres    |   | Runtime Endpoint Adapter(s) |
                     | durable DB  |   | - first-party BEAM          |
                     +------------ +   | - gRPC compatibility        |
                                       | - future external/provider  |
                                       +---+-------------------------+
                                           |
                                           | v1 first-party endpoint
                                           |
                                       +---v--------------------+
                                       | Node Agent(s)         |
                                       | - Register/Heartbeat  |
                                       | - Model cache         |
                                       | - Worker supervisor   |
                                       | - Diagnostics         |
                                       +---+-------------------+
                                           |
                                     UDS / local gRPC
                                           |
                                 +---------v-----------+
                                 | Worker Runtime      |
                                 | MLX / compatible    |
                                 | streams token deltas|
                                 +---------------------+
```

### 1.4 Qualified profiles and portable assumptions

Orchard SHALL use qualified, composable profile kinds so platform support, distribution, runtime-provider support, and cross-platform acceptance remain distinct.

* A **platform profile** binds Orchard host roles to a specified operating system, architecture, and platform acceptance evidence.
* A **distribution profile** binds a platform profile and install roles to deployment artifacts, host lifecycle, paths, credential storage, update and rollback behavior, retained state, and release evidence.
* A **runtime-provider profile** binds a Node role to a Worker Runtime provider, compatible acceleration and device resources, provider-neutral conformance, and real-runtime acceptance.
* An **acceptance profile** defines a named topology and the evidence required to prove its participating profiles operate together.

A host-lifecycle adapter is a platform integration boundary, not a profile.
A deployment artifact is a produced distribution input or output, not a profile.
Profile-specific requirements MUST NOT be treated as requirements of every Controller Host, Node, distribution, or runtime provider.
Defining or accepting a profile does not declare it supported; a support claim requires its applicable acceptance evidence and gates to pass.

The current Apple Silicon macOS platform profile SHALL preserve the accepted Controller and Node behavior of the all-in-one and split-role topologies at their documented support status.
The macOS native distribution profile SHALL use `Orchard.app` inside a DMG and SHALL preserve launchd, Keychain, app-owned lifecycle, rollback, retained-state, signing, notarization, and stapling requirements.
The macOS MLX Node runtime profile SHALL qualify a Node role that pairs the portable Node Agent with Apple Silicon, Metal, the MLX-LM runtime provider, the tokenizer stack, provider-neutral conformance, and real MLX runtime acceptance.
The Node Agent SHALL remain part of the portable Orchard control-plane core and MUST NOT become provider-specific through a runtime-provider profile.
Managed local Postgres mode SHALL remain target behavior of the macOS native distribution profile using Apple Silicon-compatible local containerization, with Apple’s Containerization project or the open-source `container` implementation as the supported local runtime path.
Managed local Postgres mode is unavailable in current builds and remains future Milestone 6 work.
Apple documents launchd as the system service manager for daemons and agents, and its Containerization project as a macOS Linux-container runtime built on Apple Silicon virtualization. ([Apple Support][2])

The accepted Linux Controller profile is a platform profile for the Controller role.
It SHALL use operator-provided external Postgres and SHALL NOT require a local Node Agent, accelerator runtime, Apple tooling, launchd, Keychain, DMG, or Orchard.app.
Its final distribution format and host manager remain deferred.
No Linux support claim follows from portable compilation alone.

The mixed-platform acceptance profile SHALL prove a portable Controller, including the Linux Controller profile, operating admitted macOS Nodes that satisfy the macOS MLX Node runtime profile.
Passing that acceptance profile is required before the Linux Controller profile is declared supported and does not turn a Controller Host into a schedulable Node.

### 1.5 First-class runtime

The required v1 macOS worker runtime is **MLX-based**.
The default macOS runtime provider SHALL target **MLX-LM**.
MLX is specifically built for Apple Silicon, and MLX-LM provides text generation on Apple Silicon. ([GitHub][3])

Orchard SHALL distinguish these concepts:

* **artifact format**: the model artifact representation, such as GGUF or SafeTensors
* **runtime provider**: the Worker Runtime implementation, such as MLX-LM or a future provider
* **acceleration implementation**: the execution technology, such as Metal, CUDA, ROCm, or CPU
* **device resource**: a versioned device identity, topology, memory domain, and allocatable capacity

Portable policy and scheduling MUST NOT infer one concept from another or use operating-system and provider names as capability proof.
Additional runtime providers require their own runtime-provider profile with provider-neutral conformance and applicable real-runtime acceptance before support is claimed.

### 1.6 Non-goals for v1

* Kubernetes integration
* cross-node tensor parallelism
* embeddings/audio/vision APIs
* generic hosted compute, arbitrary code execution, or controller-hosted execution of client-supplied tools
* internet-dependent control plane behavior
* dynamic autoscaling
* active/active multi-controller consensus

Base v1 tool calling SHALL remain **request-scoped function-tool passthrough**. When tool calls are produced, Orchard SHALL return them to the client rather than executing inline request tools on the platform.

Server-side tool execution MAY be added in a later phased extension. In that mode, the controller SHALL resolve approved tools, apply policy and loop limits, and schedule execution on nodes that explicitly advertise the required tool capability. Nodes SHALL execute bounded tool adapters locally and return results to the controller. Orchard SHALL remain an orchestration and governance layer, not a general-purpose remote compute runtime.

---

## 2. Component Overview

### 2.1 Controller components

| Component           | Process type         | Responsibility                                               |
| ------------------- | -------------------- | ------------------------------------------------------------ |
| `orchard-controller`    | OTP release; launchd in macOS native distribution profile | Main control plane daemon                     |
| `Orchard.API`           | OTP app              | HTTP API surface: `/v1`, `/ops/v1`, `/admin/v1`              |
| `Orchard.Auth`          | OTP app              | API key auth, service account auth, RBAC                     |
| `Orchard.Admission`     | OTP app              | validation, tenant policy, quotas, idempotency               |
| `Orchard.Scheduler`     | OTP app              | Runtime Endpoint selection, queueing, fairness, placement decisions |
| `Orchard.Dispatch`      | OTP app              | Runtime Endpoint operations, compatibility dispatch, stream fan-out to clients |
| `Orchard.Catalog`       | OTP app              | model catalog, artifact manifests, routing policy resolution |
| `Orchard.Nodes`         | OTP app              | node registry, lifecycle, heartbeat snapshots                |
| `Orchard.Requests`      | OTP app              | per-request FSMs and request event logging                   |
| `Orchard.Observability` | OTP app              | metrics, traces, logs                                        |
| `Orchard.Governance`    | OTP app              | tenants, API Clients, API Tokens, quotas, role bindings, audit logs |

### 2.2 Node-side components

| Component               | Process type         | Responsibility                                   |
| ----------------------- | -------------------- | ------------------------------------------------ |
| `orchard-node-agent`        | OTP release; launchd in macOS native distribution profile | Node control endpoint             |
| `Orchard.Node.Register`      | OTP app              | join, cert renewal, heartbeat                    |
| `Orchard.Node.Models`        | OTP app              | artifact cache, verification, load/unload        |
| `Orchard.Node.Workers`       | OTP app              | worker supervisor, crash recovery                |
| `Orchard.Node.Diagnostics`   | OTP app              | health and support data                          |
| `orchard-worker-supervisor` | spawned child        | manages one or more worker runtime processes     |
| `orchard-worker-mlx`        | spawned child        | MLX runtime server for one loaded model instance |

### 2.3 End-user and operator components

| Component               | Packaging                    | Responsibility                                             |
| ----------------------- | ---------------------------- | ---------------------------------------------------------- |
| Tray/menu bar app       | macOS `.app` + LaunchAgent   | local status, onboarding, and logs                         |
| `orchardctl` CLI            | binary                       | admin/operator automation, bootstrap, diagnostics          |
| Orchard Console         | controller LiveView          | local/operator UI for runtime status, node inventory and admission review, action previews, requests, Workspaces, API Tokens, and API Clients |
| Developer Portal        | controller LiveView          | Invite-only, Workspace-scoped self-service mint, list, and revoke of a Portal User's tenant-direct API Keys |
| Managed Postgres helper | LaunchDaemon in managed mode | local DB lifecycle only                                    |

Workspace SHALL be the product-facing name for one existing Tenant governance boundary in Console and Developer Portal.
Access SHALL be the Console navigation destination for Workspace management; it SHALL NOT imply a new cluster-wide RBAC role or hierarchy.
Tenant schemas, UUIDs, slugs, API fields, CLI vocabulary, audit identifiers, CSV `organization`, and `/portal/:organization_slug` URLs SHALL remain compatible.
Existing `/console/tenants` and `/console/tenants/:id` links SHALL remain usable alongside canonical `/console/access` and `/console/access/workspaces/:id` routes.
Team SHALL remain API Client grouping metadata, without membership, authorization, model grants, or quotas.

The accepted Console target SHALL authenticate a named Console Identity through a revocable Console Session under §10.11.
Console Identity, non-interactive API Client, and Workspace-scoped Portal User SHALL remain distinct principals even when descriptive metadata matches.

The seeded Tenant `00000000-0000-0000-0000-000000000000` SHALL be the default Workspace.
Its untouched built-in name `Legacy Single Tenant` SHALL display as `Default workspace`; a customized name SHALL be preserved and the stable default identity indicated separately.
Default identity SHALL be determined by UUID, not by name or slug.
When it is the only Workspace, a new guided colleague handoff SHALL start within that scope with the Workspace step visibly resolved.
Multiple Workspaces SHALL require deliberate selection for a new handoff, and an explicit Workspace route or scoped draft SHALL NOT be overwritten by default selection.
Default selection SHALL NOT create model grants, Portal Users, credentials, quota exemptions, or runtime readiness.
Page reads SHALL NOT create a replacement seed or reset existing state; a missing or unreadable seed SHALL produce a recoverable setup error.

### 2.4 Repository structure

The implementation SHOULD use an umbrella repository with separate Elixir releases:

```text
/apps
  /orchard_shared        # protobufs, common structs, config parsing
  /orchard_controller    # controller release
  /orchard_node_agent    # node agent release
  /orchard_cli           # CLI
/native
  /orchard_worker_mlx    # macOS MLX runtime-provider implementation
  /orchard_tokenizer     # tokenizer/render helper
/proto
  cluster/v1/*.proto
  orchard/worker/v1/*.proto  # target provider-neutral Worker Runtime ownership
/packaging
  app/
  dmg/
  launchd/
  container/
  payload/                 # shared distribution-neutral payload assets consumed by Orchard.app and the DMG
```

### 2.5 Process boundaries

* Controller and node agent SHALL be separate releases.
* Controller MAY run on a node that also runs a node agent.
* Worker runtimes SHALL be subprocesses supervised by node agent, not permanent launchd services.
* Tokenization/rendering helper MAY be a bundled native or Python helper, but the controller API layer remains Elixir/OTP.
* Controller-owned durable operations SHALL execute inside the active Controller through authenticated, authorized, leader-aware, and audited domain operations.
* Portable CLI code SHALL own client interaction and presentation, not direct Repo authority or host lifecycle mechanics.
* Platform-specific host lifecycle behavior SHALL remain isolated behind host adapters and SHALL NOT become a portable Orchard control-plane core dependency.

---

## 3. Control Plane Design

### 3.1 Controller runtime model

The controller SHALL be a Phoenix/Plug HTTP service plus Runtime Endpoint clients and the configured internal service ingress for node lifecycle and compatibility transports.

**Required listeners**

* Public/admin/operator API listener according to the configured public transport mode (§10.7):
  * `direct_https`: controller terminates HTTPS, default `:8443`.
  * `reverse_proxy`: controller provides a local/private HTTP backend for an operator-managed TLS-terminating proxy.
  * `plain_http_localhost`: controller provides loopback HTTP only for local development or break-glass recovery.
* `:8444` gRPC/mTLS for node registration/heartbeat/event ingress while the compatibility transport remains enabled

Prometheus metrics are served on the public/admin/operator API listener above; the controller SHALL NOT create a separate metrics listener (§9.1).

**Required readiness conditions**

* Postgres reachable
* migrations current
* model/tenant/key caches loaded
* if Active/Standby mode enabled: instance is leader for write paths

**Health exposure contract**

* Unauthenticated `GET /health/live` SHALL return HTTP `200` with exactly
  `{"status":"ok"}`.
* Unauthenticated `GET /health/ready` SHALL return HTTP `200` with exactly
  `{"status":"ok"}` when the active readiness predicate passes, or HTTP `503`
  with exactly `{"status":"error"}` when it fails.
* Public health responses SHALL NOT include checks, reasons, remediation, version,
  build, transport, Console, runtime, tenant, or user details.
* Detailed diagnostics SHALL be available only through authenticated Operator
  `GET /ops/v1/health` using the cluster-scoped Operator-or-admin authorization
  boundary. The response SHALL include `Cache-Control: no-store`, identify its
  readiness contract, and may include sanitized checks, reasons, remediation,
  build, transport, Console, and runtime observations.
* Until authoritative cache-loaded and conditional leadership sources exist, the
  implementation MAY temporarily use the unchanged M0-era predicate identified as
  `orchard.readiness.legacy_m0.v1`. This staged predicate does not satisfy or claim
  the complete readiness conditions above. It SHALL expose its identifier and
  ordered check keys through authenticated Operator health only.
* The later complete aggregate SHALL replace the staged predicate without constants,
  configuration flags, readiness-only caches, unrelated caches, or other shims for
  missing authorities. Detailed unauthenticated health SHALL NOT be restored.

### 3.2 OTP supervision tree

```text
Orchard.Application
├─ Orchard.Repo
├─ Orchard.CacheSupervisor
│  ├─ Orchard.Cache.ApiKeys
│  ├─ Orchard.Cache.Models
│  ├─ Orchard.Cache.Tenants
│  └─ Orchard.Cache.NodeSnapshots
├─ Orchard.API.Endpoint
├─ Orchard.RPC.ControllerServer
├─ Orchard.RPC.NodeClientPool
├─ Orchard.DispatchCapacity.QuarantineStore
├─ Orchard.Inference                                  # rest_for_one
│  ├─ Orchard.Requests.Registry
│  ├─ Orchard.DispatchCapacity.AllocationAuthority
│  ├─ Orchard.Requests.Supervisor
│  └─ Orchard.Inference.QueueManager
├─ Orchard.Scheduler.Supervisor
│  ├─ Orchard.Scheduler.Dispatcher
│  └─ Orchard.Scheduler.PlacementReconciler
├─ Orchard.NodeSupervisor
├─ Orchard.AuditSupervisor
├─ Orchard.Observability.Supervisor
└─ Orchard.LeaderTasks
   ├─ Orchard.Leader.LockManager
   ├─ Orchard.Leader.RetentionSweeper
   └─ Orchard.Leader.QuotaSweeper
```

The inference subtree SHALL start `Orchard.DispatchCapacity.AllocationAuthority` ahead of the request supervisor and queue manager under a `rest_for_one` strategy, so losing the Controller allocation authority also restarts the processes whose dispatch claims it tracked instead of leaving orphaned claims behind.
`Orchard.DispatchCapacity.QuarantineStore` SHALL be supervised by the Controller root ahead of that subtree so an allocation authority restart cannot resume dispatch from a clean quarantine set, as required by §4.6.2.

### 3.3 Controller leadership

The controller SHALL support:

* **single-controller mode**: one instance, always leader
* **Active/Standby mode**: up to two controller instances, one leader

Leader election SHALL use a **Postgres advisory lock**. Advisory locks are application-defined and support transaction/session scoping, which is sufficient for exclusive scheduler and migration ownership in this design. ([PostgreSQL][4])

**Lock responsibilities**

* scheduler ownership
* queue dispatch ownership
* placement reconciliation ownership
* migration ownership
* retention sweeper ownership

Standby controller behavior:

* MAY serve `GET /health/live`
* SHALL return `503 controller_standby` for write paths if directly addressed
* SHALL not schedule, dispatch, or mutate cluster runtime state

Each single-controller or Active/Standby Controller instance SHALL have a durable Controller-instance record containing:

* stable `controller_id` UUID
* Controller Certificate URI SAN, certificate identifier, and fingerprint
* canonical production Controller BEAM node name
* BEAM Authorization Root custody reference, never the root value
* instance status
* first-enrolled and last-seen timestamps
* running Orchard version
* supported dispatch-capacity contract version, indivisible all-consumers-ready declaration, and capability observation timestamp

Controller-instance identity is durable cluster truth.
Advisory-lock leadership is transient and SHALL NOT be conflated with Controller-instance identity.

Every non-retired Controller instance SHALL atomically publish its running Orchard version, supported dispatch-capacity contract version, `dispatch_capacity_consumers_ready`, and capability observation timestamp at boot and on each Controller membership heartbeat.
The supervised `Orchard.ControllerInstances.MembershipOwner` SHALL emit that heartbeat every `10000` ms and update `last_seen_at` plus the complete capability tuple in one write.
Heartbeat failure SHALL be retried without reporting fresh capability evidence, and evidence older than the freshness threshold SHALL remain stale until a successful complete write.
`dispatch_capacity_consumers_ready = true` SHALL declare that MultiNode, admitted SingleNode, Node queue-source refresh, QueueManager, and dispatch-time revalidation all use the shared evaluation as one indivisible contract-versioned capability.
For F11, Controller capability is compatible only when `dispatch_capacity_contract_version` exactly equals the locked singleton row's `required_contract_version` and `dispatch_capacity_consumers_ready` is true.
Supporting multiple contract versions in one Controller requires a future explicit supported-version-set contract and SHALL NOT be inferred from greater-than-or-equal comparison.
Missing evidence, version `0`, a false readiness declaration, or evidence older than `controller_capability_freshness_threshold_ms` SHALL block enforcement cutover for any non-retired Controller instance.
The default Controller capability freshness threshold SHALL be `30000` ms.
An obsolete or permanently unavailable Controller SHALL be explicitly retired through `POST /ops/v1/controllers/:controller_id/retire` before it can be excluded from cutover preflight.

Leader controller behavior:

* A configured Active/Standby leader that cannot prove current advisory-lock ownership — leadership evidence unavailable, the lock not held, or the lock held by another controller identity — SHALL fail closed on write paths with `503 controller_leadership_unproven`, a reason distinct from `controller_standby`.
* Single-controller deployments are unaffected.

### 3.4 Canonical request model

All public inference requests SHALL normalize into one internal struct:

```elixir
%CanonicalRequest{
  internal_id: UUID,
  public_id: String.t(),
  endpoint: :chat_completions | :responses,
  tenant_id: UUID,
  principal_type: :tenant | :service_account,
  principal_id: UUID | nil,
  service_account_id: UUID | nil,
  api_key_id: UUID | nil,
  model_ref: %{
    model_id: String.t(),
    version: String.t()
  },
  input_items: [map()],
  rendered_prompt: binary() | nil,
  input_token_count: non_neg_integer(),
  store?: boolean(),
  stream?: boolean(),
  sampling: %{
    temperature: float(),
    top_p: float(),
    max_output_tokens: pos_integer(),
    stop: [String.t()],
    seed: integer() | nil
  },
  response_format: %{
    type: :text | :json_object
  },
  reasoning: %{
    generation_policy: :model_default | :disabled | :enabled,
    projection: :legacy_blended | :final_only | :reasoning_structured,
    source: :omitted_public | :explicit_public | :console_default | :console_explicit,
    effective_contract:
      %{mode: :legacy}
      | %{
          mode: :negotiated,
          model_artifact_digest: String.t(),
          chat_template_digest: String.t(),
          render_contract: String.t(),
          render_contract_version: String.t(),
          parser_family: String.t(),
          parser_version: String.t(),
          runtime_contract_version: String.t(),
          event_binding_version: String.t()
        }
  },
  tooling: %{
    tools: [map()],
    requested_tools: [map()],
    tool_choice: map() | String.t() | nil,
    registry_snapshot: %{
      entries: [map()]
    },
    execution_snapshot: %{
      entries: [map()]
    }
  },
  metadata: map(),
  admission: %{
    timeout_ms: pos_integer(),
    queue_wait_ms: pos_integer(),
    max_cold_start_ms: pos_integer()
  },
  resolved_policy: %{
    quota_id: UUID | nil,
    routing_policy_id: UUID | nil,
    allowed_pool_ids: [UUID],
    max_active_requests: pos_integer() | nil,
    residency_preference: :required_loaded | :prefer_loaded | :allow_cold_load
  }
}
```

Reasoning generation and public projection are independent canonical axes.
`generation_policy` controls whether the selected model is allowed to use its template-owned default, is required not to generate reasoning, or is required to generate reasoning.
`projection` controls whether decoded output remains one legacy blended text channel, exposes final answer text only, or selects structured reasoning as public output in addition to final answer text.
The Controller SHALL preserve the policy source and resolve the complete effective contract before dispatch.
The effective contract SHALL remain pinned for every attempt of the logical Request and SHALL NOT be inferred again after scheduling.
The Controller MUST NOT derive either axis from the other.
The outer `generation_policy` and `projection` fields are the sole authority for those axes and MUST NOT be duplicated inside `effective_contract`.
An omitted legacy Request SHALL use exactly `%{mode: :legacy}` and SHALL retain no nullable negotiated identity fields.
An explicit negotiated Request SHALL use `mode = negotiated` and SHALL carry every listed identity field as a non-empty value.
Missing or nullable negotiated identity SHALL fail validation before scheduling.
Because §5.6 restricts a negotiated Request to already loaded Tier 0 candidates, `resolved_policy.residency_preference` and `admission.max_cold_start_ms` SHALL NOT apply to its candidate selection.
An `allow_cold_load` or `prefer_loaded` policy SHALL NOT admit a cold or cached candidate for it, and a `required_loaded` policy SHALL NOT narrow it further.
Its `timeout_at` SHALL therefore resolve through §12.4's loaded-only formula for every resolved `residency_preference`, so a cold-start budget becomes neither a selection input nor deadline headroom.

The currently valid source, generation, and projection combinations are closed:

* `omitted_public` requires `model_default + legacy_blended`
* `console_default` requires `disabled + final_only`
* `console_explicit` may select `model_default`, `disabled`, or `enabled` only with `final_only`
* `explicit_public` may select `model_default`, `disabled`, or `enabled` only with `final_only`, and only after the concrete public input contract is accepted
* `reasoning_structured` remains unavailable until its separate public contract expands this matrix

Every other combination SHALL fail before the first Request write and MUST NOT reach scheduling or dispatch.

When both Chat Completions and Responses omit reasoning control, Orchard SHALL normalize the Request to `generation_policy = model_default`, `projection = legacy_blended`, and `source = omitted_public`.
That omitted mode SHALL preserve the complete current legacy pipeline, including template rendering, Worker Runtime text processing, tool classification, stop-sequence behavior, Output Commitment, public blended output, capture, hashing, and replay.
An omitted control MUST NOT silently enter the negotiated reasoning pipeline merely because a model, template, tokenizer, Worker Runtime, or Runtime Endpoint advertises reasoning support.
For an omitted public control, the `body_hash` domain SHALL remain the exact pre-reasoning-control domain.
The synthesized reasoning defaults and `%{mode: :legacy}` marker MUST NOT be added to that hash input, so an otherwise identical public body retains its existing idempotency and integrity identity.
An accepted explicit public control remains part of the normalized public request body and therefore participates in the existing public-body idempotency hash.

Ordinary assistant input content is opaque caller-authored content.
Orchard MUST NOT infer, strip, restore, or promote prior reasoning from ordinary assistant text.
Explicit structured prior-reasoning input is unsupported in the first reasoning-control release and SHALL fail request validation rather than being silently flattened or re-fed.

Tooling contract rules:

* request `tools` entries MAY be inline function definitions or registry refs of the form `tool://<name>@<version>`
* when present, an inline function definition's `parameters` field SHALL be a JSON object; non-object schema values SHALL fail request validation before model lookup, tokenization, scheduling, or dispatch
* `tooling.requested_tools` SHALL preserve the normalized request `tools` array in original order
* `tooling.tools` SHALL contain only controller-resolved runtime-ready tool definitions; registry ref placeholders SHALL NOT be forwarded past request preparation
* `tooling.registry_snapshot.entries` SHALL capture controller-side registry provenance for ref-backed tools only and SHALL be empty when no registry refs were requested
* `tooling.execution_snapshot.entries` SHALL capture controller-owned admission-time execution semantics for every effective tool and SHALL be empty when no effective tools were admitted
* provenance SHALL be read from `tooling.registry_snapshot`; execution eligibility metadata and current admission ownership SHALL be read from `tooling.execution_snapshot`; neither SHALL be inferred from the other
* base v1 tool calling SHALL remain client-executed passthrough; `tooling.execution_snapshot` documents the admission decision and future eligibility metadata only and SHALL NOT by itself enable server-side execution
* absent `tools` and `requested_tools` SHALL normalize to empty arrays; absent `tool_choice` SHALL normalize to `null`; absent `registry_snapshot` SHALL normalize to `%{entries: []}`; absent `execution_snapshot` SHALL normalize to `%{entries: []}`

### 3.5 Prompt rendering and tokenization

The controller SHALL perform **exact prompt rendering and exact token counting before scheduling**.

Implementation requirement:

* bundle a helper executable `orchard-tokenizer`
* it MUST support:

  * tokenizer.json
  * SentencePiece tokenizer.model
  * chat template rendering
  * token count for final rendered prompt

Tokenizer contract v2 requirements:

* the controller SHALL pass tool context into prompt rendering when a request includes tool configuration
* registry-backed tool refs SHALL be resolved by the controller before prompt rendering
* the render payload SHALL include:

  * `tools` as the ordered array of resolved effective tool definitions
  * `tool_choice` as `null`, a string mode, or a named-function object

* absent `tools` SHALL be represented as an empty array
* absent `tool_choice` SHALL be represented as `null`
* token counting SHALL apply to the final rendered prompt after any tool-aware template expansion
* tokenizer modes that cannot represent tool context SHALL reject tool-calling requests rather than silently dropping tool metadata

Tokenizer contract v3 adds controller-authoritative prompt token IDs for safe-tokenization-capable workers. When controller safe tokenization produces `prompt_token_ids`, capable workers must use those IDs directly rather than re-encoding rendered prompt text. Manifest compatibility trust remains governed by §6.4 and the runtime manifest-trust configuration; worker capability is advertised by the worker, not by the manifest.

For contract-v3 segmented rendering, assistant tool-call history arguments SHALL be decoded from public JSON strings into argument objects before chat-template rendering.
Malformed, non-object, duplicate-key, or non-finite arguments SHALL fail before inference.
Caller-string tagging SHALL operate on the normalized argument object, protecting recursive object keys and string values while preserving JSON scalar types and the dual-render compatibility check.
Assistant tool-call history MAY omit content or supply null when it contains a nonempty list of valid function calls; segmented rendering SHALL normalize that absent text to an empty string.
Exactly empty caller strings SHALL remain empty without markers because they contain no caller bytes.
Every nonempty caller string SHALL retain ordinary markers enclosing all original bytes, including leading and trailing whitespace, in raw and JSON rendering.
Trimming a tagged string SHALL operate on the original caller value and retain markers around any nonempty result; only an empty result MAY omit markers.
Text-part lists SHALL be concatenated before caller tagging so trimming preserves the combined text's internal whitespace.
Segmented rendering SHALL restrict operations on marker-bearing values to an explicitly audited subset: whole-value rendering and traversal, original-value trimming, serialization, concatenation, observations, and the literal replacements `-` to `_`, space to `_`, and `$` to empty used by the qualified template.
Serialization, concatenation, and those replacements SHALL preserve registered marker identities, multiplicity, balanced spans, and caller containment before returning their results.
Unsupported caller-string transformations, character indexing, slicing, iteration, and unpacking SHALL fail closed before exposing unprotected fragments, including after coercion or serialization.
Templates MAY omit whole caller values, and one empty trim SHALL NOT remove protection from other uses of its original value.
All nonempty caller strings SHALL remain tagged, and the dual-render check remains mandatory; incompatible transformations SHALL fail closed.
A request-dependent render or decode failure SHALL fail that request without writing a bundle-wide incompatibility cache entry.
Only validated deterministic tokenizer or sentinel-preflight incompatibilities MAY populate the negative compatibility cache.
Runtime helper errors SHALL identify request, artifact-preflight, or artifact-tokenizer evaluation scope; cache admission requires explicit artifact scope, matching inner and outer error categories, and structurally valid deterministic evidence.
Unscoped runtime errors SHALL remain request-local for compatibility with older helpers.

For any explicitly negotiated reasoning mode, the Controller SHALL own typed generation policy, projection, parser-family selection, and version selection.
The public API MUST NOT accept arbitrary chat-template keyword arguments.
The tokenizer SHALL map the typed generation policy through a closed contract for the exact model artifact and chat-template digest.
The tokenizer SHALL return effective render metadata sufficient for the Controller to prove the generation policy, projection, exact model artifact digest, chat-template digest, render contract and version, parser family and version, runtime contract version, and policy provenance used for that Request.
The Controller SHALL reject an explicit reasoning control before dispatch when the exact model and template contract cannot honor it.
The Controller MUST NOT guess support from a model name, family-name substring, unversioned parser heuristic, or unqualified template inspection.
`model_default` in omitted legacy mode means the existing template behavior and MUST NOT be rewritten into an explicit enabled or disabled template argument.

Safe-tokenization caller-string segmentation SHALL protect free-form caller-authored prompt material, including message content text, multimodal text parts, message names, tool descriptions, tool schema strings, tool call identifiers, function names, function arguments, and named tool-choice fields. Fixed protocol role values (`system`, `developer`, `user`, `assistant`, `tool`) SHALL remain unwrapped during marker-based dual rendering because chat templates commonly use roles for control flow; roles are validated request metadata rather than free-form prompt text. This role exemption MUST NOT exempt message content or tool/schema text from control-token detection.

The controller-side chat-template renderer SHALL support Hugging Face's standard chat-template globals used by tokenizer templates, including `raise_exception(message)` and `strftime_now(format_string)`, so compatibility decisions reflect template semantics rather than missing helper globals.

Tokenizer observability includes `[:orchard, :tokenizer, :prompt_token_ids_dispatched]` when capable workers receive controller-supplied IDs, `[:orchard, :tokenizer, :unsafe_mode_active]` when safe-mode falls back to legacy rendered-prompt dispatch, and `[:orchard, :tokenizer, :parity_drift]` when a capable worker rejects controller-supplied `prompt_token_ids` with `prompt_token_ids_length_mismatch`. The parity-drift event is an operator-visible invariant breach counter; it is emitted only for worker stream failures, not controller-synthesized timeout or cancellation failures.

When `tokenizer_safe_mode_prefer_capable` is enabled and `tokenizer_safe_mode` is not `:off`, the multi-node scheduler MAY prefer Runtime Endpoints whose live Runtime Endpoint Observation reports `supports_prompt_token_ids = true`.
This preference is a scheduler tie-breaker only; it is not dispatch authority and MUST NOT replace the per-request Runtime Endpoint ensure-model-loaded result gate.

Console Live Cluster diagnostics SHALL surface the latest observed live prompt-token-ID support value per reachable Runtime Endpoint target so operators can assess mixed-version safe-tokenization risk; absence or `false` is rendered as legacy capability, not as a probe failure.

Console diagnostics SHALL surface observe-only, process-local safe-tokenization counters aggregated since counter process start (`control_token_in_user_content`, `detector_error`, `prompt_token_ids_dispatched` event count and accumulated token count, `unsafe_mode_active`, `parity_drift`, `catalog_drift`, and `safe_tokenization.degraded_no_manifest_catalog`). Counter values reset on counter process restart and MUST NOT influence scheduling, dispatch, admission, or readiness.

The controller SHALL also emit `[:orchard, :tokenizer, :catalog_drift]` when the live request-time partial control-token catalog derived from `tokenizer.json.added_tokens` entries with `special=true`, tokenizer-config named singleton tokens, and `tokenizer_config.json.additional_special_tokens` contains entries absent from `manifest.safe_tokenization.control_tokens`. This signal is one-directional (`added` drift only) and partial: it MUST NOT emit `removed` entries, and it does not detect manifest entries removed from the live artifacts, non-special `added_tokens`, chat-template-literal drift, or wrapper-tool-marker drift.

The controller SHALL reject requests when:

* `input_tokens + max_output_tokens > model.max_context_tokens`
* request contains unsupported message/item types
* tokenizer assets for the selected model are missing or invalid
* tokenizer prompt rendering cannot honor the request's tool configuration

### 3.6 Request FSM

Each active request SHALL be represented by a `:gen_statem` request process with the following states:

```text
received
  -> validated
  -> admitted
  -> queued
  -> scheduled
  -> dispatching
  -> running
  -> streaming
  -> completed

bounded Automatic Attempt Retry edge:
  running -> dispatching

failure exits:
  -> failed
  -> cancelled
  -> timed_out
  -> interrupted
```

Rules:

* `running` means node accepted and worker prefill began
* `streaming` means Output Commitment has occurred through a validated selected public reasoning, final-text, tool-call, or structured-output delta
* one coarse Request FSM SHALL span both Inference Attempts of one logical Request; Automatic Attempt Retry SHALL NOT add a retry-specific state
* a Request whose attempt 1 has not reached `running` SHALL remain in `dispatching` through attempt 1 resolution, the retry decision, alternate scheduling, and attempt 2's dispatch sequence
* a Request whose attempt 1 reached `running` SHALL remain in `running` through attempt 1 resolution, the retry decision, and alternate scheduling, and SHALL take the `running -> dispatching` edge exactly once at the atomic attempt 2 start boundary in §5.8; this is the only backward edge in this FSM and it SHALL NOT be taken after Output Commitment
* a declined retry SHALL take no backward edge and SHALL terminalize from the state attempt 1 already held, so `no_alternative_node`, `cancelled`, and `budget_exhausted` outcomes never move the Request backward
* attempt 2 SHALL NOT re-enter `received`, `validated`, `admitted`, `queued`, or `scheduled`, and the Request SHALL terminalize exactly once from its final attempt
* `interrupted` is used for controller/process failure after dispatch but before terminal reconciliation
* once a request row has reached `validated`, scheduler or dispatch orchestration crashes MUST terminalize it as `failed` with durable `error_code = "orchestration_error"` and a sanitized public `internal_error`
* once terminal, state is immutable

### 3.7 Durable-state write rules

The controller SHALL persist:

* node inventory
* node lifecycle state
* heartbeats
* model catalog and placements
* tenants / keys / quotas / routing policies
* requests
* request lifecycle events
* audit logs

The controller SHALL NOT rely on in-memory state for correctness after restart. ETS caches are acceleration only.

### 3.7.1 Request-step durable contract

Request-step persistence SHALL remain layered on `request_events` for the first hosted-execution prerequisite slice. The controller SHALL NOT introduce a separate `request_steps` table unless later implementation evidence proves `request_events` insufficient.

Reserved request-step `event_type` values are:

* `request_step.started`
* `request_step.proposed`
* `request_step.completed`
* `request_step.failed`
* `request_step.cancelled`
* `request_step.timed_out`
* `request_step.interrupted`
* `request_step.indeterminate`

Request-step rows SHALL always persist with `state = null`. They SHALL NOT mutate `requests.state`; coarse request lifecycle state remains owned by the request FSM and its existing lifecycle events.

Supported `step_type` values are:

* `inference_turn`
* `tool_call`
* `tool_execution`

Boundary vocabulary is:

* `pre_side_effect`
* `post_observation`

Boundary rules:

* `request_step.started` SHALL use `pre_side_effect`
* all other `request_step.*` events SHALL use `post_observation`

Deterministic step identifiers SHALL use these formats:

* inference turn: `inference_turn:t{turn_index}:a{attempt}`
* tool call proposal: `tool_call:t{turn_index}:c{call_id}`
* tool execution: `tool_execution:t{turn_index}:c{call_id}:a{attempt}`

Each request-step payload SHALL carry:

* `step_id`
* `step_type`
* `turn_index`
* `attempt`
* `parent_step_id`
* `boundary`
* `result`

When applicable, payloads MAY also carry `call_id`, `tool_name`, `arguments_json`, `model_id`, and `model_version`.

One logical Request MAY contain at most two Inference Attempts for its first Inference Turn.
Those attempts SHALL use `inference_turn:t1:a1` and `inference_turn:t1:a2`, remain under the same Request row and Request FSM, and SHALL NOT repeat admission, quota reservation, idempotency resolution, queue admission, or Payload Capture Mode resolution.
Attempt 1 terminal evidence SHALL precede attempt 2 started evidence in request-event sequence order.
A successful attempt SHALL carry no `retry_decision`.
An unsuccessful attempt 2 SHALL carry `retry_decision = "retry_exhausted"` unless caller cancellation or disconnect caused its terminal outcome, in which case `cancelled` SHALL take precedence, or a Controller-detected negotiated acceptance-proof failure under §7.5.3a wins the terminal race before deadline terminalization is proven, in which case it SHALL carry `not_retryable`. An already-proven deadline terminalization retains `retry_exhausted`.
Deadline terminalization is proven when the Request's absolute deadline is already exhausted at attempt 2's retry boundary, mirroring attempt 1's `budget_exhausted` precedence over `not_retryable`.
That `not_retryable` exception is available only to an attempt 2 whose `attempt_outcome` is `failed` with `output_committed = false`; a `cancelled`, `timed_out`, or `interrupted` attempt 2, and any attempt 2 that committed output, SHALL retain `cancelled` or `retry_exhausted`.
Attempt 1 SHALL never carry `retry_exhausted`.

The orchestrator SHALL append exactly one `request_step.started` event for each Inference Attempt.
Attempt 1 started evidence SHALL be durable before its initial dispatch sequence begins.
After the final pre-start caller and deadline gate, attempt 2 started evidence SHALL be appended atomically with attempt 1 terminal evidence carrying `retried`.
The dispatcher SHALL consume that existing attempt context and SHALL NOT append a second started event.

A terminal Inference Attempt result SHALL record `attempt_outcome`, `started_at`, `ended_at`, `accepted`, `output_committed`, `execution_resolution`, `capacity_release_outcome`, and the stable Node identity when resolved.
The closed `attempt_outcome` vocabulary is `completed`, `failed`, `cancelled`, `timed_out`, and `interrupted`.
The optional `output_commitment_kind` SHALL be absent when `output_committed = false` and otherwise SHALL be one of `reasoning`, `text`, `tool_call`, or `structured_output`.
`reasoning` SHALL be recorded only for a non-empty reasoning delta selected by `projection = reasoning_structured`.
Hidden reasoning under `projection = final_only` and reasoning embedded in the undifferentiated legacy text channel under `projection = legacy_blended` SHALL NOT use the `reasoning` commitment kind.
The closed `execution_resolution` vocabulary is `not_started`, `terminated`, and `unresolved`.
The closed `capacity_release_outcome` vocabulary is `released`, `already_released`, `not_applicable`, and `unresolved`.
The closed `failure_class` vocabulary is `pre_acceptance_unavailable`, `model_load_failure`, `worker_or_node_loss`, `runtime_failure`, `terminal_conformance`, `capacity_rejection`, `cancellation`, `deadline`, `controller_failure`, `occupancy_unresolved`, and `identity_unresolved`.
A non-completed attempt SHALL carry one `failure_class` and a Controller-normalized stable `failure_code` from the `requests.error_code` vocabulary in §8.2; raw or unknown runtime text SHALL NOT become a failure code or metric label.
The normalization SHALL retain an allowlisted stable inference Runtime Endpoint code, map a model-load category to its Controller-owned default stable code, map caller disconnect to `request_caller_disconnect`, map logical deadline exhaustion to `request_timeout`, preserve the existing stable `cluster_busy` or `model_busy` public mapping for ordinary post-start capacity scarcity, and map terminal-conformance, unresolved occupancy, unresolved identity, unknown, or untrusted source codes to `internal_error` or `orchestration_error` according to the existing Controller-owned public failure mapping.
A raw source failure code MAY persist separately only under `full`; it SHALL NOT control retry, public mapping, or metric labels.
A runtime-provided retryability assertion MAY persist as a boolean only when present.
Every terminal Inference Attempt result SHALL carry `output_tokens` as a non-negative cumulative count and `output_usage_status` as `exact` or `lower_bound`.
A Worker-originated terminal result SHALL use `exact` and SHALL include the complete attempt total.
A Controller-synthesized terminal result SHALL use `lower_bound` when it can prove only the latest validated cumulative count.
The optional `reasoning_tokens` field SHALL be present only when an exact subset is proven, including when that exact value is zero, and SHALL be absent when the subset is unknown or unproven.
These fields are closed non-content evidence and SHALL remain durable under every Payload Capture Mode.
The closed `retry_decision` vocabulary is `retried`, `not_retryable`, `output_committed`, `cancelled`, `budget_exhausted`, `identity_unresolved`, `occupancy_unresolved`, `no_alternative_node`, and `retry_exhausted`.
A successful attempt SHALL omit `retry_decision`; every unsuccessful attempt SHALL carry one.
The optional `target_ref` SHALL be an approved stable identifier under `full` or a deterministic hash outside `full`, never a raw target address.
`excluded_node_ids` SHALL be empty for attempt 1 and SHALL contain exactly attempt 1's durable Node UUID for attempt 2.
Closed attempt evidence, timestamps, booleans, stable Node UUIDs, and deterministic target hashes SHALL remain durable under `none` and `metadata` after validation.
Raw runtime messages, content, target addresses, and arguments remain governed by §10.10 and MUST NOT be persisted outside the effective capture policy.

Durable retention of these payload fields is bounded by the Request capture mode in §10.10. Outside `full`, `call_id` persists only as a deterministic hash, the step identifiers derived from it embed that hash, and `tool_name`, `arguments_json`, `model_id`, and `model_version` are not retained.

`tool_execution` steps and `request_step.indeterminate` remain future-facing shapes for later hosted-execution slices, but their durable outcome contract is now defined in §3.7.2. This persistence section MUST NOT be interpreted as enabling controller-owned hosted `/v1/responses` tool-execution loops in the current slice.

### 3.7.2 Future tool-execution outcome taxonomy

This subsection defines the controller-owned outcome contract for a later phased hosted-tool extension. It SHALL be used when Orchard persists or projects the result of a `tool_execution` step. It MUST NOT be interpreted as enabling controller-owned hosted `/v1/responses` execution in the current slice.

Tool-execution outcome vocabulary is:

* `completed`
* `failed`
* `cancelled`
* `timed_out`
* `indeterminate`

`indeterminate` SHALL be first-class at the `tool_execution` request-step layer. Orchard SHALL use `indeterminate` when the controller cannot safely claim the final externally observable outcome of a tool attempt. Orchard SHALL NOT flatten `indeterminate` into generic failure at the request-step layer.

Initial `indeterminate_reason` vocabulary is:

* `controller_restarted`
* `executor_unreachable`
* `timeout_after_start`
* `cancel_ack_missing`
* `result_not_observed`

Request-step mapping rules:

* terminal hosted-tool outcomes SHALL persist with `step_type = "tool_execution"` and `boundary = "post_observation"`
* `completed` SHALL map to `request_step.completed`
* `failed` SHALL map to `request_step.failed`
* `cancelled` SHALL map to `request_step.cancelled`
* `timed_out` SHALL map to `request_step.timed_out`
* `indeterminate` SHALL map to `request_step.indeterminate`
* terminal `tool_execution` result maps MAY carry `remote_execution_ref` and `side_effect_anchor`
* non-completed terminal `tool_execution` result maps SHALL carry `error_code` and `error_message`
* `indeterminate` terminal `tool_execution` result maps SHALL additionally carry `indeterminate_reason`
* `completed`, `failed`, `cancelled`, and `timed_out` terminal `tool_execution` result maps SHALL NOT carry `indeterminate_reason`

Coarse request terminal mapping rules:

* `requests.state` SHALL remain coarse in this slice; Orchard SHALL NOT add request-level `indeterminate`
* future hosted controller flows SHALL derive detailed tool outcome truth from `request_step.*` rows rather than the request row
* `failed` SHALL map to request terminal `state = :failed`
* `cancelled` SHALL map to request terminal `state = :cancelled`
* `timed_out` SHALL map to request terminal `state = :timed_out`
* `indeterminate` SHALL map to request terminal `state = :failed` plus tool-execution-specific `error_code` and `error_message`

Retryability rules are:

* `completed` SHALL never auto-retry
* `failed` MAY become manually retryable in a later slice only when no durable `side_effect_anchor` exists; this slice SHALL default controller helpers to no auto-retry
* `cancelled` SHALL never auto-retry
* `timed_out` SHALL never auto-retry
* `indeterminate` SHALL never auto-retry

Future `/v1/responses` terminal projection rules are:

* these rules are reserved for the first hosted `/v1/responses` slice; current client-executed passthrough behavior remains unchanged
* `failed` SHALL project to terminal status `"failed"`
* `timed_out` SHALL project to terminal status `"failed"`
* `cancelled` SHALL project to terminal status `"incomplete"` only when partial tool-related output or items were already surfaced; otherwise it SHALL project to `"failed"`
* `indeterminate` SHALL project to terminal status `"incomplete"` only when partial tool-related output or items were already surfaced; otherwise it SHALL project to `"failed"`
* `indeterminate` SHALL NEVER be surfaced as a successful completed tool result

### 3.8 Internal request lifecycle

```text
1. HTTP request received
2. authn/authz
3. canonicalize + tokenize
4. quota and policy admission
5. insert request row + event
6. schedule or queue
7. dispatch to node
8. node ensures model loaded
9. worker executes and streams deltas
10. controller relays SSE/JSON response
11. finalize usage/accounting
12. append terminal request event + audit entries
```

After step 5, internal scheduler or dispatch orchestration failures SHALL skip the remaining runtime steps, append a terminal failed request event, and preserve sanitized public error mapping.

### 3.9 Idempotency

The controller SHALL support `Idempotency-Key` on both public inference endpoints.

Rules:

* uniqueness scope: `(tenant_id, idempotency_key)`
* if same key + same body hash already completed and `stream=false`, return the stored result when the Request retained its `response_payload`, otherwise return `409 idempotency_not_replayable` (see §10.10 for when payloads are retained)
* if same key + same body hash is still active, return `409 request_in_progress`
* if same key reused with different body hash, return `409 idempotency_mismatch`
* streaming responses SHALL NOT be replayed from persisted token chunks in v1

---

## 4. Node Management

### 4.1 Node identity model

A Controller Host is a host that runs a Controller instance and participates in durable orchestration and, when configured, Active/Standby leadership.
A Controller Host is not schedulable unless an admitted Node Agent on that host separately satisfies the Node contract.

A Node is an explicitly managed resource representing an admitted host that runs a Node Agent and advertises authenticated, versioned runtime-provider and device-resource capabilities.
A Node is not defined solely by operating system or processor vendor.
The current supported Nodes are Apple Silicon macOS hosts under the supported Apple Silicon macOS platform profile and macOS MLX Node runtime profile.
Future Node support requires separate platform, distribution, runtime-provider, trust, and real-runtime acceptance evidence as applicable.

A node record SHALL include:

* stable `node_id` UUID
* hostname
* advertise address
* canonical production BEAM node name after validated private IPv4 inventory exists
* pool membership
* platform and architecture observations
* distinct runtime-provider, acceleration, device-resource, and memory-domain capabilities
* trust material reference
* lifecycle state
* current health
* last heartbeat timestamp
* durable dispatch capacity policy after Node Admission

A Node's canonical production BEAM node name SHALL be null until validated private IPv4 inventory is recorded.
Node Admission SHALL NOT authorize a Peer Grant, and no production Runtime Endpoint target or `admitted -> active` BEAM authorization SHALL proceed, while that canonical name is absent or unvalidated.

Runtime Endpoint metadata MAY be observed before a trusted Node exists.
An unreconciled first observation SHALL create or update a Runtime Endpoint Admission Candidate for admin review, not a Node row.
Runtime Endpoint Admission Candidates live outside the Node Lifecycle State machine.
They SHALL NOT be represented as `provisioned` unless an admin-created placeholder or bootstrap exists.
They SHALL NOT be represented as `registered` unless `RegisterNode` or equivalent trust proof has completed.
They SHALL NOT be represented as `active`, considered schedulable, or allowed to publish queue capacity.
Candidate metadata is untrusted operator-review evidence and SHALL be sanitized, bounded, and insufficient by itself for scheduling, dispatch, trust establishment, or Node identity ownership.
In Active/Standby mode, creating candidates, rejecting candidates, clearing rejection, admitting nodes, and writing the related audit events are leader-only write paths.

### 4.2 Node lifecycle states

| State             | Meaning                                                           | Schedulable |
| ----------------- | ----------------------------------------------------------------- | ----------- |
| `provisioned`     | admin created placeholder/bootstrap issued; node has not joined   | no          |
| `registered`      | node proved identity and submitted inventory                      | no          |
| `admitted`        | admin accepted trusted registered node into cluster and assigned pool/policy | no |
| `active`          | admitted node has fresh healthy observation and is eligible for scheduling | yes |
| `cordoned`        | healthy enough to run existing work, but no new work              | no          |
| `draining`        | cordoned and actively waiting for active requests to finish       | no          |
| `maintenance`     | unschedulable for upgrades/diagnostics                            | no          |
| `decommissioning` | node being removed; cert/token revocation and cleanup in progress | no          |
| `removed`         | terminal tombstone state                                          | no          |

### 4.3 Node lifecycle transitions

```text
provisioned -> registered
registered  -> admitted
admitted    -> active

active      -> cordoned
cordoned    -> active

active      -> draining
cordoned    -> draining
draining    -> cordoned
draining    -> maintenance
maintenance -> active

registered  -> decommissioning
admitted    -> decommissioning
active      -> decommissioning
cordoned    -> decommissioning
draining    -> decommissioning
maintenance -> decommissioning
decommissioning -> removed
```

### 4.4 Transition rules

* `provisioned -> registered`

  * trigger: successful `RegisterNode`
  * conditions: valid bootstrap token or valid client cert

* `registered -> admitted`

  * trigger: Admin API action
  * conditions: inventory captured, trust established, pool assigned, and required policy inputs supplied
  * effect: atomically persist an explicit Controller Dispatch Ceiling and approval provenance before the lifecycle transition; when the administrator omits the value, persist the explicit default `1`; before enforcement cutover the policy state is `approved_explicit`, and after enforcement cutover it is `enforcing`

* `admitted -> active`

  * trigger: first successful healthy heartbeat after admission

* `active -> cordoned`

  * trigger: operator/admin action
  * effect: scheduler excludes node immediately

* `active|cordoned -> draining`

  * trigger: operator/admin action
  * effect: no new requests, wait until `active_request_count == 0`

* `draining -> cordoned`

  * trigger: operator/admin action (cancel drain)
  * effect: stop waiting for active-request quiescence; node remains unschedulable as `cordoned`; work already completed, cancelled, or quiesced during the drain is not restored; no drain completion is certified

* `draining -> maintenance`

  * trigger: automatic when drained and requested action specified
  * effect: model preloads disabled, diagnostics allowed

* `maintenance -> active`

  * trigger: operator/admin action
  * conditions: health is not `unreachable` or `unhealthy`

* `registered|admitted|active|cordoned|draining|maintenance -> decommissioning`

  * trigger: admin action
  * effect: cordon, revoke future scheduling, cancel or drain active work, revoke join trust

* `decommissioning -> removed`

  * trigger: cleanup success
  * effect: no rejoin with same `node_id`

Runtime Endpoint status observation alone MUST NOT bypass `provisioned -> registered`, `registered -> admitted`, or `admitted -> active`.
Observed candidates and provisioned placeholders MAY appear in admission review, but admit execution SHALL be blocked until a registered Node has current trust, inventory, pool, and required policy inputs.
Rejecting pending Node Admission SHALL persist a Node Admission Decision and SHALL NOT transition a Node to `decommissioning`.
Rejected admission metadata SHALL include `decision = rejected`, actor, decided timestamp, reason, observed identity or node reference, target reference when applicable, and audit event reference.
For lifecycle-managed Node rows, rejection SHALL leave lifecycle as `provisioned` or `registered` and set the derived admission category to `rejected`.
Re-admission after rejection SHALL require current trusted registration state plus either an explicit admin clear action or a new registration and trust event recorded in audit.

### 4.5 Node health model

Health is orthogonal to lifecycle state.

Valid health values:

* `healthy`
* `degraded`
* `unhealthy`
* `unreachable`

Required controller thresholds:

* background status observation interval: **5000 ms** default, and strictly below both freshness thresholds
* heartbeat freshness threshold (`node_freshness_threshold_ms`): **30000 ms** default
* heartbeat unreachable threshold (`node_unreachable_threshold_ms`): **15000 ms** default

Cluster-management status freshness categories and scheduler eligibility SHALL derive from the same configurable heartbeat freshness thresholds.
The cluster-management freshness display is `fresh` through the smaller of the heartbeat freshness and unreachable thresholds, `stale` through the larger threshold, and `unreachable` after the larger threshold.
With current defaults this means `fresh` at or under 15000 ms, `stale` from over 15000 ms through 30000 ms, and freshness `unreachable` over 30000 ms.
Scheduler eligibility and the `node_observation_stale` reason code use `node_freshness_threshold_ms`, default 30000 ms, so a `stale` freshness display state can remain schedulable until that cutoff.
The freshness category named `unreachable` is distinct from the Node Health `unreachable` value; Node Health `unreachable` uses the 15000 ms unreachable threshold.

Health derivation:

* `healthy`: heartbeat fresh and no local alarm
* `degraded`: fresh heartbeat, but warning condition exists
* `unhealthy`: fresh heartbeat, but serious local error
* `unreachable`: heartbeat older than 15s

Active-Node liveness SHALL be maintained by a leader-owned background status observer
(`Orchard.RuntimeEndpoint.ActivationProbe`) that probes admitted and active Runtime
Endpoint Nodes on a bounded interval strictly below both heartbeat thresholds, independent
of request traffic. Successful authenticated observations advance `last_heartbeat_at`,
re-derive health, and refresh aggregate capacity evidence in one write. Transport failures
and a periodic heartbeat-age sweep over `:active` Nodes demote health through the graded path
(`degraded`, then `unreachable` past the unreachable threshold); a Node already recorded
`unhealthy` SHALL keep that health until a successful observation clears it, and `:admitted`
Nodes SHALL NOT be swept because a stalled admitted heartbeat usually means the observation
seam is rejecting a reachable Node. Non-healthy observations from already-active
Nodes SHALL be recorded; `:admitted` to `:active` promotion remains healthy-gated.
A standby Controller SHALL write nothing on this path.

Warning conditions:

* swap used > 2 GiB
* thermal pressure = serious
* repeated worker restart in last 10 min
* free disk for model cache < 10 GiB

Serious conditions:

* thermal pressure = critical
* worker supervisor unavailable
* artifact filesystem unavailable
* local RPC server unhealthy
* free disk < 5 GiB

### 4.6 Heartbeat payload

For first-party v1 Runtime Endpoints, the Active Controller obtains heartbeat and
inventory evidence by pulling authenticated Runtime Endpoint status through the
leader-owned background observer defined in §4.5 at a 5000 ms default interval. A
first-party Node Agent answers that status operation; it does not originate a separate
periodic push heartbeat loop.

The observation payload includes:

```json
{
  "node_id": "uuid",
  "agent_version": "semver",
  "hostname": "mac-01",
  "advertise_addr": "10.0.0.21",
  "rpc_port": 9444,
  "physical_memory_bytes": 68719476736,
  "available_memory_bytes": 40265318400,
  "swap_used_bytes": 0,
  "cpu_load_1m": 1.2,
  "thermal_pressure": "nominal",
  "active_requests": 1,
  "capabilities": {
    "arch": "arm64",
    "chip_family": "M3",
    "supported_formats": ["mlx"],
    "runtime_adapters": ["mlx_lm"]
  },
  "placements": [
    {
      "model_id": "llama-3.1-8b-instruct",
      "version": "mlx-q4-v1",
      "state": "loaded",
      "resident_bytes": 6442450944,
      "active_request_count": 1,
      "max_concurrency": 1,
      "last_used_at": "2026-03-08T12:00:00Z"
    }
  ],
  "workers": [
    {
      "worker_id": "uuid",
      "state": "busy",
      "restart_count": 0
    }
  ]
}
```

### 4.6.1 Runtime Endpoint capability and readiness observation

Hosted-tool observation SHALL remain distinct from heartbeat inventory in the current implementation slice.

Rules:

* the durable implementation seam for runtime status SHALL be a Runtime Endpoint Observation produced through the Runtime Endpoint Interface
* the current gRPC Compatibility Adapter SHALL derive Runtime Endpoint Observations from `NodeRuntimeService.GetStatus` returning `StatusResponse`
* Controller-facing Runtime Endpoint adapters SHALL assign scheduling-authoritative observation time when a successful status response is received and normalized.
* Endpoint-provided wall-clock timestamps SHALL NOT be freshness authority.
* For authenticated observations, the adapter SHALL reuse the exact Controller-assigned timestamp in both the returned Runtime Endpoint Observation and authenticated persistence.
* controller-owned active-Node liveness and inventory freshness SHALL be refreshed by a leader-owned background status probe on a bounded interval independent of request traffic, consuming authenticated observations through the same seam
* heartbeat payloads MAY carry equivalent hosted-tool data in a later slice, but controller-owned hosted-tool observation SHALL currently be derived from Runtime Endpoint status-probe ingestion
* this contract defines future hosted routing inputs only; it SHALL NOT by itself enable controller-owned hosted `/v1/responses` execution or any other hosted execution behavior
* Runtime Endpoint Observations are observational until reconciled to a trusted Node
* unregistered observations MAY update Runtime Endpoint Admission Candidate metadata only
* unregistered observations SHALL NOT update Node lifecycle state
* unregistered observations SHALL NOT refresh queue capacity sources
* gRPC and BEAM Runtime Endpoint Observations SHALL affect scheduling only after the target identity resolves to a persisted trusted Node

Each successful authenticated, non-stale observation of a trusted target SHALL append one `node_heartbeats` row in the same transaction that advances `nodes.last_heartbeat_at`, re-derives Node health, and refreshes aggregate DispatchCapacity evidence. Failure of any write rolls back all effects. A standby Controller writes nothing on this path, and a transport failure SHALL NOT create a synthetic successful heartbeat row.

`node_heartbeats.payload` SHALL use Controller-produced schema version `1` with a closed top-level allowlist: `schema_version`, `validity`, optional `invalid_reason`, `endpoint_id`, `target`, `availability`, `worker_state`, `aggregate_active_request_count`, `aggregate_max_concurrency`, `aggregate_capacity_evidence`, `placements`, `runtime_memory_budgets`, `runtime_prefix_cache_statuses`, `worker_crash_counters`, and `supports_prompt_token_ids`. The row columns remain canonical for trusted `node_id` and `observed_at`. `target` is limited to `id`, `transport`, `address`, and `node_id`; each placement is limited to `model_ref`, `state`, `capacity`, and `last_used_at`; each model reference to `model_id` and `version`; each Placement Capacity to `active_request_count`, `max_concurrency`, `status`, and `source`; aggregate capacity evidence to `runtime_concurrency_limit`, `active_request_count`, and `validity`; and each worker-crash counter to `model_id`, `count`, and `counter_version`, capped at 4 entries per payload. Maps and lists are capped at 40 entries, nesting at depth 4, and otherwise-unbounded strings at 512 bytes; narrower domain, numeric, and status-vocabulary bounds take precedence. The complete encoded JSON is capped by validated `node_heartbeat_payload_max_bytes`, default **262144 bytes**.

Memory-budget entries SHALL use `Orchard.Runtime.MemoryBudget.normalize/1`, and prefix-cache entries SHALL use `Orchard.Runtime.PrefixCacheStatus.normalize/1`, not scheduler-specific normalization. Persisted prefix-cache data SHALL exclude raw fingerprint sets while retaining only sanitized status, fingerprint count, and warmth information. Unknown fields are dropped. An unknown schema, malformed required envelope, or payload still over the byte cap after normalization SHALL commit as a minimal bounded version-1 `validity = "invalid"` envelope with a stable `invalid_reason`; it cannot produce a positive scheduler candidate and maps to `dispatch_capacity_facts_unavailable`. The payload SHALL NOT contain credentials or secrets, DSNs, prompt or response bodies, raw tokens, tenant identifiers, raw metadata or diagnostics, local paths or evidence, tool/session identifiers, Controller policy, Controller-accounted Allocation, quarantine, authority decisions, acquirability, or another derived eligibility result.

Hosted-tool observation vocabulary:

* **static capability** identifies a node-advertised hosted tool by registry-compatible `name` and `version`, plus the local `adapter_kind`
* **dynamic readiness** reports whether that same advertised hosted tool is currently ready on the node, with `ready`, `readiness_code`, and `readiness_message`
* the controller SHALL derive canonical hosted-tool identity as `tool://<name>@<version>`
* hosted-tool identity SHALL align with controller registry semantics; Orchard SHALL NOT introduce a second hosted-tool naming scheme

Compatibility and defaulting rules:

* absent hosted-tool capability/readiness fields on a Runtime Endpoint Observation SHALL mean the endpoint advertises no hosted tools
* absent hosted-tool capability/readiness fields SHALL NOT be treated as a status-probe error
* readiness without matching advertised capability for the same `tool://<name>@<version>` SHALL NOT make the node eligible for hosted routing
* `supports_prompt_token_ids` indicates that the endpoint's loaded worker can accept controller-supplied prompt token IDs on the runtime execution request. Absence or `false` is treated as legacy capability, not as an observation failure. When `tokenizer_safe_mode_prefer_capable=true` and `tokenizer_safe_mode` is not `:off`, this field from a fresh durable scheduler snapshot MAY inform opt-in scheduler preference only; it is not dispatch authority.
* absent or empty runtime memory budgets on a Runtime Endpoint Observation SHALL mean no memory-budget observation is available
* absent or empty `runtime_memory_budgets` SHALL NOT be treated as a status-probe error
* `runtime_memory_budgets` SHALL remain observe-only telemetry except for the Phase 4E scheduler-ranking guard defined in §5.7 and §7.5.3; it SHALL NOT affect node readiness, model admission, request admission, scheduling eligibility, hosted-tool eligibility, public error contracts, queue ordering, or memory-budget enforcement
* when `memory_admission.enabled = true`, `Orchard.Scheduler.MultiNode` MAY use only `RuntimeMemoryBudget.status_code == "ok"` plus `headroom_available == true` as a positive, non-excluding ranking preference below loadedness, requested-placement active request count when known, health, live prefix-cache fingerprint match, historical cache affinity, and any enabled safe-tokenization capable-worker preference, and above deterministic `node_id`
* absent, empty, stale, malformed, disabled, unavailable, invalid, device-info-failed, compute-failed, non-`ok`, or `headroom_available != true` memory telemetry SHALL be rank-neutral and fail open
* current `RuntimeMemoryBudget.status_code` vocabulary is: `ok`, `disabled`, `device_info_unavailable`, `device_info_invalid`, `resident_memory_unavailable`, `compute_failed`, `invalid_status`
* absent or empty runtime prefix-cache statuses on a Runtime Endpoint Observation SHALL mean no prefix-cache observation is available
* absent or empty `runtime_prefix_cache_statuses` SHALL NOT be treated as a status-probe error
* aggregate `runtime_prefix_cache_statuses` counters SHALL remain observe-only telemetry and SHALL NOT affect node readiness, model admission, request admission, scheduling eligibility, queue ordering, hosted-tool eligibility, or `worker_generation_mode`; the Phase 4C bounded HMAC fingerprint field MAY affect scheduler ranking only as the explicitly configured non-gating tie-breaker defined in §5.7 and §7.5.3
* current `RuntimePrefixCacheStatus.status_code` vocabulary is: `ok`, `disabled`, `unavailable`, `error`, `invalid_status`
* these status codes are observational only in this slice and SHALL NOT gate readiness, admission, or scheduling
* aggregate `active_request_count` on a Runtime Endpoint Observation, and on the current gRPC compatibility `StatusResponse`, SHALL report active runtime requests across the endpoint node
* `max_concurrency` on the current gRPC compatibility `StatusResponse` SHALL report the Node-owned Runtime Concurrency Enforcement Limit
* an omitted or zero compatibility-protocol `max_concurrency` MAY normalize to Runtime Concurrency Enforcement Limit `1` only for an explicitly unmanaged source-development or compatibility target
* an omitted, zero, malformed, unavailable, or stale Runtime Concurrency Enforcement Limit for an admitted production Node SHALL yield Effective Dispatch Limit `0`
* absent or empty Placement Capacity on a Runtime Endpoint Observation, including absent or empty `runtime_model_placements` on the current gRPC compatibility `StatusResponse`, SHALL mean no explicit per-placement capacity observation is available
* absent or empty Placement Capacity SHALL NOT be treated as a status-probe error
* Placement Capacity entries SHALL report Node-owned capacity for loaded Model Placements through Runtime Endpoint Observations using model reference, active request count, and max concurrency; `max_concurrency <= 0`, malformed entries, duplicate matching entries, or non-matching entries SHALL be treated as unknown capacity
* valid per-placement capacity SHALL NOT prove endpoint eligibility when the shared authority decision has no positive available slots; under `f11_enforcing`, this means Dispatch Headroom is `0`
* unknown Placement Capacity SHALL NOT prove scheduler eligibility for an already-active endpoint; `Orchard.Scheduler.MultiNode` MAY keep a matching loaded-model active candidate eligible only when exactly one valid matching Placement Capacity entry reports `active_request_count < max_concurrency`

Effective readiness rules for future hosted routing:

* a node candidate is effectively ready for a hosted tool only when the controller registry contains an active tool with matching `name` and `version`
* the registry tool `execution_mode` SHALL be `:server_hostable`
* the node SHALL advertise matching static hosted-tool capability for the same `tool://<name>@<version>`
* the node lifecycle state SHALL be `active`
* node health SHALL be `healthy` or `degraded`
* the Runtime Endpoint Observation SHALL be fresh under Orchard's existing freshness thresholds
* dynamic readiness for that tool SHALL exist and have `ready = true`

### 4.6.2 Controller dispatch capacity authority

Every admitted production Node SHALL have one durable Controller dispatch capacity policy.
For this contract, the production cohort begins only when Node Admission commits; a registered but unadmitted Node is enrolled inventory but is not yet a dispatch-policy subject.
The operational cohort ends only when lifecycle `removed`, trust revocation, and the removal audit commit durably.
A removed Node's policy remains historical evidence but is excluded from capacity evaluation, operator-approval blockers, Controller compatibility cutover preflight, and zero-occupancy quiescence.
Any later re-enrollment SHALL pass a new Node Admission and persist policy under the then-current phase.
Except for the bounded pre-F11 cohort while its policy state is `shadow_legacy`, that policy SHALL contain a non-negative Controller Dispatch Ceiling and an explicit policy state.
The bounded `shadow_legacy` record SHALL deliberately contain a null ceiling, SHALL be distinct from a missing policy record, and SHALL never authorize the new production capacity semantics.
The Controller Dispatch Ceiling is Controller-owned policy and SHALL NOT be inferred, copied, or backfilled from runtime telemetry.
New Node Admission SHALL persist a Controller Dispatch Ceiling in the same transaction as admission, using an explicit value supplied by the administrator or the explicit default `1`.
The cluster SHALL persist one durable dispatch-capacity enforcement phase with values `pre_cutover` and `enforcing`.
The admission transaction SHALL lock and read that phase rather than infer cutover from policy rows, Controller version, transport, or cluster occupancy.
While the phase is `pre_cutover`, new admission SHALL write `approved_explicit`; while the phase is `enforcing`, new admission SHALL write `enforcing` directly because every semantic consumer is already enforcing the shared evaluation.
An explicit Controller Dispatch Ceiling of `0` is valid policy and, while the authority decision is `f11_enforcing`, prevents new Controller allocations without changing Node Lifecycle State or forcibly cancelling accepted, running, or streaming work solely because of the policy value.
While the phase is `pre_cutover`, an approved ceiling including `0` is not yet allocation authority, and admission or mutation previews SHALL expose `controller_dispatch_ceiling_not_yet_enforcing`.
A missing policy record, or a missing ceiling outside the bounded `shadow_legacy` exception, is an integrity failure and SHALL yield Effective Dispatch Limit `0`.
A permanent null value meaning runtime-managed capacity is prohibited.

The Runtime Concurrency Enforcement Limit is the Node-owned dynamic aggregate limit that the Node Agent enforces locally.
The Controller SHALL treat a Runtime Endpoint capacity observation as fresh only while both the trusted Node heartbeat and the capacity observation remain within the scheduler freshness threshold.
For an admitted production Node, the Controller SHALL compute:

```text
effective_dispatch_limit =
  if trusted_identity
     and lifecycle_state == active
     and node_health == healthy
     and heartbeat_is_scheduler_fresh
     and capacity_observation_is_scheduler_fresh
     and dispatch_capacity_enforcement_phase == enforcing
     and controller_dispatch_policy_state == enforcing
     and controller_dispatch_ceiling_is_valid
     and runtime_concurrency_enforcement_limit_is_valid
  then min(runtime_concurrency_enforcement_limit, controller_dispatch_ceiling)
  else 0

dispatch_headroom =
  max(effective_dispatch_limit - controller_accounted_allocation, 0)
```

Dispatch Headroom SHALL authorize only acquisition of a new allocation.
Dispatch revalidation of a recognized pre-acceptance allocation SHALL NOT require positive Dispatch Headroom after counting that same allocation a second time.
Instead, the shared evaluation SHALL serialize revalidation with allocation changes, exclude only the current recognized allocation from the allocation operand, and allow execution only when the resulting value is positive and every non-allocation gate still passes.
An allocation held during connection or model loading is pre-acceptance work and is not grandfathered across a ceiling reduction.
A request already accepted by the Node, running, or streaming SHALL NOT be forcibly cancelled solely because the Controller Dispatch Ceiling is lowered.

The shared evaluation SHALL take the durable cluster enforcement phase as an explicit input.
While the phase is `pre_cutover`, a `shadow_legacy` or `approved_explicit` policy SHALL return counterfactual Effective Dispatch Limit and Dispatch Headroom `0` plus an explicit `legacy_pre_cutover` decision that preserves the named legacy capacity behavior for every semantic consumer.
The `legacy_pre_cutover` decision is temporary migration behavior, SHALL NOT be presented as Effective Dispatch Limit or Dispatch Headroom, and SHALL NOT create durable policy from telemetry.
The shared evaluator SHALL calculate the temporary decision centrally as follows:

```text
legacy_pre_cutover_limit =
  if fresh runtime max_concurrency is a positive integer
  then max_concurrency
  else 1

legacy_pre_cutover_reported_allocation =
  if fresh aggregate active_request_count is a non-negative integer
  then active_request_count
  else 0

legacy_pre_cutover_claimed_allocation =
  count(unique non-released Controller-local temporary legacy claims)

legacy_pre_cutover_available_slots =
  max(
    legacy_pre_cutover_limit
      - legacy_pre_cutover_reported_allocation
      - legacy_pre_cutover_claimed_allocation,
    0
  )
```

The temporary decision SHALL authorize new work only when trusted identity, lifecycle `active`, health `healthy` or `degraded`, scheduler-fresh heartbeat and Runtime Endpoint Observation, pool, format, memory, placement, and breaker gates pass and `legacy_pre_cutover_available_slots` is positive.
All five semantic consumers SHALL use the decision and its centrally calculated available slots without independently interpreting runtime concurrency.
Acquisition of a temporary legacy claim SHALL serialize across every placement and queue lane for the Node so concurrent consumers cannot spend the same temporary slot.
The claim SHALL begin before connection or model loading, remain attached to the logical request through accepted, running, and streaming work, and release exactly once on terminal completion, cancellation, pre-acceptance failure, or before retrying another Node.
Pre-acceptance legacy revalidation SHALL exclude only the current recognized temporary claim from the claimed-allocation operand and SHALL retain the claim through Node acceptance.
The reported allocation plus temporary-claim calculation is deliberately conservative when Runtime Endpoint telemetry also observes Controller work.
Queue-source and lane contributions are scheduling hints only; every grant SHALL still acquire the serialized temporary legacy claim before dispatch.
Controller-accounted Allocation MAY be tracked counterfactually before cutover but SHALL NOT replace reported allocation or the separate temporary-claim bound.
The frozen missing or malformed aggregate-active-count normalization to `0` is limited to this temporary branch and is the explicit malformed aggregate active-count follow-up outside F11 enforcement scope.
While the phase is `enforcing`, only an `enforcing` policy MAY produce a non-zero Effective Dispatch Limit.
A `pre_cutover` phase with an `enforcing` policy, or an `enforcing` phase with `shadow_legacy` or `approved_explicit`, is an integrity mismatch and SHALL fail closed for new allocation and expose `dispatch_capacity_phase_policy_mismatch`.

Controller-accounted Allocation SHALL count unique, non-released, Node-scoped logical allocations owned by the current Active Controller.
Queued requests, unassigned queue grants, configured base lane capacity, Node-reported active request counts, and Placement Capacity telemetry SHALL NOT count as Controller-accounted Allocation.
One request SHALL acquire at most one allocation on a Node before model loading or execution, retain it through dispatch and running work, and release it exactly once before retrying another Node or after cancellation, pre-acceptance failure, or terminal completion.
Release SHALL remain idempotent and SHALL report whether the live claim transitioned to released, was already released, was not applicable, or could not be confirmed.
An unavailable authority, ambiguous release, unresolved cancellation drain, or unavailable quarantine store SHALL report unresolved ownership rather than synthetic success.
Alternate scheduling and acquisition SHALL begin only after attempt 1 execution is resolved and release is affirmatively `released`, `already_released`, or `not_applicable`.
Opaque process-local claim tokens SHALL NOT be persisted or transferred between attempts.
A same-Request held-claim rejection SHALL remain a fail-closed defense against overlapping logical ownership.
Acquisition of the final unit of Dispatch Headroom SHALL be serialized so two concurrent requests cannot both claim it.
This F11 accounting contract is Controller-local and SHALL NOT be represented as a durable dispatch permit, leader epoch, Node-verifiable token, crash-recoverable reservation ledger, or proof of actual Node occupancy.

For the reserved experimental `managed_apple_silicon_macos_node` profile only, Orchard SHALL use durable execution-grant IDs and fence epochs solely to fence the profile's managed host-composition transition.
Transition creation SHALL be the first-stage allocation-issuance fence: the Controller SHALL close new grant issuance for that Node and persist each exact grant, its fence epoch, and its terminal disposition in Postgres under the same serialization boundary as transition creation and scheduler exclusion.
The stable helper SHALL provide the second-stage final-acceptance fence by serializing final Worker Runtime acceptance against durable local epoch closure and by durably retaining the current local epoch plus consumed or rejected grant IDs so restart and replay fail closed until exact Controller and helper reconciliation.
Host mutation SHALL remain blocked until local epoch closure is durable and every pre-fence grant is proven never accepted, durably rejected before acceptance, or confirmed terminated with its allocation released.
This profile SHALL remain reserved, experimental, not operator-acquirable, and not production-admittable until its product-versioning and release-governance, clean-host provisioning, operator-visible status and repair, safe decommission, and next-update prerequisites are accepted and its full production qualification is complete.
This exception SHALL NOT alter F11 for any other profile or authorize a general durable dispatch-permit system, leader epoch, leadership fence, crash-recoverable reservation ledger, handover recovery mechanism, or other pre-M7 fencing behavior.

The Active Controller SHALL provide one Controller-local cluster transition barrier and one Controller-local acceptance gate per admitted production Node.
Node policy mutation SHALL serialize through that Node's acceptance gate.
Final dispatch revalidation SHALL acquire the same acceptance gate and hold it continuously from the final shared evaluation through either Node acceptance or pre-acceptance failure.
If dispatch holds the gate first, Node acceptance linearizes before a later ceiling mutation and the accepted work may drain naturally.
If policy mutation holds the gate first, later revalidation SHALL observe the new ceiling and phase before execution.
Enforcement cutover SHALL use the cluster transition barrier and every Node acceptance gate in stable order so no temporary legacy claim or pre-acceptance handoff can cross the phase change.
These gates define one live Active Controller's F11 linearization boundary and are not a substitute for M7 leadership fencing or durable dispatch permits.

A dispatch that cannot establish whether its runtime execution ended — a cancel drain that times out without a transport-proven clean disconnect and without a durably recorded `unhealthy` or `unreachable` Node — SHALL quarantine that Node in the Active Controller's local quarantine set.
A transport disconnect counts as proof only when the Runtime Endpoint client affirmatively reports the runtime stream closed; a best-effort `:ok` from a transport that cannot observe closure SHALL be treated as unreconciled.
Quarantine is keyed by admitted Node identity, so an evaluation without a Node identity, such as an unmanaged source-development or compatibility target, SHALL NOT be quarantined.
Every later shared evaluation for a quarantined Node SHALL supply health `unreachable` rather than counting the unresolved execution as free capacity, and SHALL therefore fail closed with the existing `node_health_unhealthy` reason code.
The quarantine set SHALL be supervised outside the inference subtree so restarting the allocation authority cannot resume dispatch from a clean quarantine set, and an unavailable quarantine set SHALL make every Node evaluate as unreachable rather than as free capacity.
Within F11, quarantine SHALL NOT expire on a timer and SHALL NOT be released through an unauthenticated operator surface; recovery is a Controller restart after the operator confirms no orphaned execution remains.

One shared transport-independent capacity evaluation SHALL produce the Runtime Concurrency Enforcement Limit, Controller Dispatch Ceiling, Effective Dispatch Limit, Controller-accounted Allocation, Dispatch Headroom, Placement Capacity, durable enforcement phase, policy state, normalized target management class, explicit authority decision of `legacy_pre_cutover`, `f11_enforcing`, `unmanaged_source_development`, `unmanaged_compatibility`, or `fail_closed`, decision-specific available slots, eligibility, and stable reason codes.
For a `production_managed` target, only `legacy_pre_cutover` with positive centrally calculated legacy slots or `f11_enforcing` with positive Dispatch Headroom SHALL authorize dispatch.
`fail_closed` SHALL NEVER authorize dispatch.
`Orchard.Scheduler.MultiNode`, admitted `Orchard.Scheduler.SingleNode`, Node observation queue-source refresh, `Orchard.Inference.QueueManager`, and dispatch-time revalidation SHALL consume that evaluation without re-deriving the formulas or defaulting missing production policy to `1`.
Transport selection SHALL NOT classify capacity authority.
An admitted production Node remains governed by this contract over BEAM, gRPC compatibility, or a static target reference.
Every normalized Runtime Endpoint target descriptor SHALL carry `capacity_management_class` with one of `production_managed`, `unmanaged_source_development`, or `unmanaged_compatibility`.
The Controller SHALL resolve trusted admitted production inventory before applying configured classification, and an inventory match SHALL force `production_managed` regardless of a conflicting unmanaged declaration.
`unmanaged_source_development` SHALL be accepted only from Controller-owned source-development configuration while the Controller runs in source-development mode.
`unmanaged_compatibility` SHALL be accepted only from an explicitly enabled Controller-owned compatibility target configuration that does not resolve to admitted production inventory.
The classification SHALL NOT come from Node telemetry, transport type, address shape, probe outcome, or adapter fallback.
Absent, malformed, conflicting, or unresolved classification SHALL fail closed for production dispatch with no legacy normalization.
Only a valid explicitly classified unmanaged source-development or compatibility target MAY retain legacy capacity behavior, and failure to resolve a production-managed target SHALL NOT downgrade it to that exception.

Placement Capacity remains Node-owned and MAY further reduce capacity for one Model Placement.
For each placement, allocatable capacity SHALL be bounded by both that Placement Capacity and the shared authority decision's available slots.
While the decision is `f11_enforcing`, acquisition of new Controller-accounted Allocations across every placement and queue lane for one Node SHALL NOT cause the total to exceed its Effective Dispatch Limit.
While the decision is `legacy_pre_cutover`, the temporary centrally calculated legacy slots plus serialized temporary claims remain the aggregate bound and Effective Dispatch Limit remains counterfactual `0`.
A ceiling reduction MAY temporarily leave accepted, running, or streaming allocations above the new Effective Dispatch Limit while they drain naturally, but no new allocation may increase that total.
Configured base queue capacity and source-scoped lane capacity govern queue flow only and SHALL NOT create production dispatch authority.

While the authority decision is `f11_enforcing`, lowering a Controller Dispatch Ceiling SHALL affect new allocation and pre-acceptance revalidation immediately, SHALL NOT forcibly cancel accepted, running, or streaming work solely because of the reduction, and SHALL leave Dispatch Headroom at `0` while Controller-accounted Allocation is greater than or equal to the lowered Effective Dispatch Limit.
Accepted, running, and streaming work SHALL finish naturally, and new allocation MAY resume only after Dispatch Headroom becomes positive.
Pre-acceptance work that no longer passes serialized held-allocation revalidation after `request_step.started` SHALL release its allocation effectively once, persist the applicable closed attempt outcome under §5.9, and fail without queue re-entry.
On attempt 1, ordinary scarcity records `not_retryable`; on attempt 2, every such non-cancellation failure records `retry_exhausted` while preserving its specific failure class.
While the authority decision is `f11_enforcing`, raising a Controller Dispatch Ceiling SHALL create no allocation by itself, SHALL remain bounded by the current Runtime Concurrency Enforcement Limit and all other eligibility gates, and MAY wake queued work only after shared capacity re-evaluation.

Existing Nodes SHALL migrate through policy states `shadow_legacy`, `approved_explicit`, and `enforcing` in that order.
`shadow_legacy` SHALL apply only to non-removed production Nodes whose Node Admission committed before the F11 expand migration, identified by durable `admitted_at` or equivalent admission history, and SHALL be a temporary counterfactual observation state, not a steady-state authority mode.
During `shadow_legacy`, the present policy record's intentionally absent ceiling computes counterfactual Effective Dispatch Limit `0` while named legacy behavior continues temporarily and mismatch diagnostics remain non-authoritative.
Operator approval SHALL persist an explicit ceiling, actor, timestamp, and reason before advancing the policy to `approved_explicit`.
No Node SHALL enter `enforcing` until every named capacity consumer uses the shared evaluation.
Enforcement cutover SHALL run under the migration advisory lock and one Postgres transaction that locks the cluster-wide phase, verifies every non-removed admitted production Node has approved policy, verifies fresh compatible all-consumers-ready evidence for every non-retired Controller instance, advances approved policies, records cutover actor, time, reason, and required contract version, and changes the phase to `enforcing`.
Before that transaction, cutover SHALL enter a visible `quiescing` operation under the Controller-local cluster transition barrier, refuse new temporary legacy claims, and allow existing temporary claims and accepted work to finish without forced cancellation.
Cutover SHALL proceed only after every non-removed admitted production Node has zero live temporary legacy claims and a new scheduler-fresh aggregate Runtime Endpoint Observation reporting `active_request_count = 0`.
Excluding a removed tombstone SHALL require durable lifecycle `removed`, revoked trust, and the existing successful removal audit; no other lifecycle state or unreachable Node gains an implicit exclusion.
Cutover SHALL then acquire every Node acceptance gate in stable order, revalidate quiescence and every other precondition, and hold those gates through transaction commit and local phase publication.
Cutover SHALL NOT adopt live legacy work into Controller-accounted Allocation or infer any durable policy from telemetry.
If quiescence times out, evidence becomes stale, or any precondition fails, Orchard SHALL leave phase and policies unchanged, reopen legacy dispatch, and expose the blocker.
If any precondition or write fails, neither the phase nor any policy transition SHALL commit.
At enforcement cutover, every otherwise eligible non-removed admitted production Node SHALL have an operator-approved ceiling and advance atomically to `enforcing`, or fail closed with Effective Dispatch Limit `0`.
After enforcement cutover, each new admission SHALL persist an `enforcing` explicit policy in the admission transaction and SHALL fail closed if that write or its audit record fails.
Every Controller SHALL read the durable phase at boot, readiness, Active-role acquisition, admission mutation, and dispatch evaluation.
A Controller that cannot enforce the marker's required contract version SHALL fail readiness and refuse admission and dispatch after cutover rather than treating the cluster as `pre_cutover`.
The migration SHALL NOT assign existing Nodes a ceiling of `1`, infer a ceiling from telemetry, or treat a missing policy record as legacy state.

Operator diagnostics SHALL expose durable enforcement phase, policy state, normalized target management class, authority decision, Runtime Concurrency Enforcement Limit, Controller Dispatch Ceiling, Effective Dispatch Limit, Controller-accounted Allocation, Dispatch Headroom, Placement Capacity, decision-specific available slots, eligibility, the relevant observation time, and stable reason codes.
While the decision is `legacy_pre_cutover`, diagnostics SHALL additionally expose `legacy_pre_cutover_available_slots`, live temporary legacy claim count, and cutover quiescing state as temporary non-authoritative migration evidence and SHALL keep Effective Dispatch Limit and Dispatch Headroom at `0`.
Stable capacity reason codes SHALL include `node_health_degraded`, `controller_dispatch_ceiling_missing`, `controller_dispatch_ceiling_invalid`, `controller_dispatch_ceiling_not_yet_enforcing`, `controller_dispatch_ceiling_zero`, `controller_dispatch_ceiling_exhausted`, `runtime_concurrency_limit_unknown`, `runtime_concurrency_limit_exhausted`, `dispatch_headroom_exhausted`, `placement_capacity_exhausted`, `dispatch_capacity_revalidation_failed`, `dispatch_capacity_pre_cutover_legacy`, `dispatch_capacity_phase_policy_mismatch`, `dispatch_capacity_cutover_quiescing`, `dispatch_capacity_cutover_occupancy_not_zero`, `runtime_endpoint_management_class_missing`, `runtime_endpoint_management_class_invalid`, `dispatch_ceiling_shadow_mismatch`, and `dispatch_ceiling_not_approved`.
A consumer that cannot assemble the Controller-owned facts required for the shared evaluation from current authenticated evidence SHALL fail closed and expose the scheduler rejection reason code `dispatch_capacity_facts_unavailable` rather than falling back to telemetry or a permissive default.
Serialized per-Node capacity policy mutation that cannot acquire the Node acceptance gate SHALL fail fast with `dispatch_capacity_acceptance_gate_busy` rather than block behind an in-flight dispatch.
The term `Admitted Capacity` SHALL NOT be used for any of these concepts.

Durable dispatch permits, leadership epochs and dispatch fencing, crash or handover reservation recovery, durable quarantine survival across Controller restart, audited quarantine release after verified reconciliation, and compromised-node occupancy integrity are M7-aligned follow-ups outside F11.
Malformed aggregate active-count handling, queue-source expiry and reservation provenance, and configured-base versus live-capacity provenance are separate follow-ups outside F11.

### 4.7 Pool model

v1 SHALL support **exactly one pool per node**.

Pool examples:

* `default`
* `high-memory`
* `canary`
* `maintenance-spare`

Pools influence:

* allowed/denied scheduling
* pool preference score
* desired pinned models
* default queue/cold-load behavior

### 4.8 Drain behavior

`drain` means:

1. mark node `draining`
2. scheduler excludes it
3. existing requests continue
4. when active requests reach zero:

   * if `enter_maintenance=true`, transition to `maintenance`
   * else remain `cordoned`

Drain request parameters:

* `deadline_ms` default `300000`
* `cancel_after_deadline` default `false`
* `enter_maintenance` default `true`

If deadline expires and `cancel_after_deadline=true`:

* controller SHALL cancel remaining active requests
* node transitions to `maintenance` if cancellation succeeds

### 4.9 Node agent responsibilities

Node agent SHALL:

* register with controller
* renew node certificate
* heartbeat every 2s
* retrieve, protect, stage, rotate, and revoke scoped BEAM Peer Grants for admitted production connections
* expose the first-party Runtime Endpoint through production TLS distribution after certificate and Peer Grant authorization succeeds
* expose the current gRPC Runtime Endpoint compatibility service
* download/verify model artifacts
* manage worker subprocess lifecycle
* obtain host-observed device inventory and health through a capability-provider contract distinct from runtime-provider evidence
* report immediate state changes
* collect diagnostics
* cancel orphaned requests when controller session disappears

### 4.10 Local worker contract

Node agent SHALL own Worker Runtime subprocess lifecycle, model loading, execution, cancellation, capacity observation, diagnostics, and cleanup.
The Worker Runtime protocol source, version policy, binding generation authority and output manifest, descriptor golden, and conformance fixtures SHALL have provider-neutral ownership outside any runtime-provider implementation.
Generated consumer copies MAY live under a runtime-provider package when their only authority is the neutral generator and required validation checks every committed output for drift.
Local workers SHOULD speak gRPC over Unix domain sockets, with this minimal internal contract:

* `LoadModel`
* `UnloadModel`
* `Generate`
* `Cancel`
* `Status`

This local API is internal-only and not part of the public compatibility contract.
Before capability evidence authorizes work, a Worker Runtime provider SHALL report its protocol version, provider identity and version, supported artifact formats, runtime features, acceleration implementations, device bindings, memory semantics, concurrency, and cache capabilities.
Unknown, malformed, absent, stale, or incompatible required evidence MUST NOT prove capability eligibility.
That evidence travels as one additive provider-neutral capability envelope on the worker `Status` response; the Node Agent alone owns its receipt time, freshness, validity classification, and exact-profile evaluation, and that local evaluation SHALL remain diagnostic-only, altering no readiness, admission, dispatch, scheduling, retry, or Runtime Endpoint behavior until a separately reviewed cutover makes normalized evidence authoritative.
The canonical protocol source is `proto/orchard/worker/v1/worker_runtime.proto`; supported Python and Elixir consumer bindings are generated from it and checked byte-for-byte in required validation.

---

## 5. Scheduler Design

### 5.1 Scheduling objectives

The scheduler SHALL optimize for:

1. correctness and policy compliance
2. avoiding failed dispatches
3. lowest latency
4. model reuse / warm residency
5. deterministic tie-breaking

### 5.2 Admission control order

Admission MUST execute in this order:

1. authenticate principal
2. authorize endpoint
3. resolve model
4. canonicalize input
5. tokenize and compute exact input tokens
6. enforce model context limit
7. enforce tenant model access
8. enforce tenant quotas
9. enforce tenant concurrency
10. create request record
11. attempt schedule or enqueue

For service-account-owned API Tokens, authentication SHALL resolve the owning Service Account as `principal_type = service_account` and the owning Tenant as the effective Tenant before endpoint authorization.
For tenant-direct API Keys, authentication SHALL resolve `principal_type = tenant`.
Public inference endpoint authorization for service-account principals SHALL require tenant-scoped `inference_client` access before model resolution, tenant quota admission, or queue admission.

Failure precedence:

1. auth failure
2. authorization failure
3. invalid request
4. model not found
5. model not authorized
6. quota exceeded
7. queue full / cluster busy

### 5.3 Quota model

Quotas are tenant-scoped. Supported limits:

* requests per minute
* concurrent active requests
* input tokens per day
* output tokens per day
* max context tokens per request
* max output tokens per request
* max queue wait ms

Resolved concurrent active request limits SHALL appear on canonical requests as `resolved_policy.max_active_requests`.
Quota admission SHALL serialize per tenant via advisory transaction lock on hashed tenant id.

Admission accounting:

* input tokens are charged exactly at admission
* output tokens are **reserved** at admission using requested `max_output_tokens`
* on completion:

  * actual output tokens charged
  * unused reserved output tokens released
* on an unsuccessful attempt before Output Commitment:

  * the reservation remains held when Automatic Attempt Retry will start
  * when the logical Request terminalizes, proven generated output tokens from the selected attempt remain charged even if no output committed, and only the unused reservation is released
  * the reservation is fully released only when the selected attempt generated zero output tokens
* on partial failure after Output Commitment:

  * output tokens generated by the selected attempt remain charged, including hidden or selected public reasoning tokens
  * unused reserved output tokens released

Input-token accounting SHALL occur once for the logical Request.
Attempt 1 SHALL NOT release or reacquire quota when attempt 2 will run.
Final usage and quota reconciliation SHALL occur exactly once when the logical Request terminalizes, using the terminal attempt under the existing quota policy.
Logical Request output usage SHALL be the exact total output-token count generated by the selected terminal attempt when the terminal contract proves it, including both reasoning and final-answer tokens.
A Controller-synthesized failure that cannot prove the terminal total SHALL use the latest validated cumulative count with `output_usage_status = lower_bound`.
Logical Request accounting SHALL copy the selected terminal attempt's `output_usage_status`, and quota reconciliation SHALL use the associated count without presenting a lower bound as exact.
Successful public responses SHALL report exact usage only.
A failed Request with lower-bound usage SHALL retain that non-content status for quota reconciliation, metrics, and audit, but MUST NOT serialize the lower bound through an existing public field that implies an exact total.
Tokens from a discarded retry attempt SHALL remain physical attempt telemetry and MUST NOT be added to the logical Request's public usage or charged a second time.
When the selected Worker Runtime can report an exact reasoning-token subset, Orchard MAY retain that subset as internal additive non-content usage detail.
Orchard MUST NOT transmit or expose a reasoning-token subset until separately accepted presence-aware Runtime Endpoint and public API usage contracts define the encoding and preserve exact zero versus unknown across `N` and `N-1`, hashing, and replay.
An exact reasoning-token count of zero SHALL remain distinct from an unavailable or unproven reasoning-token count.
Orchard MUST NOT estimate reasoning-token usage by retokenizing decoded text or subtracting an unproven final-answer count from the total.

### 5.4 Queue model

When a request cannot be granted immediately because no live Runtime Endpoint, node, or placement capacity is available, or because the tenant active request cap is exhausted:

* request enters tenant FIFO queue
* max wait defaults to `3000 ms`
* max queued requests per tenant defaults to `32`
* max active requests per tenant defaults to unlimited unless controller queue configuration or a resolved policy supplies a cap

When `resolved_policy.max_active_requests` or controller queue configuration supplies a tenant active cap, controller queue admission SHALL queue same-tenant requests once active grants for that tenant reach the limit, even if the requested model/version lane or a placement still has spare capacity.
Recovered in-flight grants SHALL count against that tenant active cap until their Request reaches a terminal state.

With controller queue admission enabled, a scheduler `cluster_busy` or `model_busy` result observed after a static queue grant SHALL be treated as queue-waitable live node, requested model path, or placement capacity exhaustion.
The controller SHALL return the request to the same controller queue lane for the requested model/version under the original max queue wait budget instead of extending the deadline.
Requeued grants SHALL preserve the original `queued_at`, admission order, and queue deadline.
The queue manager MAY defer the requeued lane until the next poll interval before re-granting to avoid a tight scheduler retry loop.
If live node capacity, requested model path capacity, placement capacity, or tenant active capacity does not become available before that deadline, the terminal public outcome SHALL be `queue_timeout`.
With controller queue admission disabled, `cluster_busy` and `model_busy` remain immediate admission failures.

Queue discipline:

* one FIFO queue per tenant
* cross-tenant selection uses weighted round-robin
* cross-tenant promotion skips tenants whose head entry lacks lane capacity or tenant active capacity without reordering that tenant's FIFO queue
* tenant weight default = 1
* within tenant, strict FIFO

Scheduler wake-up triggers:

* new request admitted
* request finished/cancelled
* heartbeat state change
* placement state change
* periodic tick every `100 ms` while queue non-empty

Queue lane capacity SHALL be the configured base lane capacity plus live capacity sources. Node-owned live sources are process-local scheduling hints owned by accepted-observation ingestion after the observation transaction commits; a MultiNode request snapshot SHALL NOT publish, rebuild, or clear them. The ingestion consumer SHALL rerun the shared capacity evaluation before refreshing matching source-scoped loaded/cold contributions, and positive contributions remain bounded by its available slots and by one unreserved cold slot per lane per node observation. Live refreshes MAY wake queued requests without a new admission event.

Identity rejection, transport failure, heartbeat-age demotion, lifecycle, health, or freshness loss, malformed or unavailable capacity facts, failed observation commit, and evaluator or consumer failure SHALL clear affected sources. BEAM observations may refresh them only when the target resolves to the same persisted trusted active Node; address-only or mismatched observations, Runtime Endpoint Admission Candidates, and explicitly unmanaged compatibility probes SHALL NOT publish production Node-owned sources. QueueManager or Controller restart starts with no Node-owned source contributions; no heartbeat-history replay or request snapshot reconstructs them, and only a later accepted eligible observation may repopulate them.

Configured base lane capacity remains separate. Neither it nor a live capacity source authorizes production dispatch unless the shared capacity authority decision is `legacy_pre_cutover` with positive centrally calculated legacy slots or `f11_enforcing` with positive Dispatch Headroom at allocation time.

### 5.5 Eligibility filter

The heterogeneous scheduling target SHALL match model artifact requirements to fresh authenticated runtime-provider capabilities, acceleration capabilities, device resources, memory domains, and Controller policy.
Scheduling MUST NOT authorize work solely from operating-system names, `worker_backend` strings, transport type, or inferred provider defaults.
Missing, malformed, stale, conflicting, unauthenticated, or version-incompatible evidence required by an accepted capability contract SHALL fail closed with stable provider-neutral explanations.

This target does not change current production eligibility in this contract-only change.
Normalized capability evidence SHALL be introduced additively and compared diagnostically before a separately reviewed behavior change makes it authoritative.
Until that cutover, omitted new fields MUST NOT create a new rejection path beyond the current eligibility contract below.

For each production MultiNode scheduling attempt, the candidate universe SHALL be the exact intersection of the effective normalized targets returned by `Inference.runtime_endpoint_targets/0`, the certificate-backed active inventory returned by `Nodes.active_runtime_endpoint_targets/0`, and the latest accepted scheduler-fresh `node_heartbeats` rows whose Node and normalized target identities match. A fresh row does not admit an unconfigured, inactive, untrusted, address-only, removed, reconfigured, or identity-mismatched target.

The scheduler SHALL obtain one immutable request-scoped Postgres snapshot with one statement or equivalent read-transaction semantics, deterministically selecting the latest accepted row per intersected target by descending `observed_at` and then descending row identity. Per-Node observation times may differ; both `nodes.last_heartbeat_at` and the selected row's `observed_at` SHALL satisfy `node_freshness_threshold_ms` at query time. Controller or scheduler restart requires no production candidate-cache hydration; the next attempt reads Postgres.

The explicitly unmanaged static compatibility branch is available only when static fallback is enabled, trusted admitted/active inventory is confirmed empty, and the normalized target exactly satisfies `Inference.static_runtime_target?/1`. It MAY run one bounded compatibility status-probe wave over at most the first four deduplicated configured targets, with one connect/status attempt per target for the entire logical request through terminal completion, the existing **2000 ms** per-target timeout, and no retry; it SHOULD run as one bounded wave rather than serially multiplying that timeout. Loading, final revalidation, failure handling, execution, and terminal completion MUST NOT initiate another status attempt for that target. It MUST NOT run when trusted inventory exists, inventory availability cannot be proven, or the production snapshot fails, and it does not become trusted inventory or production authority.

Automatic Attempt Retry SHALL NOT reallocate that probe budget. Alternate scheduling for attempt 2 SHALL NOT initiate a second compatibility status-probe wave or any further connect/status attempt, because the existing budget already covers the entire logical request through terminal completion. A logical Request whose attempt 1 was dispatched to an explicitly unmanaged compatibility candidate SHALL therefore start no attempt 2: its retry decision SHALL resolve to `no_alternative_node` unless an earlier reason in the §5.8 decline precedence applies, preserving attempt 1's stable public failure without queue re-entry or deadline extension.

Production scheduling and dispatch SHALL perform no inline Runtime Endpoint status probe anywhere on the request path; the bounded explicitly unmanaged compatibility wave and the §7.5.3a bounded negotiated reasoning live-observation wave are its only exceptions, and neither becomes trusted inventory or production capacity authority. Database unavailability, incomplete reads, or absent usable facts SHALL fail closed without stale process memory or the unmanaged compatibility branch.

A node is eligible only if all conditions are true:

* node state = `active`
* node health = `healthy`, or node health in `{healthy, degraded}` while the shared capacity authority decision is `legacy_pre_cutover`
* pool is allowed by routing policy
* model format is supported by node runtime
* node has enough memory headroom
* the shared capacity authority decision is `legacy_pre_cutover` with positive centrally calculated legacy slots or `f11_enforcing` with positive Dispatch Headroom
* model placement concurrency not exceeded
* no placement/node circuit breaker suppresses dispatch

Runtime Endpoint Admission Candidates are never eligible nodes.
Unresolved, untrusted, rejected, provisioned, registered, or admitted-but-not-active candidates and Nodes SHALL be excluded before candidate tiering and scoring.
For attempt 2, `exclude_node_ids` SHALL contain attempt 1's stable Node identity and SHALL be applied as a hard eligibility filter before tiering, ranking, scoring, and prefix-cache scoring.
A different target address for the same Node SHALL NOT satisfy this exclusion.
An unresolved or mismatched Node identity SHALL fail closed with `identity_unresolved`, and the orchestrator SHALL reject any scheduler result that selects an excluded Node.
An excluded Node SHALL appear in the §7.3.5 scheduler explanation as a rejected candidate with the stable reason code `previous_attempt_node_excluded`.
The `ScorePrefixCache` budgets in §7.5.3 remain per logical Request and SHALL NOT be reallocated per attempt; attempt 2 SHALL issue prefix-cache scoring only within the unconsumed remainder of that budget and SHALL otherwise rank fail-open on deterministic base order.

Memory eligibility formula:

```text
required_bytes =
  model_load_bytes_if_not_loaded
  + (input_tokens * model.prefill_workspace_bytes_per_token)
  + (max_output_tokens * model.kv_cache_bytes_per_token)
  + safety_margin_bytes

safety_margin_bytes = max(2 GiB, 10% of physical_memory_bytes)
```

Eligibility condition:

```text
available_memory_bytes >= required_bytes
```

Endpoint node concurrency is not exceeded only when the shared capacity evaluation returns `legacy_pre_cutover` with positive centrally calculated legacy slots or `f11_enforcing` with Dispatch Headroom greater than `0`.
`fail_closed` never satisfies this condition.
Under `f11_enforcing`, a degraded, unhealthy, unreachable, non-Active, untrusted, scheduler-stale, or policy-missing admitted production Node SHALL have Effective Dispatch Limit `0` and SHALL be ineligible for new work.
Model placement concurrency is evaluated independently through valid matching Placement Capacity.
Both endpoint-level aggregate capacity and requested-placement capacity must remain available for a loaded candidate to be eligible.
Scheduler decisions MAY include `queue_lane_capacity` when live loaded-placement capacity or eligible cold Runtime Endpoint capacity leaves room for the requested lane.
Loaded candidate contribution SHALL be constrained by both requested-placement capacity and the shared authority decision's available slots.
Cold candidate contribution SHALL count only candidates whose shared authority decision has positive available slots.
Omitted `queue_lane_capacity` means the controller queue must use its conservative configured capacity.

### 5.6 Candidate tiers

Eligible nodes are grouped into tiers:

* **Tier 0: loaded**

  * placement state = `loaded`

* **Tier 1: cached**

  * placement state in `cached`, `downloaded`

* **Tier 2: cold**

  * placement absent, but artifact available and expected load time <= `max_cold_start_ms`

Tier selection rule:

* if any Tier 0 candidates exist, ignore Tier 1 and Tier 2
* else if any Tier 1 candidates exist, ignore Tier 2
* else consider Tier 2

An explicit `final_only` or `reasoning_structured` Request is the sole exception to that rule.
Tier 1 and Tier 2 candidates SHALL be ineligible for it, `residency_preference` and `max_cold_start_ms` SHALL NOT widen that candidate set, and Orchard SHALL NOT descend to Tier 1 or Tier 2 to discover or acquire reasoning support.
Its §7.5.3a narrow reasoning-specific eligibility predicate SHALL NOT run during tiering, and capacity eligibility SHALL NOT narrow what that predicate may observe.
The predicate's universe SHALL be every loaded placement of the requested model on a scheduler-fresh active trusted Node that satisfies the §5.5 health condition exactly as ordinary scheduling states it — `healthy`, or `degraded` while the shared capacity authority decision is `legacy_pre_cutover` — so the probe gate tightens with that existing cutover rather than diverging from it.
That universe SHALL additionally include placements ordinary §5.5 eligibility excludes solely because aggregate slots or Dispatch Headroom are exhausted, placement concurrency is exceeded, or tenant active capacity is exhausted, and SHALL be ordered by the §5.7 ranking as it would apply to those placements with the deterministic lexicographic `node_id` tie-break last.
A Node that is not scheduler-fresh, fails that health condition, or is suppressed by either §5.10 breaker SHALL NOT be probed, and breaker suppression SHALL be read at both scopes §5.5 already enforces: the node-level breaker and the `(node, model)` placement-level breaker.
A withheld target's reasoning support stays unknown rather than disproven, and probing SHALL NOT circumvent §5.10 suppression.
The predicate SHALL resolve to the highest-ranked placement that proves the exact tuple, and ordinary §5.5 eligibility SHALL then decide whether that placement can be dispatched now.
When a proving placement exists but cannot be dispatched because aggregate slots or Dispatch Headroom are exhausted, placement concurrency is exceeded, or tenant active capacity is exhausted, and likewise whenever any loaded placement's reasoning support remains unknown through an unknown-class probe result under §7.5.3a, an elapsed wave deadline, or a withheld target, the Request SHALL keep its existing `cluster_busy` or `model_busy` outcome and stay queue-waitable under §5.4's controller queue contract; that is transient pre-dispatch unavailability, and no such placement SHALL be read as proof of no reasoning support.
Only when the requested model has no loaded placement on an active trusted Node, or when every loaded placement of that model was probed and each returned confirmed non-support under §7.5.3a's classes, SHALL Orchard fail the Request closed before dispatch through the §7.2.7 `503 server_error` plus `runtime_incompatible` mapping.
That parity covers the queue outcome semantics only, not deadline duration: §12.4 still resolves a negotiated Request's deadline through the loaded-only formula, so queue wait and wave time consume the same remaining request budget.

### 5.7 Scoring formula

The heterogeneous scheduling target SHALL represent memory as versioned device resources and explicit memory domains such as unified memory, discrete device memory, and system memory.
Provider-specific working-set, VRAM, or host-memory fields MAY feed adapter normalization but MUST NOT become the portable scheduling vocabulary.
Any change from the current observe-only memory-ranking behavior to capability eligibility or enforcement requires a separately reviewed behavior change.

Within a tier, compute:

```text
score =
  pool_bonus
  + residency_bonus
  + mem_bonus
  + load_bonus
  + health_bonus
  + warmth_bonus
  - swap_penalty
```

Where:

* `pool_bonus`

  * 200 if preferred pool
  * 50 if allowed pool
  * 0 otherwise

* `residency_bonus`

  * 500 for `loaded`
  * 200 for `cached`
  * 0 for cold

* `mem_bonus`

  * `floor(100 * free_after_request / physical_memory_bytes)`
  * bounded `0..100`

* `load_bonus`

  * `100 - floor(100 * active_requests / node_max_concurrency)`

* `health_bonus`

  * 30 if `healthy`
  * 0 if `degraded`

* `warmth_bonus`

  * 20 if same model used on node in last 5 minutes

* `swap_penalty`

  * 50 if swap used > 2 GiB
  * 0 otherwise

Tie-break order:

1. higher score
2. lower active_requests
3. lexicographically smaller `node_id`

The score/bonus model above is the broader M4 scheduling contract. The current bounded Phase 4C/4E implementation uses the late tie-break order below and does not introduce threshold-based memory admission or request rejection.

Controller-side cache-affinity, safe-tokenization capable-worker preference, Phase 4D tie-only scoring, and memory-admission ranking for the bounded current implementation SHALL use the following late tie-break order among otherwise schedulable candidates in the same residency/load/health position:

1. loaded model already present
2. lower active request count for the requested placement when valid matching Placement Capacity is available, otherwise lower endpoint aggregate `active_request_count`
3. healthier node (`healthy` before `degraded`)
4. live prefix-cache fingerprint match, only when both `cache_affinity.enabled=true` and `cache_affinity.live_fingerprint_match_enabled=true` and bounded non-persisted evidence is available; production snapshot candidates cannot derive this signal from their sanitized payload and remain rank-neutral at this step
5. historical cache-affinity match from recent completed placements, when cache affinity is enabled
6. safe-tokenization capable-worker preference, only when `tokenizer_safe_mode_prefer_capable=true`, `tokenizer_safe_mode` is not `:off`, and the fresh durable scheduler snapshot reports `supports_prompt_token_ids=true`
7. explicit memory-headroom observation, only when `memory_admission.enabled=true` and the candidate's matching `RuntimeMemoryBudget` has `status_code = "ok"` and `headroom_available = true`
8. lexicographically smaller `node_id`

Default Phase 4D runtime behavior remains observe-only (`prefix_cache_scoring.ranking_mode = :observe_only`) and rank-neutral.

When `prefix_cache_scoring.enabled=true`, `cache_affinity.enabled=true`, `cache_affinity.live_fingerprint_match_enabled=true`, and `prefix_cache_scoring.ranking_mode = :tie_only`, the scheduler MAY apply one bounded conditional score step immediately before step 8, only for the leading rank-equivalence group where steps 1–7 are equal and only deterministic `node_id` differs. Candidate scoring in this conditional step is capped at 2 (incumbent + challenger). The challenger MAY be promoted only when challenger score normalizes to `status_code = "ok"` with `resident_fingerprint_match = true` and `score_tier = "resident_fingerprint"`, and the incumbent score is comparable `ok` non-resident (`status_code = "ok"`, `resident_fingerprint_match = false`, and `score_tier` is `"no_match"` or `"recent_fingerprint_only"`). Any non-`ok`, timeout, unsupported, unavailable, `model_not_loaded`, `invalid_request`, missing, malformed, contradictory, or transport-failure score outcome for either candidate SHALL preserve base order fail-open and deterministic `node_id` fallback.

A live prefix-cache fingerprint match is a bounded, approximate warmth hint. It SHALL bias ranking only after health and before historical affinity; production snapshot candidates remain rank-neutral when the sanitized durable payload cannot provide the raw match. Request-specific `ScorePrefixCache` behavior remains subject to the selected-only/two-candidate limits in §7.5.3; those limits are per logical Request and SHALL span both Inference Attempts, so attempt 2 SHALL consume only their unconsumed remainder and SHALL rank without prefix-cache scoring once the Request budget is exhausted. It SHALL NOT introduce status or score fan-out. Safe-tokenization capable-worker preference is default-off and SHALL bias ranking only after live and historical cache-affinity signals and before memory-headroom admission. The memory-headroom observation is a bounded, positive-only hint. It SHALL bias ranking only after live cache-affinity, historical cache-affinity, and any enabled safe-tokenization capable-worker preference, and before deterministic `node_id`; candidates with absent, malformed, unavailable, or non-`ok` memory-budget telemetry remain schedulable and rank-neutral. Neither hint SHALL change node eligibility, request admission, queue ordering, public error contracts, or runtime concurrency.

### 5.8 Scheduling algorithm

```text
run_request(req):
  initial_schedule = schedule(req, exclude_node_ids = [])

  if initial_schedule is pre_start_busy:
    requeue_or_terminalize_under_original_queue_deadline(req, initial_schedule)
  else:
    attempt_1 = start_and_dispatch_attempt(req, initial_schedule.candidate)

    if attempt_1 succeeds:
      terminalize(req, attempt_1)
    else:
      retry_gates = evaluate_retry_gates_before_alternate_schedule(
        attempt_1,
        req.timeout_at
      )

      if retry_gates decline:
        terminalize(req, attempt_1)
      else:
        alternate_schedule = schedule(
          req,
          exclude_node_ids = [attempt_1.node_id]
        )
        decision = finalize_retry_decision(attempt_1, alternate_schedule)

        if decision permits retry:
          attempt_2 = start_and_dispatch_attempt(
            req,
            alternate_schedule.candidate
          )
          terminalize(req, attempt_2)
        else:
          terminalize(req, attempt_1)
```

Automatic Attempt Retry is an internal continuation of the same logical Request and SHALL be bounded to one second attempt.
The Controller SHALL assign `requests.timeout_at` once at Request creation and every scheduling, model-load, execution, cleanup, persistence, and retry action SHALL consume that same absolute deadline.
Model loading SHALL NOT extend the logical deadline, and a non-positive remaining budget SHALL prevent alternate scheduling or dispatch.
The same Request ID, canonical payload, body hash, idempotency scope, admission result, queue grant, quota reservation, Payload Capture Mode snapshot, and caller-visible response SHALL span both attempts.
A duplicate idempotent submission SHALL observe the existing Request as in progress throughout both attempts.

Output Commitment is the transport-independent point at which the Controller validates and observes the first non-empty delta selected for the logical public response.
For `projection = reasoning_structured`, the first selected public reasoning delta commits with `output_commitment_kind = reasoning`.
For `projection = final_only`, hidden reasoning does not commit output; the first non-empty final-text delta, valid tool-call delta with a stable non-empty tool-call identity, or content-bearing structured-output delta commits under the existing kind.
For `projection = legacy_blended`, the existing undifferentiated `OutputTextDelta` behavior remains unchanged, including JSON text used for structured output.
The Controller SHALL record Output Commitment before invoking the public event handler or serializer.
`Accepted`, `Progress`, `UsageUpdate`, empty deltas, hidden reasoning deltas, model-load events, and terminal failures SHALL NOT commit output.
Once output commits, Orchard SHALL NOT retry even when handler, serializer, or client delivery later fails.
Validated pre-commit events SHALL remain attempt-local until the retry decision is known.
When an event establishes Output Commitment, Orchard SHALL deliver all earlier buffered validated events in original order before exposing the committing event downstream.
When attempt 2 starts, attempt 1 buffered events SHALL be discarded from the logical public response.
When retry is declined or the final attempt completes without commitment, that final attempt's buffered events SHALL be delivered in original order.
A handler or serializer failure during a final buffered flush SHALL be a terminal non-retryable orchestration failure.
`first_token_at` SHALL remain a public-output timing field.
It SHALL record the first non-empty final-text delta for `final_only`, the first selected public reasoning or final-text delta for `reasoning_structured`, and the first non-empty legacy text delta for `legacy_blended`.
Hidden reasoning SHALL NOT set `first_token_at`, and tool or control events SHALL NOT redefine it as a generic commitment timestamp.

Retry SHALL fail closed and SHALL require attempt 1, no Output Commitment, remaining deadline, a live caller, resolved first-Node identity, resolved execution, affirmative capacity release, an explicitly retryable failure, and a different eligible Node.
A structured inference Runtime Endpoint `Failed` event SHALL require both `retryable: true` and one of the allowlisted stable transient codes `node_unavailable`, `node_timeout`, `runtime_unavailable`, `resource_exhausted`, `timeout`, `worker_unavailable`, or `worker_down`.
Model-load retry eligibility SHALL be based only on the normalized `ModelLoadFailure` category and SHALL be limited to `acquisition_failed`, `runtime_unavailable`, `resource_exhausted`, or `timeout`; a model-load failure code or message SHALL NOT independently authorize retry.
Unknown classes, unknown codes, deterministic failures, `retryable: false`, terminal-conformance failures, persistence failures, event-handler failures, orchestration failures, unresolved occupancy, and unresolved identity SHALL NOT retry.
Retry-capable failures are limited to resolved pre-acceptance Node or transport unavailability, the closed transient model-load categories, resolved worker or Node loss before acceptance, and an accepted pre-commit transient failure whose drain proves termination.

The attempt 1 decline precedence SHALL be `output_committed`, `cancelled`, `budget_exhausted`, `not_retryable`, `identity_unresolved`, `occupancy_unresolved`, then `no_alternative_node`.
An unsuccessful attempt 2 SHALL record `retry_exhausted` unless caller cancellation or disconnect caused its terminal outcome, in which case it SHALL record `cancelled`, or a Controller-detected negotiated acceptance-proof failure under §7.5.3a wins the terminal race before deadline terminalization is proven, in which case it SHALL record `not_retryable`; no attempt 2 outcome SHALL trigger a third attempt. An already-proven deadline terminalization retains `retry_exhausted`, and §3.7.1 owns the evaluable boundary for that exception.
If no different eligible Node exists, Orchard SHALL start no second attempt, SHALL NOT re-enter the queue or extend a budget, and SHALL preserve attempt 1's stable public failure while recording `no_alternative_node` as internal evidence.
Attempt 1's stable failure classification SHALL be fixed in its typed outcome, and any breaker-eligible failure effect SHALL be durable before the fresh alternate scheduler decision.
The alternate scheduler decision is side-effect-free with respect to dispatch.
Because `no_alternative_node` is part of the terminal attempt evidence, the final attempt 1 terminal event SHALL be appended only after this decision determines whether a different candidate exists.
After the alternate scheduler decision and before persisting either `no_alternative_node` or the attempt 2 start boundary, Orchard SHALL recheck caller liveness and the absolute deadline so `cancelled` and `budget_exhausted` retain precedence.
Failure of that post-scheduling gate SHALL terminalize attempt 1 with `cancelled` or `budget_exhausted` and SHALL append no attempt 2 evidence.
If the gate passes and no candidate exists, Orchard SHALL persist attempt 1 terminal evidence with `no_alternative_node`.
If the gate passes and a valid different candidate exists, Orchard SHALL atomically append attempt 1 terminal evidence with `retried` and attempt 2 started evidence.
After the atomic append and immediately before any attempt 2 dispatch side effect, Orchard SHALL recheck caller liveness and the absolute deadline to close the transaction-to-dispatch race.
Caller cancellation or disconnect at that post-start gate SHALL terminalize attempt 2 as `cancelled`; deadline exhaustion SHALL terminalize attempt 2 as `timed_out` with `retry_exhausted`; neither outcome SHALL dispatch or start a third attempt.
The effective Payload Capture Mode SHALL resolve before the first Request write and SHALL apply unchanged to every attempt.

### 5.9 Dispatch rules

A production candidate snapshot is selection evidence, not a dispatch permit. Production scheduling and dispatch SHALL NOT status-probe a Runtime Endpoint anywhere on the request path outside the bounded waves §5.5 enumerates as its only exceptions.

Dispatch sequence:

1. reserve request in request FSM (`scheduled`) for attempt 1; attempt 2 already holds `dispatching` from the §5.8 atomic start boundary under §3.6 and SHALL NOT re-enter `queued` or `scheduled`
2. confirm that the orchestrator has appended exactly one `request_step.started` event for the selected Inference Attempt; the dispatcher SHALL NOT append another
3. resolve trusted admitted production inventory and identity before applying configured classification, then consume the shared capacity authority decision; under `f11_enforcing`, atomically acquire or recognize exactly one Node-scoped Controller allocation under Dispatch Headroom, while under `legacy_pre_cutover`, acquire or recognize exactly one serialized Node-scoped temporary legacy claim under the centrally calculated slots; `fail_closed` SHALL NOT proceed to `ExecuteInference`
4. if placement not `loaded`, call `EnsureModelLoaded` while retaining the allocation
5. after load and immediately before execution, acquire the Node acceptance gate and re-run the same authority decision and Placement Capacity checks against the latest durable observation and current Controller-owned facts; `f11_enforcing` SHALL revalidate the recognized pre-acceptance allocation after excluding only that allocation from the allocation operand, while `legacy_pre_cutover` SHALL revalidate the recognized temporary claim after excluding only that claim from the claimed-allocation operand
6. if acquisition, the acceptance gate, or revalidation fails, release the allocation effectively once, persist the applicable closed attempt outcome from the retry rule below, and fail without queue re-entry
7. call `ExecuteInference`
8. wait for `accepted` while retaining the Node acceptance gate, or treat failure before `accepted` as pre-acceptance failure
9. after `accepted`, release the acceptance gate, retain the allocation or temporary legacy claim through terminal completion, and transition request to `running`

Only scheduler `cluster_busy` and `model_busy` outcomes that occur before this dispatch sequence and before `request_step.started` MAY use the existing same-lane requeue path.

For an initially cold explicitly unmanaged compatibility candidate, final revalidation SHALL consume valid matching Placement Capacity from the successful `EnsureModelLoaded` result while preserving the captured target and resolved Node identity, aggregate capacity, availability, health, observation time and freshness behavior, and explicit unmanaged classification. Missing, malformed, zero-maximum, invalid-model-reference, or model-mismatched post-load evidence SHALL fail closed before `ExecuteInference` under the existing revalidation failure contract and SHALL NOT cause another status attempt. For an initially loaded compatibility candidate, an absent additive load-result field SHALL NOT replace or invalidate captured valid matching Placement Capacity; valid newer matching evidence MAY replace it. Production snapshot revalidation remains governed by the latest durable observation and current Controller-owned facts.

Retry rule:

* automatic retry occurs at most once and produces only attempt 2
* retry is allowed only before Output Commitment and within the original absolute Request deadline
* attempt 2 performs a fresh scheduler decision with hard exclusion of attempt 1's durable Node identity
* attempt 2 acquisition SHALL occur only after attempt 1 execution and capacity ownership are affirmatively resolved
* every post-`request_step.started` capacity acquisition, acceptance-gate, or revalidation rejection is an attempt outcome and SHALL NOT re-enter the queue
* on attempt 1, ordinary post-start capacity scarcity records `not_retryable`, held-claim or quarantine uncertainty records `occupancy_unresolved`, and unresolved identity records `identity_unresolved`
* on either attempt, caller disconnect records `cancelled`
* on attempt 2, every other unsuccessful post-start capacity outcome records `retry_exhausted` while preserving its specific failure class and code
* an attempt 1 dispatched to an explicitly unmanaged compatibility candidate starts no attempt 2 and records `no_alternative_node` unless an earlier decline reason applies, because §5.5 grants that branch one status-probe wave for the entire logical request
* no different eligible Node preserves the original public failure and records `no_alternative_node`

Caller disconnect SHALL map consistently across pre-dispatch, capacity-gate, and runtime-drain phases to Request state `cancelled`, attempt event `request_step.cancelled` after an attempt starts, durable code `request_caller_disconnect`, retry decision `cancelled`, HTTP status `499` when a response remains deliverable, and public code `request_cancelled`.
Controller or process failure without caller cancellation SHALL remain `interrupted`.

Runtime Endpoint disconnect and channel cleanup failures are cleanup-only failures.
They SHALL be logged best-effort and MUST NOT overwrite an otherwise successful candidate evaluation, bounded compatibility probe, or dispatch result.

### 5.10 Circuit breakers

Node-level breaker:

* trigger: 3 dispatch failures in 60 seconds
* effect: scheduler suppresses node for 5 minutes

Placement-level breaker:

* trigger: 3 load failures for same `(node, model)` in 10 minutes
* effect: suppress cold/warm load on that node for 15 minutes

Operator MAY clear either breaker through Operator API.

Each actually run failed attempt SHALL contribute independently only when its stable failure class is already eligible for the applicable Node-level or placement-level breaker.

Breaker eligibility over the closed §3.7.1 `failure_class` vocabulary is:

* the Node-level breaker SHALL count an attempt failure only when its `failure_class` is `pre_acceptance_unavailable` or `worker_or_node_loss`, which are the dispatch failures its trigger already counts
* the placement-level breaker SHALL count an attempt failure only when its `failure_class` is `model_load_failure`, which is the load failure its trigger already counts
* `capacity_rejection`, `runtime_failure`, `terminal_conformance`, `cancellation`, `deadline`, `controller_failure`, `occupancy_unresolved`, and `identity_unresolved` SHALL NOT contribute to either breaker
* ordinary post-start capacity scarcity is `capacity_rejection` and SHALL NOT suppress a healthy but busy Node or placement
* an unsuccessful attempt SHALL contribute to at most one breaker

The failure SHALL be attributed to the Node or `(node, model)` placement that produced it.
Attempt 1 breaker effects SHALL be durable before attempt 2's fresh scheduler decision, and that decision SHALL respect any resulting suppression.
The retry decision and a declined retry SHALL NOT add a breaker event.
This attempt accounting SHALL NOT change breaker thresholds, windows, suppression durations, or the Operator clear path.

---

## 6. Model Lifecycle

### 6.1 Catalog model vs placement model

The system SHALL distinguish:

1. **Catalog state**: global metadata about a model artifact
2. **Placement state**: per-node residency state

### 6.2 Catalog states

Global catalog states:

* `registered`
* `active`
* `deprecated`
* `retired`

Meaning:

* `registered`: known to cluster, not yet tenant-visible
* `active`: schedulable and listable
* `deprecated`: schedulable but hidden by default in admin UX
* `retired`: not schedulable; retained for history only

### 6.3 Placement states

Per-node placement states:

```text
absent
  -> downloading
  -> downloaded
  -> verifying
  -> cached
  -> loading
  -> loaded
  -> unloading
  -> cached
  -> evicted
  -> absent

failure exit: -> failed
```

State meanings:

* `absent`: no local artifact
* `downloading`: artifact transfer in progress
* `downloaded`: transfer done, not yet checksum-verified
* `verifying`: checksum/signature check in progress
* `cached`: verified artifact on disk, not loaded in runtime
* `loading`: runtime loading model
* `loaded`: runtime ready to accept inference
* `unloading`: runtime shutting down
* `evicted`: artifact/cache explicitly evicted
* `failed`: most recent placement transition failed

### 6.4 Model bundle format

The target model contract SHALL represent artifact format independently from compatible runtime providers, acceleration implementations, and device-resource requirements.
An artifact MAY declare more than one compatible provider or acceleration requirement set.
Portable model policy MUST NOT rewrite artifact format as a runtime-provider name.

The current `format`, `adapter`, `min_agent_capability`, MLX manifest values other than the explicitly deprecated top-level `sha256`, database constraints, and accepted model bundles remain valid migration inputs.
They SHALL NOT be removed, reinterpreted, or made non-authoritative until additive replacements, backward decoding, data migration, and scheduler cutover pass separate review and acceptance.

Offline-importable model bundle SHALL be a tarball or directory with manifest:

```json
{
  "model_id": "llama-3.1-8b-instruct",
  "version": "mlx-q4-v1",
  "format": "mlx",
  "artifact_layout": "directory",
  "entrypoint": "weights/",
  "size_bytes": 1234567890,
  "resident_memory_bytes": 6442450944,
  "kv_cache_bytes_per_token": 16384,
  "prefill_workspace_bytes_per_token": 2048,
  "max_context_tokens": 32768,
  "capabilities": ["chat", "tool_calling", "json_mode"],
  "tokenizer": {
    "kind": "huggingface_tokenizer_json",
    "path": "tokenizer.json",
    "config_path": "tokenizer_config.json"
  },
  "chat_template": {
    "path": "chat_template.jinja",
    "sha256": "hex"
  },
  "safe_tokenization": {
    "control_tokens": ["</s>", "<operator_defined>", "<s>", "<|im_end|>", "<|im_start|>"],
    "extra_control_token_strings": ["<operator_defined>"],
    "catalog_sha256": "64-character lowercase hex",
    "catalog_source": {
      "added_tokens_count": 2,
      "config_singletons_count": 2,
      "additional_special_tokens_count": 0,
      "chat_template_literals_count": 2,
      "wrapper_tool_markers_count": 0,
      "extra_count": 1
    },
    "compatible": true,
    "template_compatible": true
  },
  "runtime_requirements": {
    "adapter": "mlx_lm",
    "min_agent_capability": "mlx"
  }
}
```

Top-level Model Manifest `sha256` is optional, deprecated compatibility metadata.
Supported consumers SHALL accept otherwise valid manifests with or without it and SHALL continue rejecting unknown keys.
When present, it SHALL be a non-empty string but SHALL NOT supply, override, or be compared with the authoritative Catalog Artifact Bundle digest.
BundleBuilder SHALL retain its current legacy emission during this compatibility phase.
Producer omission MUST be implemented only in a separate accepted change that cites repo-owned minimum-consumer-version evidence proving every supported consumer accepts omission.

A Model Hub-generated Artifact Bundle MAY carry an optional `tool_capability_evidence.json` sidecar without a manifest-version bump. The top-level Model Manifest remains closed so an N-1 Worker Runtime can load it unchanged. The sidecar SHALL be a closed typed object with `tool_calling` containing the source repository and exact immutable source revision, sorted unique base-model references as provenance only, tokenizer-config and chat-template SHA-256 values when present, the exact parser type when present, a closed boolean preflight result (`parser_recognized`, `definition_rendered`, and `history_rendered`), a result of `declared`, `unknown`, or `conflicted`, and `runtime_qualification: "not_established"`.

The Model Hub SHALL derive this sidecar only from the resolved repository/revision and downloaded bundle artifacts. It SHALL NOT infer capability from a model name, family-name substring, publisher tag, base-model reference, arbitrary model card text, generic tag absence, or a successful chat-only render. `declared` requires all three preflight booleans true: an exact known parser type, a bounded tool-definition render, and a bounded structured assistant function-call plus tool-result history render. The history render SHALL use the same contract-v3 safe argument normalization required by §3.5. `declared` is the only result that may place `tool_calling` in `capabilities`; `unknown` and `conflicted` SHALL remain chat-only. A Model Hub declaration is Catalog admission evidence only; it SHALL NOT establish runtime qualification, a support claim, or server-side tool execution.

Manifest `capabilities` alone SHALL NOT admit `tool_calling` for any bundle, including an offline-authored Model Bundle. Manifest parsing SHALL drop a `tool_calling` entry unless the same bundle carries a sidecar whose result is `declared`, and SHALL leave every other manifest capability unchanged. A `declared` sidecar whose manifest omits `tool_calling`, or whose preflight booleans are not all true, SHALL fail manifest validation rather than admit a partial tuple.

For every `declared` sidecar, bundle parsing SHALL verify both recorded digests against the manifest-selected tokenizer config and chat template, verify the parser declaration against that config, and rerun the bounded tokenizer-only tool preflight. Missing assets or digests, mismatches, unsuccessful renders, and unavailable preflight SHALL fail validation; producer-supplied booleans alone are not proof.

The importer SHALL validate and preserve the sidecar in the Artifact Bundle, copy it to the immutable Catalog model record, and reject duplicate `{model_id, version}` identities. It SHALL NOT mutate a Catalog row to repair a capability. The Console Model Hub SHALL offer an operator repair action that uses the normal download/build/import path against the same exact source revision and a distinct explicit Catalog version; the new manifest records the distinct Catalog version as its `version`, while the new sidecar SHALL continue to record the original source revision. Such reimport does not by itself transfer qualification or support evidence between artifacts.

Catalog versions SHALL be single path components without separators. Namespaced model IDs remain permitted, but an import destination SHALL NOT overlap or descend beneath an existing Artifact Bundle.

`models.artifact_sha256` SHALL remain the authoritative lowercase SHA-256 digest of the final stored Artifact Bundle after secure staging and all importer-owned mutations.
The existing digest algorithm recursively collects regular files, rejects symlinks and unsupported entries, sorts bundle-relative paths, and hashes each relative path followed by the file's exact bytes.
The digest domain SHALL include the relative path and exact final bytes of `manifest.json` and, when present, `tool_capability_evidence.json`.
The authoritative value SHALL NOT be written into `manifest.json`, because doing so would make the digest depend on its own encoded value.
This contract change SHALL NOT rehash existing Catalog rows or introduce a new digest algorithm.

Reasoning-generation support is an additive, versioned runtime capability bound to an exact model artifact and chat-template digest.
Its contract SHALL enumerate complete supported tuples containing generation policy, projection, parser family and version, template-render contract and version, Runtime Endpoint contract version, and event-binding version without relying on a model-name heuristic or a Cartesian product of independent lists.
Manifest compatibility and strict unknown-key handling SHALL follow the existing additive migration rules until an accepted manifest schema extension supplies typed fields.
An older manifest that omits reasoning capability remains valid but SHALL NOT prove support for an explicitly negotiated reasoning mode.
Repository-owned manual model qualification evidence is governance evidence only.
It is independent of runtime reasoning capability and MUST NOT become a manifest field, Runtime Endpoint capability, scheduling fact, or dispatch authority.
Conversely, an advertised runtime reasoning capability MUST NOT be interpreted as satisfying any separate manual qualification gate.

Manifest fields added for safe tokenization are optional and SHALL NOT require a
manifest version bump in the Phase 1 compatibility posture. Older manifests
that omit `tokenizer.config_path` and `safe_tokenization` remain valid. When a
bundle contains `tokenizer_config.json`, BundleBuilder SHALL derive
`tokenizer.config_path` as that bundle-relative path. When the file is absent,
the field SHALL be omitted.

`safe_tokenization.control_tokens` is the sorted, deduplicated effective
catalog of control-token strings known at bundle-build time. BundleBuilder
SHALL derive it from:

1. every string `content` in `tokenizer.json.added_tokens[]`, regardless of
   token metadata flags;
2. tokenizer config singleton token keys `bos_token`, `eos_token`, `pad_token`,
   `unk_token`, `cls_token`, `sep_token`, and `mask_token`, accepting either a
   string value or an object with string `content`;
3. `tokenizer_config.json.additional_special_tokens[]`, accepting string values
   and object values with string `content`;
4. control-token literal candidates found from chat-template sources;
5. static wrapper tool markers for known MLX-LM tool parser types; and
6. `extra_control_token_strings` supplied by supported bundle inputs, when any
   such input exists.

For source #4, accepted candidate patterns SHALL include:
- pipe-style angle markers such as `<|...|>`;
- XML-like opening and closing markers such as `<tool_call>` and `</tool_call>`;
- bracket-style markers such as `[INST]` and `[/INST]`.

Source #4 extraction SHALL scan Jinja template literal text plus string constants
that are part of rendered output expressions. String constants that appear only
in non-rendered control-flow/template statements are out of scope for source #4
cataloging.

Empty strings SHALL be dropped. The final catalog SHALL be deduplicated by exact
UTF-8 byte equality and sorted lexicographically by UTF-8 bytes. The
`catalog_sha256` value SHALL be the lowercase SHA-256 hex digest computed over
the final catalog with NUL separators:

```elixir
Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(Enum.intersperse(catalog, <<0>>))), case: :lower)
```

`safe_tokenization.catalog_source` SHALL contain exactly these non-negative
integer count fields: `added_tokens_count`, `config_singletons_count`,
`additional_special_tokens_count`, `chat_template_literals_count`,
`wrapper_tool_markers_count`, and `extra_count`. Counts are per-source
observations before cross-source deduplication; their sum is not required to
equal the final catalog length.

`extra_control_token_strings` is optional. When present, it SHALL be a sorted,
deduplicated list of non-empty strings, SHALL be a subset of
`safe_tokenization.control_tokens`, and contributes to `extra_count`.
`catalog_source.extra_count` SHALL equal the number of entries in
`extra_control_token_strings`; when `extra_control_token_strings` is absent,
`extra_count` SHALL be `0`.

When eager safe-tokenization preflight finds a chat-template incompatibility,
the `safe_tokenization` object SHALL carry a structured verdict such as:

```json
{
  "control_tokens": ["</s>", "<s>", "<|im_end|>", "<|im_start|>"],
  "catalog_sha256": "64-character lowercase hex",
  "catalog_source": {
    "added_tokens_count": 2,
    "config_singletons_count": 2,
    "additional_special_tokens_count": 0,
    "chat_template_literals_count": 0,
    "wrapper_tool_markers_count": 0,
    "extra_count": 0
  },
  "compatible": false,
  "template_compatible": false,
  "incompatibility_reason": {
    "category": "dual_render_mismatch",
    "leaf_class": "messages[0].content",
    "sentinel_index": 0,
    "first_diff_offset": 12
  }
}
```

Accepted `incompatibility_reason.category` values are
`per_codepoint_decode_mismatch`, `reserved_id_persists`,
`reserved_id_set_overlap`, `empty_literal`, and `dual_render_mismatch`.
`compatible`, `template_compatible`, and `incompatibility_reason` are written by
BundleBuilder and `Orchard.Models.Importer` at bundle-build or import time when
eager preflight is enabled. Runtime components SHALL NOT mutate bundle
manifests. Helper failure or timeout MUST omit these verdict fields entirely and
MUST NOT write JSON `null`.

For imported bundles, a manifest-authored positive declaration
(`compatible=true` and `template_compatible=true`) MAY be trusted only after the
import pipeline has validated bundle identity and structure. This trust lets the
importer skip redundant preflight and lets runtime seed the positive
compatibility cache, subject to the operator kill switch for manifest
compatibility declarations. Runtime drift detection is incremental: the controller
currently emits `[:orchard, :tokenizer, :catalog_drift]` when request-time partial
catalog extraction observes tokenizer special added tokens, tokenizer-config named
singletons, or additional special tokens absent from
`manifest.safe_tokenization.control_tokens`; full post-import tokenizer/template
drift detection, including removed entries and chat-template or wrapper-tool-marker
drift, remains deferred to a later hardening phase.

`resident_memory_bytes` is static manifest-derived metadata in the current
slice: it is a lower-bound/payload-size estimate derived from bundle artifacts
(for MLX safetensors bundles, prefer `model.safetensors.index.json`
`metadata.total_size`, then fail open to regular `.safetensors` file sizes when
index metadata is unavailable). It is not a runtime memory probe. This metadata
remains observe-only and SHALL NOT gate readiness, request admission, model
admission, scheduler eligibility, hosted-tool eligibility, or
`memory_budget_mode` enforcement. (`resident_memory_bytes` remains observe-only
regardless of `memory_budget_mode`; the worker-side enforce path below samples a
live memory signal rather than this static field.)

The worker-side `memory_budget_mode` (`ORCHARD_WORKER_MEMORY_BUDGET_MODE`) is
`disabled`, `observe` (default), or `enforce`:

* `disabled` — no memory-budget observation or enforcement.
* `observe` — publishes observe-only memory-budget telemetry only; no
  enforcement.
* `enforce` — in addition to observing, the worker samples a live memory signal
  and, under sustained memory pressure, aborts ALL active generations without
  unloading the model. Each aborted generation ends with a distinct retryable
  `memory_pressure_abort` terminal so operators can distinguish enforcement from
  other failures. Enforcement applies cooldown hysteresis between abort sweeps,
  and every enforcement gate is fail-open: an unavailable, missing, or failed
  memory sample SHALL NOT fail a generation on its own. Pressure is sampled at
  admission before backend prefill starts and per backend decode event. Prefill
  is not interruptible, so a request already in prefill is not aborted
  mid-prefill.

### 6.5 Model import

Models SHALL be imported via:

* Admin API metadata import
* CLI import from local path
* optional upload to controller artifact store

Import steps:

1. optionally verify transferred Model Bundle media against detached evidence obtained through an independently trusted channel
2. parse the manifest
3. verify required fields
4. securely stage the bundle and apply importer-owned manifest mutations
5. compute `models.artifact_sha256` over the final staged Artifact Bundle
6. store the Artifact Bundle in the controller artifact root
7. insert the Catalog record with the independently computed digest
8. mark Catalog state `registered`

Post-import verification SHALL recompute the digest over the final stored Artifact Bundle and compare it with the authoritative Catalog value or a trusted external export.
The importer SHALL NOT copy the legacy manifest `sha256` into the Catalog or compare that value with the Catalog digest.
Pre-import detached media verification and post-import Catalog verification are distinct checkpoints because importer-owned mutations may change the final stored tree.

### 6.6 Model publication

A model becomes tenant-visible only when:

* catalog state transitions `registered -> active`
* at least one tenant is granted access
* routing policy resolution exists or default applies

Publication SHALL NOT change `models.artifact_sha256` or promote legacy manifest `sha256` to authoritative state.

### 6.7 Model distribution

Distribution modes:

1. **controller-hosted artifacts**

   * node agents fetch bundle over internal mTLS HTTP/gRPC
2. **pre-staged local media**

   * operator imports bundle on each node
3. **shared offline path**

   * optional mounted path identical on all nodes

Air-gapped systems MUST support mode 1 and mode 2.
Operator-controlled pre-import media verification and post-import verification of the final controller-stored Artifact Bundle SHALL use the distinct checkpoints defined in §6.5 and §11.7, never the deprecated manifest field.
Node acquisition SHALL perform authoritative `Orchard.ArtifactBundle.tree_sha256/1` verification against the Catalog digest on first acquisition and whenever durable verification evidence is absent, invalid, path- or digest-mismatched, or inconsistent with the current cache inventory.
A Node MAY skip the full byte rehash only when a versioned receipt outside the Artifact Bundle binds the authoritative Catalog digest and canonical cache path to a complete, unchanged filesystem inventory of every directory and regular file.
The inventory SHALL reject symlinks and unsupported entries and SHALL include relative paths, types, sizes, modes, ownership, device and inode identity, link counts, and modification and change times.
Before authoritative hashing, the Node SHALL normalize every bundle directory and regular-file modification time to a reserved historical value without changing bundle bytes, then bind the resulting complete inventory after hashing.
An ordinary later write SHALL therefore change the bound metadata even when the portable filesystem change-time surface reports only whole-second resolution and the write occurs immediately.
Staging promotion MAY treat the cache-root directory metadata changed by the trusted rename as a one-time transition, but descendant inventory evidence SHALL remain stable and the published receipt SHALL bind the complete final root metadata.
The receipt is an acceleration hint, not a competing digest or trust root, and SHALL NOT be stored inside or otherwise alter the authoritative Artifact Bundle digest domain.
Any receipt read, validation, inventory, or stability failure SHALL fail closed to authoritative tree hashing.
Receipt content SHALL receive owner-only permissions before atomic publication, and any authoritative verification failure SHALL invalidate prior acceleration evidence.
Before normalizing an existing cache for full verification, the Node SHALL successfully remove its prior receipt and SHALL fail closed if revocation cannot be confirmed.
An operator SHALL be able to force authoritative verification for every cache load, bypassing receipts and refreshing them only after success.
Logs SHALL distinguish first or forced full verification, receipt-matched fast-path verification, receipt invalidation, and verification failure without including local artifact paths, source URIs, digests, or file inventory contents.
Signature verification and archive-container digest requirements remain outside this change.

### 6.8 Load/unload semantics

`EnsureModelLoaded` SHALL be idempotent.

A successful `EnsureModelLoaded` result MAY include Node-owned Placement Capacity for the exact requested model reference, with a non-negative active request count and positive maximum concurrency. The evidence SHALL use the same canonical validity rules as Placement Capacity from Runtime Endpoint Observations and MUST NOT require an additional Controller Runtime Endpoint status attempt. Failed or non-loaded results MUST NOT supply placement authority. Absent, malformed, zero-maximum, negative, invalid-model-reference, or otherwise invalid evidence SHALL normalize to missing and MUST NOT be fabricated.

This evidence is additive and optional for protocol compatibility. A new Controller receiving an old protobuf response or same-named BEAM result struct without the field or key SHALL treat it as missing without raising, and an old protobuf Controller MAY ignore evidence returned by a new agent.

Behavior:

* if already `loaded`, return success immediately
* if `loading`, wait for existing load to finish or timeout
* if `cached`, start runtime load
* if `absent`, download + verify + load if allowed
* if `failed`, only retry if breaker not open or forced by operator

`UnloadModel` SHALL:

* reject if active requests > 0 unless `force=true`
* stop runtime
* leave artifact in `cached` unless `evict=true`

### 6.9 Eviction policy

Eviction SHALL run when memory or disk pressure requires space.

Eviction order:

1. cached, not pinned, oldest `last_used_at`
2. loaded but idle, not pinned, oldest `last_used_at`

Never auto-evict:

* pinned placements
* placements with active requests

If insufficient space remains after eviction, load fails with `insufficient_memory`.

### 6.10 Prewarming and pinning

Admin MAY pin models:

* to a pool
* to a specific node

Placement reconciler SHALL run every 10 seconds:

* ensure pinned models are at least `cached`
* optionally `loaded` if policy says `preload=true`

If memory is insufficient for all pinned models:

* higher `pin_priority` wins
* loser remains `cached` if possible
* policy violation logged to operator channel and audit log

---

## 7. APIs

## 7.1 API surfaces

The platform SHALL expose five API surfaces:

1. **Public Inference API**

   * OpenAI-compatible
   * HTTPS JSON + SSE for public/client traffic in `reverse_proxy` and `direct_https` transport modes
   * loopback HTTP only in degraded `plain_http_localhost` mode for local development or break-glass recovery
   * bearer API keys

2. **Operator API**

   * runtime operations
   * HTTPS JSON for public/operator traffic in `reverse_proxy` and `direct_https` transport modes
   * loopback HTTP only in degraded `plain_http_localhost` mode for local development or break-glass recovery
   * enabled API Client with cluster-scoped `operator` or `admin` RoleBinding

3. **Admin API**

   * governance/configuration
   * HTTPS JSON for public/admin traffic in `reverse_proxy` and `direct_https` transport modes
   * loopback HTTP only in degraded `plain_http_localhost` mode for local development or break-glass recovery
   * enabled API Client with cluster-scoped `admin` RoleBinding; Tenant-admin machine admission remains deferred

4. **Developer Portal**

   * Workspace-scoped browser surface at `/portal/:organization_slug`
   * TLS-only in `reverse_proxy` and `direct_https` transport modes
   * unavailable in degraded `plain_http_localhost` mode
   * invite-only Portal User email-and-password authentication, separate from Console authentication and Public Inference Bearers

5. **Runtime Endpoint and Worker Interfaces**

   * controller↔Runtime Endpoint Interface for model readiness, inference execution, cancellation, status, runtime telemetry, and Placement Capacity
   * admitted first-party production Controller and Node Agent services use the BEAM Runtime Endpoint adapter under the production identity and authorization contract in §7.5 and §10.6
   * the certificate-backed gRPC Compatibility Adapter remains an explicit compatibility, diagnostics, recovery, external-adapter, and operator opt-out path
   * Worker Runtime Interface remains local to the Node Agent

---

### 7.2 Public Inference API

#### 7.2.1 Compatibility contract

The Public Inference API SHALL prioritize wire compatibility with OpenAI for:

* `GET /v1/models`
* `POST /v1/chat/completions`
* `POST /v1/responses`

`/v1/models` SHALL return objects shaped like OpenAI model list entries with `id`, `object`, `created`, and `owned_by`. ([OpenAI Developers][5])

Reasoning control is an Orchard extension whose canonical semantics are defined in §3.4.
The first reasoning-control release SHALL support an explicit request for `projection = final_only` on both Chat Completions and Responses when the exact model, template, parser, and Runtime Endpoint contract is compatible.
This specification intentionally reserves the concrete public request field names until an accepted API contract defines them, and Orchard MUST NOT expose an ad hoc field before that contract is accepted.
When the control is omitted, both endpoints SHALL preserve `model_default + legacy_blended` behavior across sync and streaming responses.
The first release SHALL reject Chat requests for raw structured reasoning output.
Public Responses structured reasoning items and events SHALL remain disabled until a later accepted contract defines their wire names, raw-versus-summary semantics, sync representation, event ordering, terminal behavior, capture, and replay.

#### 7.2.2 Authentication

Header:

```http
Authorization: Bearer <api_key>
```

The bearer credential MAY be a tenant-direct API Key or a service-account-owned API Token.
Tenant-direct API Keys SHALL resolve to the Tenant principal.
Service-account-owned API Tokens SHALL resolve to the owning Service Account principal while keeping the owning Tenant as the effective Tenant for model access, quotas, queues, usage accounting, retention, idempotency, and request persistence.
Valid API Tokens owned by disabled API Clients SHALL authenticate as known credentials and fail authorization with `403 forbidden`.
Missing, malformed, invalid, expired, or revoked bearer credentials SHALL fail authentication with `401 invalid_api_key`.

#### 7.2.3 `GET /v1/models`

Returns models visible to the caller’s tenant.

Response shape:

```json
{
  "object": "list",
  "data": [
    {
      "id": "llama-3.1-8b-instruct@mlx-q4-v1",
      "object": "model",
      "created": 1741392000,
      "owned_by": "local"
    }
  ]
}
```

Rules:

* only `active` catalog models
* only models authorized for caller tenant
* `created` = model catalog insertion timestamp as Unix seconds

#### 7.2.4 `POST /v1/chat/completions`

Supported request fields:

* `model` required
* `messages` required
* `temperature`
* `top_p`
* `max_tokens` or `max_completion_tokens`
* `stop`
* `stream`
* `user`
* `metadata`
* `tools` (function tools only; conditional on model capability)
* `tool_choice`
* `response_format` only `{"type":"json_object"}`
* `seed` only if runtime supports deterministic seed

Tool-calling request rules:

* only function tools are supported in v1
* base v1 chat tool calling is client-executed passthrough: emitted tool calls are returned to the caller, not executed by Orchard
* each request `tools` entry MAY be either an inline function definition or `{"type":"function","ref":"tool://<name>@<version>"}`
* the controller SHALL resolve registry refs before tokenization and dispatch; the runtime SHALL receive resolved function definitions only, never `tool://...` placeholders
* inline request tools SHALL NOT be executed server-side by the platform
* unresolved, inactive, or malformed registry refs SHALL be rejected as `400 invalid_request_error`
* requests that enable tool calling against a model without tool-calling capability SHALL return `400 invalid_request_error`
* `tool_choice` modes supported in v1:

  * `"none"` disables tool calling even if `tools` is supplied
  * `"auto"` allows the model to choose text or tool calls
  * `"required"` requires one or more tool calls or the request SHALL fail
  * `{"type":"function","function":{"name":"..."}}` requires emitted tool calls to use that function name

Supported roles:

* `system`
* `developer`
* `user`
* `assistant`
* `tool`

Supported content:

* plain string
* array of text parts only: `{"type":"text","text":"..."}`

Unsupported request fields SHALL return `400 unsupported_parameter`. Explicitly unsupported in v1:

* `n != 1`
* audio/modalities
* image input
* `logprobs`, `top_logprobs`
* platform-hosted or server-executed tools in chat completions
* `json_schema`
* `parallel_tool_calls=true`
* explicit structured prior-reasoning message content
* raw structured reasoning output

The internal runtime `TokenDelta` capability (§7.5.3 internal token-streaming wire semantics) SHALL NOT expose `logprobs` or `top_logprobs` on the public `/v1` API in v1; the restriction above remains in force regardless of that internal capability.

An accepted explicit final-only control SHALL cause `message.content` and `choices[0].delta.content` to contain final-answer text only.
An omitted control SHALL preserve the existing blended content behavior byte-for-byte at the public serializer boundary.
Orchard SHALL treat every ordinary assistant message as opaque caller content and SHALL NOT reinterpret delimiter-like text as structured prior reasoning.

Non-streaming response rules:

* assistant messages MAY include `tool_calls`
* if tool calls are present and no assistant text was emitted, `message.content` SHALL be `null`
* if both assistant text and tool calls are present, both MAY be included in the message
* when a completion terminates by producing one or more tool calls, `finish_reason` SHALL be `"tool_calls"`

Streaming behavior:

* SSE
* emit chunks as `chat.completion.chunk`
* text deltas SHALL continue to use `choices[0].delta.content`
* tool-call deltas SHALL be emitted in `choices[0].delta.tool_calls`
* streamed tool-call deltas SHALL preserve zero-based call index and append-only argument fragments
* once tool-call emission has begun, stop-sequence handling SHALL NOT truncate function-call JSON arguments
* final line `[DONE]`
* if `stream_options.include_usage=true`, emit final usage chunk before `[DONE]`
* when a completion terminates by producing tool calls, the terminal chunk SHALL use `finish_reason: "tool_calls"`

If an error occurs **after** streaming has started:

* emit `data: {"error":{...}}`
* close stream
* do not emit `[DONE]`

Example non-streaming tool-call response:

```json
{
  "id": "chatcmpl_123",
  "object": "chat.completion",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_0",
            "type": "function",
            "function": {
              "name": "lookup_weather",
              "arguments": "{\"city\":\"Singapore\"}"
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ]
}
```

Example streaming tool-call sequence:

```text
data: {"id":"chatcmpl_123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}]}

data: {"id":"chatcmpl_123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0","type":"function","function":{"name":"lookup_weather","arguments":"{\"city\":\"Sing"}}]}}]}

data: {"id":"chatcmpl_123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"apore\"}"}}]}}]}

data: {"id":"chatcmpl_123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]
```

#### 7.2.5 `POST /v1/responses`

Supported request fields:

* `model` required
* `input` required
* `instructions`
* `max_output_tokens`
* `temperature`
* `top_p`
* `stop`
* `stream`
* `metadata`
* `tools` (function only; conditional on model capability)
* `tool_choice`
* `store`

Tool-calling request rules:

* only function tools are supported in v1
* base v1 Responses tool calling is client-executed passthrough unless a later phased extension explicitly enables server-side execution
* each request `tools` entry MAY be either an inline function definition or `{"type":"function","ref":"tool://<name>@<version>"}`
* the controller SHALL resolve registry refs before tokenization and dispatch; the runtime SHALL receive resolved function definitions only, never `tool://...` placeholders
* inline request tools SHALL remain client-executed; they SHALL NOT be executed server-side unless first resolved from an approved registry entry explicitly marked as server-hostable
* unresolved, inactive, or malformed registry refs SHALL be rejected as `400 invalid_request_error`
* requests that enable tool calling against a model without tool-calling capability SHALL return `400 invalid_request_error`
* `tool_choice` modes supported in v1:

  * `"none"` disables tool calling even if `tools` is supplied
  * `"auto"` allows the model to choose text or tool calls
  * `"required"` requires one or more tool calls or the request SHALL fail
  * `{"type":"function","function":{"name":"..."}}` requires emitted tool calls to use that function name

Supported output object subset:

* `id`
* `object: "response"`
* `created_at`
* `status`
* `model`
* `output`
* `output_text`
* `usage`
* `error`
* `metadata`

An accepted explicit final-only control SHALL cause `output_text` and `response.output_text.*` streaming events to contain final-answer text only.
An omitted control SHALL preserve the existing blended output object and event behavior.
The first release SHALL reject explicit structured prior-reasoning input items.
`reasoning_structured` SHALL remain unavailable on the public Responses surface until the later contract required by §7.2.1 is accepted.

Tool-calling response rules:

* sync responses MAY include `function_call` output items in `output`
* `output_text` SHALL include only text output content and MAY be empty when the response consists only of tool calls
* the platform SHALL NOT introduce incremental Responses function-call SSE events in v1
* streaming function-call data SHALL appear only in terminal `response.completed` or `response.failed` payloads
* terminal payloads that include partial tool calls due to interruption or cancellation SHALL mark the response as incomplete or failed rather than presenting the tool call as complete
* if a later phased extension enables controller-managed server-side tool execution, `/v1/responses` SHALL be the first target endpoint and Orchard SHALL keep the controller-governs / node-executes split defined in §1.6

Streaming behavior:

* SSE with typed events
* required emitted events:

  * `response.created`
  * zero or more `response.output_text.delta`
  * `response.output_text.done` if any text deltas were emitted
  * `response.completed` or `response.failed`

The Responses API in OpenAI’s current documentation uses typed semantic streaming events; this platform SHALL mirror that model for the supported subset. ([OpenAI Developers][6])

`store` behavior in this platform:

* accepted for compatibility
* does **not** disable internal accounting/audit metadata
* when `store=false`, payload retention narrows the effective capture mode under the rules in §10.10 Data governance

Example sync response with a function call item:

```json
{
  "id": "resp_123",
  "object": "response",
  "status": "completed",
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit@abc123",
  "output": [
    {
      "type": "function_call",
      "id": "call_0",
      "call_id": "call_0",
      "name": "lookup_weather",
      "arguments": "{\"city\":\"Singapore\"}"
    }
  ],
  "output_text": ""
}
```

Example streaming terminal tool-call response:

```text
event: response.created
data: {"type":"response.created","response":{"id":"resp_123","status":"in_progress"}}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_123","status":"completed","output":[{"type":"function_call","id":"call_0","call_id":"call_0","name":"lookup_weather","arguments":"{\"city\":\"Singapore\"}"}],"output_text":""}}
```

#### 7.2.6 Public error shape

All public inference errors SHALL use OpenAI-style envelope:

```json
{
  "error": {
    "message": "Model not authorized for tenant",
    "type": "invalid_request_error",
    "param": "model",
    "code": "model_not_authorized"
  }
}
```

#### 7.2.7 Public status codes

* `200` success
* `400` invalid request / unsupported parameter
* `401` invalid API key
* `403` forbidden / model unauthorized / tenant suspended
* `404` model not found
* `409` idempotency conflict
* `429` quota exceeded or queue full
* `499` caller cancelled or disconnected when a response remains deliverable
* `503` cluster busy / model busy / no eligible node
* `504` request timeout

Reasoning-control failures use this closed mapping:

| Failure phase | Public status, type, and code | `param` | Durable attempt evidence | Retry behavior |
|---|---|---|---|---|
| The exact model artifact and chat-template contract cannot honor an accepted explicit control | `400 invalid_request_error`, `unsupported_reasoning_control` | the accepted public reasoning-control field; `nil` for the Console | no attempt and no Request write | non-retryable |
| No loaded placement proves the exact negotiated tuple under §7.5.3a's exhaustion rule, or execution acceptance reports a different loaded-worker tuple before model invocation | `503 server_error`, `runtime_incompatible` | `nil` | `pre_acceptance_unavailable` plus `runtime_incompatible` and `retry_decision = not_retryable` when an attempt exists and the proof failure wins the terminal race; caller cancellation/disconnect and already-proven deadline terminalization retain their §3.7.1 decisions | non-retryable |
| Parser or generation-policy conformance fails after model invocation | `500 api_error`, `internal_error` | `nil` | `terminal_conformance` plus `internal_error` | non-retryable |

Messages for these mappings SHALL be bounded, content-free, and Controller-owned.
Neither parser fragments nor model output may enter the public message, durable error detail outside `full`, or metric labels.
The later public input-field contract MAY choose the concrete field name but MUST preserve these statuses, codes, and retry semantics.

#### 7.2.8 Console Playground reasoning contract

The Console Playground SHALL use the same canonical reasoning contract as the Public Inference API while preserving its distinct operator-facing defaults.
Its default request SHALL set `generation_policy = disabled`, `projection = final_only`, and `source = console_default`.
An operator MAY explicitly enable generation only when the Controller proves that the selected model, exact template, parser contract, and Runtime Endpoint contract can honor the request.
Unsupported explicit Console control SHALL fail before dispatch and MUST NOT fall back to the template default, legacy blended mode, or display-only stripping.

The Console SHALL keep final-answer and reasoning channels separate in its transcript state.
It SHALL send only the final-answer channel as assistant history on a later turn unless a future accepted contract adds typed prior-reasoning preservation.
When an operator explicitly selects public reasoning, the Console MAY render that selected channel as a collapsed secondary disclosure, but it MUST NOT mix the channel into the final answer or silently re-feed it.
The display-only reasoning heuristic tracked by issue #189 SHALL remain a legacy compatibility fallback for unstructured `legacy_blended` output only.
That heuristic MUST NOT become generation-policy authority, parser authority, capture authority, replay authority, or assistant-history reconstruction.

---

### 7.3 Operator API

Base path: `/ops/v1`

Operator API admission SHALL require an enabled API Client with cluster-scoped `operator` or `admin` authority.
For migrated operation families, transport admission SHALL be followed by the shared action-time authorization contract in §10.11; it SHALL NOT replace that contract or admit a Console cookie.

#### 7.3.1 Endpoints

```text
GET    /ops/v1/health
GET    /ops/v1/cluster
GET    /ops/v1/nodes
GET    /ops/v1/nodes/:node_id
POST   /ops/v1/nodes/:node_id/cordon
POST   /ops/v1/nodes/:node_id/uncordon
POST   /ops/v1/nodes/:node_id/drain
POST   /ops/v1/nodes/:node_id/maintenance
POST   /ops/v1/nodes/:node_id/resume
GET    /ops/v1/controllers
POST   /ops/v1/controllers/:controller_id/retire
GET    /ops/v1/nodes/:node_id/dispatch-capacity-policy
PATCH  /ops/v1/nodes/:node_id/dispatch-capacity-policy
POST   /ops/v1/dispatch-capacity/enforcement-cutover
GET    /ops/v1/requests/:request_id
POST   /ops/v1/requests/:request_id/cancel
POST   /ops/v1/requests/:request_id/retry
GET    /ops/v1/scheduler/explanations/:request_id
POST   /ops/v1/nodes/:node_id/diagnostics
```

Operator API requests SHALL authenticate with a service-account-owned API Token whose owning API Client is enabled and holds a cluster-scoped `operator` or `admin` RoleBinding.
Tenant-direct API Keys, tenant-scoped Access Levels, and public inference credentials SHALL NOT authorize Operator API access and SHALL fail closed.
Missing or invalid credentials SHALL return `401 invalid_api_key`; authenticated non-operator principals SHALL return `403 operator_required`.

Eligibility-changing or destructive Operator and Admin node actions SHALL provide an Action Preview before execution.
Action Previews SHALL be side-effect-free and SHALL NOT create domain rows, audit events, or Node Admission Decisions unless a future preview-audit contract explicitly says otherwise.
The preview response SHALL separate `blockers`, `warnings`, `consequence_codes`, and `confirmation_requirements`.
Blocker, warning, consequence, and confirmation requirement codes SHALL be stable machine-readable identifiers shared by Admin API, Operator API, CLI, Console, and tests.
Blockers are non-bypassable safety, permission, leadership, write-path, lifecycle, or data-integrity constraints.
Warnings are advisory and MAY require confirmation.
Consequence codes describe expected effects accepted only through explicit parameters or confirmation requirements.
Confirmation requirements are explicit acknowledgements or typed values and MUST NOT bypass blockers.
Action execution SHALL revalidate permissions, leadership and write-path availability, lifecycle state, health, active request count when relevant, and blockers at mutation time.

Dispatch-capacity policy reads SHALL require a cluster-scoped `operator` or `admin` RoleBinding.
Dispatch-capacity policy mutation and enforcement cutover SHALL require a cluster-scoped `admin` RoleBinding and SHALL be leader-only writes.
Controller-instance reads SHALL require cluster `operator` or `admin`.
`POST /ops/v1/controllers/:controller_id/retire` SHALL require cluster `admin`, Active leadership, a non-empty reason, `expected_updated_at`, side-effect-free Action Preview, and typed Controller ID confirmation.
Retirement SHALL be blocked for the current Active Controller, a Controller that still holds the leadership lock, or the last non-retired Controller instance.
Execution SHALL revalidate identity, status, optimistic concurrency, and leadership, set status `retired`, and persist a cluster-scoped audit event atomically.
Only this explicit audited retirement state SHALL exclude a Controller instance from dispatch-capacity cutover capability preflight.
`PATCH /ops/v1/nodes/:node_id/dispatch-capacity-policy` SHALL accept a non-negative `controller_dispatch_ceiling`, a non-empty `reason`, an optimistic concurrency value such as `expected_updated_at`, `dry_run`, and any confirmation required by its Action Preview.
Before cutover, that mutation SHALL approve a `shadow_legacy` policy as `approved_explicit` or update an existing `approved_explicit` ceiling; after cutover, it SHALL update an `enforcing` ceiling without changing the policy state.
The mutation SHALL revalidate authorization, Active leadership, the durable enforcement phase, Node Admission evidence, current policy version, and the non-negative ceiling inside the write transaction.
Its Action Preview SHALL expose prior and proposed ceilings, policy state, current Controller-accounted Allocation, projected Effective Dispatch Limit and Dispatch Headroom when evidence is available, blockers, warnings, consequence codes, and confirmation requirements.
Before cutover, the preview SHALL warn `controller_dispatch_ceiling_not_yet_enforcing` and SHALL NOT claim that the approved ceiling, including `0`, changes temporary legacy allocation.
Under `f11_enforcing`, a reduction below Controller-accounted Allocation SHALL require an explicit `capacity_reduction_drain` confirmation and SHALL state that accepted, running, and streaming work drains naturally while new and pre-acceptance work is blocked or revalidated.
`POST /ops/v1/dispatch-capacity/enforcement-cutover` SHALL accept a non-empty reason, `dry_run`, the expected durable phase, `expected_required_contract_version`, and typed cutover confirmation.
The submitted expected version SHALL equal the locked singleton row's required contract version and SHALL NOT change it during cutover.
Its Action Preview SHALL list every missing or unapproved admitted production Node, every non-retired Controller with missing, stale, incompatible, or all-consumers-not-ready capability evidence, and the exact policies that would advance.
Successful approval, ceiling change, and enforcement cutover SHALL persist a cluster-scoped audit event in the same transaction as the authoritative mutation.

#### 7.3.2 Node drain request example

```json
POST /ops/v1/nodes/8f.../drain
{
  "deadline_ms": 300000,
  "cancel_after_deadline": false,
  "enter_maintenance": true
}
```

Response:

```json
{
  "node_id": "8f...",
  "state": "draining",
  "active_requests": 2,
  "deadline_ms": 300000
}
```

#### 7.3.3 Cancel request semantics

`POST /ops/v1/requests/:id/cancel`

Behavior:

* if queued: remove from queue and mark `cancelled`
* if dispatching/running/streaming: send `CancelInference`
* if worker does not acknowledge within 3000 ms:

  * force terminate worker process
  * mark request `cancelled`
  * placement transitions to `cached` or `failed` depending on restart result

#### 7.3.4 Retry request semantics

`POST /ops/v1/requests/:id/retry`

Rules:

* only terminal failed/cancelled/timed_out/interrupted requests
* uses the stored canonical request only when the source Request retained it under `full`
* if the source canonical request is unavailable, fail with `retry_source_unavailable`
* creates new request row
* `retry_of_request_id` points to original
* max operator retries per original request default = 3
* the retry capture mode MUST NOT be wider than either the source Request snapshot or the current Tenant policy
* a negotiated retry SHALL preserve the source Request's reasoning generation policy, projection, source provenance, exact model artifact digest, chat-template digest, render contract and version, parser family and version, runtime contract version, and event-binding version
* an omitted legacy source Request SHALL preserve `effective_contract.mode = legacy`, remain omitted `model_default + legacy_blended`, and follow the existing legacy operator-retry semantics without fabricating negotiated identity
* if a negotiated exact stored reasoning contract is unavailable or no compatible endpoint can honor it, the retry SHALL fail before dispatch rather than rerendering, renegotiating, downgrading, or widening capture

#### 7.3.5 Scheduler explanation

Response example:

```json
{
  "request_id": "resp_01J...",
  "selected_node_id": "11111111-1111-4111-8111-111111111111",
  "selection_tier": "loaded",
  "scored_candidates": [
    {
      "node_id": "11111111-1111-4111-8111-111111111111",
      "eligible": true,
      "tier": "loaded",
      "score": 842,
      "components": {
        "pool_bonus": 200,
        "residency_bonus": 500,
        "mem_bonus": 72,
        "load_bonus": 40,
        "health_bonus": 30,
        "warmth_bonus": 20,
        "swap_penalty": 20
      },
      "reason_codes": []
    }
  ],
  "rejected_candidates": [
    {
      "node_id": "22222222-2222-4222-8222-222222222222",
      "reason_codes": ["node_not_active", "insufficient_memory"]
    }
  ],
  "skipped_candidates": [
    {
      "node_id": "33333333-3333-4333-8333-333333333333",
      "reason_codes": ["lower_tier_not_considered"]
    }
  ]
}
```

Snapshot and bounded compatibility candidates SHALL use the `cluster_management.scheduler_explanation.v1` selected/scored, rejected, and skipped structures with stable reason codes. Candidate diagnostics SHALL remain bounded and set `candidate_source = "monitor_snapshot"` for snapshot candidates or `candidate_source = "bounded_compatibility_probe"` for the unmanaged exception.
Scheduler explanations are produced whenever at least one runtime target is configured and the scheduler coherently evaluates snapshot or bounded compatibility candidates. For a coherent snapshot of lifecycle-managed targets, selected, rejected, and skipped entries remain observable even when all candidates are rejected and the existing `cluster_busy` or queue-waitable live-node-capacity outcome follows. Missing or structurally malformed snapshot facts use `dispatch_capacity_facts_unavailable`, stale facts use `node_observation_stale`, identity conflicts use `runtime_identity_mismatch`, eligible lower-tier candidates use `lower_tier_not_considered`, and existing runtime and shared-capacity failures retain their stable codes. If trusted inventory is unavailable, MultiNode preserves internal `:no_active_nodes` and emits no explanation. If the snapshot read fails after target resolution, it preserves the existing `:cluster_busy` or bounded queue outcome and emits no candidate explanation because no coherent candidate evaluation can be proven. Neither failure path probes production targets or uses stale process memory.
Reason codes SHALL be shared by Operator API, CLI, Console, and tests.
Human-readable explanation text MAY be included, but it SHALL be supplemental to machine-readable reason codes.
Rejected candidates SHALL include at least one stable rejection reason code.
Skipped candidates SHALL be represented in `skipped_candidates` outside the rejected-candidate list and SHALL include at least one stable skip reason code.
The initial scheduler rejection vocabulary SHALL include `inventory_missing`, `node_not_admitted`, `node_not_active`, `node_not_registered`, `node_health_degraded`, `node_health_unreachable`, `node_health_unhealthy`, `node_observation_stale`, `transport_unreachable`, `runtime_not_ready`, `runtime_identity_mismatch`, `version_incompatible`, `pool_not_allowed`, `model_format_unsupported`, `model_not_available_on_node`, `insufficient_memory`, `node_concurrency_exhausted`, `placement_concurrency_exhausted`, `placement_suppressed`, `node_circuit_breaker_open`, `model_load_suppressed`, `policy_required`, `pool_required`, `queue_lane_capacity_unavailable`, `trust_not_established`, `unknown_capacity`, `dispatch_capacity_facts_unavailable`, `controller_dispatch_ceiling_missing`, `controller_dispatch_ceiling_invalid`, `controller_dispatch_ceiling_zero`, `controller_dispatch_ceiling_exhausted`, `runtime_concurrency_limit_unknown`, `runtime_concurrency_limit_exhausted`, `dispatch_headroom_exhausted`, `placement_capacity_exhausted`, `dispatch_capacity_revalidation_failed`, `dispatch_capacity_phase_policy_mismatch`, `runtime_endpoint_management_class_missing`, `runtime_endpoint_management_class_invalid`, `dispatch_ceiling_shadow_mismatch`, `dispatch_ceiling_not_approved`, and `previous_attempt_node_excluded`.
`previous_attempt_node_excluded` SHALL be used only for a candidate removed by the §5.5 hard `exclude_node_ids` filter during an Automatic Attempt Retry alternate scheduling decision.
The scheduler rejection vocabulary SHALL additionally accept every stable capacity reason code when a shared dispatch-capacity evaluation excludes a candidate.
The initial scheduler skip vocabulary SHALL include `lower_tier_not_considered`, `not_scored_after_selection`, `not_applicable_to_request`, and `candidate_limit_reached`.
Queue-waitable capacity outcomes SHALL preserve whether the wait reason is live node capacity, requested model path capacity, placement capacity, or tenant active capacity.
Scored candidates SHALL be listed in the scheduler's actual selection ranking order.
The selected node SHALL correspond to the top-ranked eligible scored candidate.
A scored candidate's `score` SHALL be consistent with its additive `components` breakdown.
Component keys are stable machine-readable identifiers within a persisted explanation and MAY evolve as the ranking model changes, but score and components SHALL remain internally consistent for a given persisted decision.
Scheduler explanation generation, validation, and persistence are observational.
An invalid or unbuildable explanation SHALL NOT fail, block, or alter the user's inference request.
Invalid explanation payloads SHALL NOT be persisted; the controller SHALL drop them with a logged error while still recording the underlying scheduler decision.

---

### 7.4 Admin API

Base path: `/admin/v1`

Admin API admission SHALL require an enabled API Client with cluster-scoped `admin` authority.
The accepted credential-management target in §10.11 SHALL retain this admission boundary and add shared action-time authorization without introducing Tenant-admin machine admission or accepting Console cookies.

#### 7.4.1 Endpoints

Accepted target credential-management and Console Identity provisioning routes are specified in §10.11; those additions remain pending implementation.

```text
GET    /admin/v1/tenants
POST   /admin/v1/tenants
GET    /admin/v1/tenants/:tenant_id
PATCH  /admin/v1/tenants/:tenant_id
POST   /admin/v1/tenants/:tenant_id/suspend
POST   /admin/v1/tenants/:tenant_id/resume

GET    /admin/v1/api-keys
POST   /admin/v1/api-keys
POST   /admin/v1/api-keys/:key_id/revoke

GET    /admin/v1/service-accounts
POST   /admin/v1/service-accounts
PATCH  /admin/v1/service-accounts/:id

GET    /admin/v1/quotas
POST   /admin/v1/quotas
PATCH  /admin/v1/quotas/:quota_id

GET    /admin/v1/models
POST   /admin/v1/models/import
PATCH  /admin/v1/models/:model_id/:version
POST   /admin/v1/models/:model_id/:version/activate
POST   /admin/v1/models/:model_id/:version/deprecate
POST   /admin/v1/models/:model_id/:version/retire

GET    /admin/v1/routing-policies
POST   /admin/v1/routing-policies
PATCH  /admin/v1/routing-policies/:id

GET    /admin/v1/node-admission/candidates
GET    /admin/v1/node-admission/candidates/:candidate_id
POST   /admin/v1/node-admission/candidates/:candidate_id/reject
POST   /admin/v1/node-admission/candidates/:candidate_id/clear-rejection
POST   /admin/v1/nodes/provision
POST   /admin/v1/nodes/:node_id/admit
POST   /admin/v1/nodes/:node_id/decommission

PATCH  /admin/v1/observability
POST   /admin/v1/bootstrap-tokens
```

Node Admission Candidate review endpoints SHALL expose sanitized observed identity, target reference, inventory, compatibility evidence, last observation timestamp when present, admission category, decision metadata when present, and audit event reference when present.
Admin admission execution SHALL require a registered trusted Node with inventory, pool, and required policy inputs.
`POST /admin/v1/nodes/:node_id/admit` SHALL accept optional non-negative `controller_dispatch_ceiling`, a required non-empty `capacity_policy_reason`, `dry_run`, and any confirmation required by its Action Preview; it SHALL default the ceiling explicitly to `1` only when omitted and include the resolved value and phase-derived policy state in its Action Preview.
Admission execution SHALL lock and read the durable enforcement phase, persist the explicit ceiling, approval actor, timestamp, and reason with the admission decision, and fail the entire transaction on policy or audit failure.
Pending admission rejection SHALL persist a Node Admission Decision and audit event without deleting observed inventory.
Clearing rejection SHALL require admin authority and SHALL persist an audit event.
Admin admit and pending-admission reject endpoints SHALL support `dry_run` requests that return the shared Action Preview shape and follow the side-effect-free invariants in §7.3.1.

#### 7.4.2 Tenant create example

```json
POST /admin/v1/tenants
{
  "name": "Finance",
  "slug": "finance",
  "default_pool_id": "uuid",
  "request_body_capture_mode": "metadata"
}
```

#### 7.4.3 API key create example

```json
POST /admin/v1/api-keys
{
  "tenant_id": "uuid",
  "name": "finance-prod-app",
  "roles": ["inference_client"],
  "expires_at": "2026-12-31T00:00:00Z"
}
```

Response:

```json
{
  "id": "uuid",
  "token_prefix": "orchard_kp_<16-character-public>",
  "secret": "orchard_sk_<16-character-public>_<43-character-secret>",
  "expires_at": "2026-12-31T00:00:00Z"
}
```

#### 7.4.4 Bulk API Client provisioning CLI contract

The first bulk provisioning surface SHALL be `orchardctl api-clients bulk-provision`.
The command SHALL support exactly one of Dry Run or Apply mode.
The command SHALL expose `--dry-run`, `--apply`, `--file`, `--output`, `--rotation`, and `--json` options.
Apply mode SHALL require an operator-specified output path.
Dry Run mode MAY validate an operator-specified output path without requiring one.
The input CSV SHALL require `organization`, `api_client`, `owner_contact`, and `key_name`.
The input CSV MAY include `team`, `owner_name`, `external_ref`, `description`, `purpose`, `expires_at`, and `metadata_json`.
The `organization` field SHALL identify one Workspace slug per input file.
Plaintext API Token secrets SHALL NOT be accepted in input.
Dry Run SHALL validate Workspaces, API Client identity, duplicate API Token names, optional expiry values, metadata JSON, and output destination readiness without mutating state or generating secrets.
Apply SHALL validate the output path before mutation and commit all provisioning changes as one batch.
Apply SHALL write One-time Secret Output only after the batch succeeds.
One-time Secret Output SHALL be a CSV with `organization`, `api_client`, `external_ref`, `key_name`, `api_token_id`, `api_token_prefix`, `api_token`, and `expires_at` columns.
If One-time Secret Output delivery fails after a committed Apply, Orchard SHALL mark the Provisioning Batch as `output_failed`, write a redacted audit event, and return recovery guidance that names API Token prefixes for revocation or rotation.
The output-failed recovery path SHALL NOT persist plaintext API Token secrets.
`orchardctl cluster init` publishes its file-backed One-time Secret Output through the cluster-init-only protected publication profile in §11.9, which does not modify this bulk-provisioning contract or the `OrchardCLI.ExclusiveOutput` contract.
Repeated provisioning SHALL match API Clients by Workspace plus External Reference when present, otherwise by Workspace plus API Client name.
Repeated provisioning SHALL reject duplicate active API Token names unless explicit Key Rotation mode is enabled.
Key Rotation mode SHALL create a replacement API Token and revoke previous active API Tokens with the same API Client and token name.
Repeated provisioning SHALL preserve omitted optional API Client metadata columns, clear present blank optional scalar metadata columns, and replace metadata when `metadata_json` is present.
Bulk provisioning SHALL reject rows targeting disabled API Clients.
JSON mode SHALL emit a machine-readable summary without plaintext API Tokens in stdout.

#### 7.4.5 Model import example

```json
POST /admin/v1/models/import
{
  "source_type": "local_path",
  "path": "/Volumes/Models/llama-3.1-8b-instruct-mlx-q4-v1.tar",
  "activate": false
}
```

#### 7.4.6 Observability config example

```json
PATCH /admin/v1/observability
{
  "tracing": {
    "enabled": true,
    "otlp_endpoint": "https://otel-collector.local:4318",
    "sample_ratio": 0.1
  },
  "logging": {
    "level": "info",
    "retention_days": 7
  }
}
```

Metrics exposure is not configurable through this endpoint; §9.1 fixes the
shared HTTP listener and the operator-or-admin bearer boundary for `/metrics`.

---

### 7.4a Developer Portal

Base path: `/portal/:organization_slug`

The Developer Portal SHALL be a distinct browser surface from Orchard Console.
It SHALL NOT render operator Console chrome, other Workspaces, nodes, or cluster administration.
A Portal User SHALL be an interactive identity scoped to one Workspace and SHALL authorize only Developer Portal access.
A Portal User SHALL NOT be treated as an Operator, Service Account, Owner Contact, Tenant Admin, Public Inference principal, or authority for Console, Operator API, or Admin API access.
Portal sessions SHALL NOT authorize Public Inference, Operator API, Admin API, or Console access.
Named Console authentication SHALL change attribution for Console-originated Portal administration under §§10.9 and 10.11 without changing Portal identity scope or inference-key independence.

Routes:

```text
GET  /portal/:organization_slug
GET  /portal/:organization_slug/invites/:token
POST /portal/:organization_slug/invites/:token
POST /portal/:organization_slug/session
POST /portal/:organization_slug/logout
LIVE /portal/:organization_slug/keys
```

Portal User accounts SHALL be operator-invite only, with no public signup or self-registration.
Email SHALL be the Portal User identifier and SHALL be unique by normalized value within one Workspace.
SMTP SHALL NOT be required.
Creating a Portal User SHALL persist the invited identity and `portal_user.invited` audit row atomically without creating a Portal Invite row.
For a Portal User in `invited` status, the Console SHALL provide Copy invite.
Each Copy invite action SHALL mint a fresh single-use token, persist only its hash, extend the invite expiry, and invalidate every prior unused invite token for that Portal User.
A Copy invite mutation SHALL lock the Portal User before observing invite-row state, generating the token, or calculating the expiry.
The first committed Copy invite SHALL use `portal_user.invite_issued`, and a later committed replacement SHALL use `portal_user.invite_reissued`.
Concurrent Copy actions SHALL serialize so exactly one initial issue is recorded and every later replacement extends the stored expiry.
A Portal User SHALL have at most one stored invite row at a time.
Invite invalidation SHALL delete the stored invite row rather than tombstone it, and Orchard SHALL NOT retain invite revocation history.
Orchard SHALL NOT persist the plaintext invite token or URL.
The operator SHALL deliver the copied invite URL out of band.
Invite redemption SHALL be bound to the Workspace identified by the route and SHALL succeed only for a valid unexpired invite owned by a Portal User who is currently `invited` in that Workspace.
Successful redemption SHALL set the Portal User's password, mark the invite redeemed, activate the Portal User, and end that Portal User's standing portal sessions.
Wrong-Workspace, disabled-user, invalidated, expired, redeemed, and unknown-token redemption failures SHALL use one generic external response and SHALL make no persisted mutation.
Recopying an invite for a Portal User who remains `invited` SHALL use the same reissue flow and SHALL end that Portal User's standing portal sessions.

The portal SHALL identify the Workspace by slug, then authenticate one active Portal User by normalized email and password.
Unknown Workspace, unknown email, disabled Portal User, and wrong-password submissions SHALL have indistinguishable status, body shape, headers, and generic credential failure.
`GET /portal/:organization_slug` SHALL be response-indistinguishable for Workspaces with or without invited or active Portal Users and for unknown slugs.
Failed portal logins SHALL be limited per Workspace fingerprint, Portal User or email fingerprint, and source fingerprint.
They SHALL NOT use a Workspace-wide lockout.

The operator SHALL invite and disable Portal Users from the existing Console Workspace detail surface.
Disabling a Portal User SHALL atomically invalidate every outstanding invite by deleting its stored row, and SHALL end only that Portal User's portal sessions.
Disabling a Portal User SHALL NOT revoke that Portal User's API Keys.
Invite reissue, invite redemption, and Portal User disablement SHALL NOT revoke minted API Keys.
Repeated disable SHALL be a true no-op that does not rewrite timestamps, advance the session epoch, or create another successful audit observation.

The portal SHALL mint tenant-direct API Keys with `issuance_surface = 'developer_portal'` and `portal_user_id` equal to the signed-in Portal User.
A Portal User MAY have at most 10 active portal-minted tenant-direct keys.
Revoked and expired keys SHALL NOT count toward that ceiling.
The mint transaction SHALL serialize on the Portal User, not the Workspace.
Portal key mint and revoke SHALL carry the validated session tenant ID, Portal User ID, and password epoch into one outer transaction.
That transaction SHALL lock and revalidate the Portal User before enforcing the mint cap or locking an API Key.
The lock order for revoke SHALL be Portal User then API Key, and a stale captured epoch SHALL fail as an invalid session before any API Key lock or mutation.
Operator-minted tenant-direct keys SHALL NOT count toward that ceiling, SHALL remain operator-only, and SHALL NOT be visible or revocable from the portal.
The portal SHALL list and revoke only portal-minted keys whose `portal_user_id` and `tenant_id` match the signed-in Portal User and Workspace.
Keys owned by another Portal User or another Workspace SHALL be indistinguishable from missing keys on portal list and revoke paths.
Portal revoke SHALL take effect on the next Public Inference authentication.
Repeated Portal revoke SHALL be a true no-op that does not rewrite `revoked_at` or `updated_at` and does not create another successful audit observation.

Legacy portal-minted keys with `portal_user_id IS NULL` SHALL remain valid `orchard_sk_*` Bearer credentials until explicitly revoked.
Legacy unowned portal-minted keys SHALL remain operator-visible only, SHALL NOT be claimable by a Portal User, and SHALL NOT be listed or revoked from the portal.
The portal SHALL NOT mint a new key without `portal_user_id`.
Public Inference Bearer authentication SHALL continue to resolve every tenant-direct key as `principal_type = tenant` and SHALL NOT consult `portal_user_id`.

Key secrets SHALL be shown once at creation and SHALL NOT be recoverable later.
After mint, the portal SHALL show one `POST /v1/chat/completions` curl using an active exact Model identity with enabled access for the Workspace, or state that no test curl is available.
Selection SHALL be deterministic when no exact Model was requested.
An explicitly requested exact Model that is inactive, unavailable, or no longer authorized SHALL NOT be silently substituted.
Catalog availability and model authorization SHALL NOT be presented as proof of runtime readiness or request success.
Console colleague handoff examples SHALL use a literal placeholder credential; only the actual Portal mint response SHALL display that Portal User's newly minted secret under the existing one-time display contract.
Console guidance SHALL NOT treat the default-scoped Playground as evidence for a different Workspace.

The portal SHALL be served only when public API HTTPS is enabled and the effective request scheme is HTTPS.
Degraded `plain_http_localhost` SHALL return `404` for every portal route.

---

### 7.5 Runtime Endpoint and Internal Worker Interfaces

Runtime Endpoint semantics SHALL remain independent of Controller Host and Node operating systems.
Runtime Endpoint Observations SHALL evolve additively to distinguish host capability-provider evidence from runtime-provider evidence and to carry normalized platform, architecture, provider, acceleration, device-resource, memory-domain, health, availability, freshness, and capability-version facts.
Host hardware presence MUST NOT prove runtime initialization.
Runtime readiness MUST NOT fabricate host device inventory.
Unknown, malformed, stale, unauthenticated, or version-incompatible evidence MUST NOT prove a capability requirement.

Existing observations that omit additive heterogeneous capability fields SHALL remain decodable.
Their omission SHALL remain non-authoritative for new capability requirements and SHALL NOT change current scheduling behavior until the separately reviewed authoritative cutover.

Controller runtime execution SHALL use the Runtime Endpoint Interface.
Runtime Endpoint semantics are transport-independent.
The gRPC/protobuf `NodeRuntimeService` remains the gRPC Compatibility Adapter and a candidate protocol for future non-BEAM adapters.
First-party Orchard Controller and Node Agent source-dev services SHALL use BEAM Distribution as the default live Controller-to-Node Agent Runtime Endpoint transport when the endpoint is an admitted first-party Orchard service.
Source-dev split-role `bin/dev-controller` and `bin/dev-node-agent` SHALL default to BEAM Runtime Endpoint transport when `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` is unset.
Source-dev gRPC compatibility remains available on port `50071` through explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
Accepted two-Mac smoke evidence SHALL remain recorded before and after BEAM Runtime Endpoint transport is promoted as the source-dev default.
The accepted smoke requires Console Nodes to show local and remote Node Agents reachable, `GET /v1/models` to return `200`, and `POST /v1/chat/completions` to complete through the Console Playground or an equivalent API request.
When BEAM Runtime Endpoint transport is selected, Orchard MUST NOT retry the same request through gRPC compatibility as an automatic fallback.
Console live runtime diagnostics SHALL use the configured Runtime Endpoint target list.
Explicit BEAM Runtime Endpoint targets SHALL take precedence over legacy gRPC runtime client targets for Console probes.
Production BEAM Distribution MUST be explicitly enabled, identity-bound, network-restricted, and fail closed when required admission configuration is missing.
BEAM Runtime Endpoint targets MUST carry a valid BEAM node-name address (`service@host`) as an atom or binary; a configured `node_id`, when present, MUST be a UUID and MUST match observed endpoint metadata before scheduler or dispatch may trust that candidate identity.
External Runtime Endpoints MUST NOT join the first-party BEAM mesh.
Postgres remains durable truth for inventory, lifecycle state, Runtime Endpoint Observations, scheduling history, request state, and operator-visible status.
BEAM Distribution MUST NOT be treated as durable cluster truth.

#### 7.5.0 Production first-party BEAM identity and authorization

The Production BEAM Operating Model SHALL use OTP TLS distribution with explicit peer verification on both endpoints.
The accepting endpoint SHALL require a peer certificate.
The Controller SHALL validate the exact Node-ID URI SAN, certificate identifier, serial, fingerprint, and internal trust authority recorded for the Node.
The Node Agent SHALL validate the exact Controller-ID URI SAN, certificate identifier, fingerprint, and enrolled internal trust authority recorded for the Controller instance.
TLS certificate validation is necessary but SHALL NOT be treated as complete OTP distribution authorization.

Each production distribution relationship SHALL also require one active BEAM Peer Grant scoped to:

* contract version and purpose
* cluster ID
* Controller ID and canonical Controller BEAM name
* Controller Certificate identifier and fingerprint
* Node ID and canonical Node BEAM name
* Node Certificate identifier and fingerprint
* Controller BEAM Authorization Root ID
* grant ID and generation
* issue, not-before, cutover, and expiry times

Each Controller instance SHALL own a distinct BEAM Authorization Root containing at least 256 bits of random key material.
The root SHALL be separate from the node-signing CA, Controller Certificate private key, database credentials, and other cluster secrets.
It SHALL be stored in macOS Keychain or an owner-only Controller path, SHALL never be stored in Postgres, and SHALL never be delivered to a Node.

The Controller SHALL derive the encoded Peer Grant secret with HMAC-SHA-256 over a versioned, length-delimited canonical encoding of the complete immutable grant scope.
Only Controller-approved active or staged grant records may cause the encoded value to be converted to the cookie atom required by OTP.
Externally supplied or otherwise untrusted values MUST NOT create atoms.

A BEAM Peer Grant record SHALL include:

* stable `grant_id` UUID and monotonically increasing pair generation
* cluster ID, Controller ID, canonical Controller BEAM name, Controller Certificate identifier and fingerprint, and BEAM Authorization Root ID
* Node ID, canonical Node BEAM name, and Node Certificate identifier and fingerprint
* contract version and purpose
* issue, not-before, cutover, and expiry timestamps
* lifecycle state
* delivery, activation, supersession, failure, and revocation evidence
* SHA-256 hash of the encoded secret

The closed grant lifecycle states SHALL be `pending_delivery`, `staged`, `active`, `superseded`, `revoked`, `expired`, and `delivery_failed`.
Only `active` authorizes ordinary new connections.
`staged` authorizes only its scheduled cutover, and all other states SHALL fail closed for new connections.
Postgres SHALL NOT store the plaintext Peer Grant or BEAM Authorization Root.

The initial Peer Grant validity SHALL default to 30 days, with normal rotation beginning 7 days before expiry.
Only one active generation and at most one staged successor generation may exist for an exact Controller-to-Node pair.
A database uniqueness constraint SHALL enforce at most one `active` and at most one `staged` generation per exact `(cluster_id, controller_id, node_id, purpose)` scope.
Normal generation creation SHALL be rate-limited to no more than once per hour per pair so legitimate rotation cannot cause unbounded OTP atom creation.

The Node Admission state transition, its Node Admission Decision and audit event, and one initial `pending_delivery` Peer Grant record for each currently eligible Controller instance SHALL commit in one Postgres transaction.
If any part cannot be persisted, admission SHALL fail closed with no partial admission and no orphaned grant metadata.
A Controller instance enrolled after Node Admission SHALL obtain its initial grant metadata through a separate leader-authorized operation that is itself atomic.
A registered but unadmitted Node SHALL receive no production Peer Grant.
The Node SHALL retrieve the exact Controller's authorized grant through certificate-authenticated control traffic and store it atomically in its owner-only identity root.
Lost delivery responses SHALL return the same authorized generation and derived secret after identity, certificate, admission, generation, and expiry are revalidated.

Normal rotation SHALL stage the successor on both endpoints, cut over at an agreed time, deliberately disconnect the old distribution connection, and require the successor generation on reconnect.
Revocation SHALL update Postgres authority immediately, replace the exact-name cookie mapping, exclude the Runtime Endpoint from scheduling and queue capacity, disconnect the peer, and append a sanitized cluster-scoped audit event.
Revocation SHALL remain visibly incomplete until disconnection succeeds or the affected distribution process is restarted.
`net_kernel:allow/1` SHALL NOT be treated as a revocation mechanism.

Node or Controller Certificate renewal SHALL require a new Peer Grant generation bound to the renewed certificate identifier and fingerprint.
Because certificate identity and fingerprint are part of the immutable grant scope, certificate-renewal cadence necessarily drives Peer Grant rotation and a staged reconnect.
Re-admission SHALL require a new grant ID and generation after current trust and admission requirements succeed.
Decommission SHALL revoke every Peer Grant involving the Node, revoke the Node Certificate, disconnect the Node from every reachable Controller, and prevent reuse of the same Node ID, canonical BEAM name, certificate, or grant.
Loss or compromise of a BEAM Authorization Root SHALL stop new authorization under that root until the root is restored or replaced and every affected pair is reissued through certificate-authenticated control traffic.

Each Active/Standby Controller instance SHALL have a distinct stable Controller ID, Controller Certificate URI SAN, canonical BEAM name, BEAM Authorization Root, and Peer Grant with each admitted Node.
Active and Standby Controllers SHALL NOT share pair grants.
Both Controllers MAY keep authenticated distribution connections for liveness, status, and explicitly read-only diagnostics.
Only the Active Leader may initiate inference execution, model mutation, cancellation, or lifecycle writes, enforced by the Postgres advisory-lock write gate before the operation leaves the Controller.
A Peer Grant proves Controller-instance membership, not advisory-lock leadership.
The Node Agent cannot cryptographically prove that a connected Controller owns the Postgres advisory lock, and Orchard MUST NOT claim otherwise through a certificate, cookie, or Node-local leader flag.

Canonical production Node Agent names SHALL use `orchard_node_agent_<node-id-without-hyphens>@<private-ipv4>`.
Canonical Controller names SHALL use `orchard_controller_<controller-id-without-hyphens>@<private-ipv4>`.
The complete UUID SHALL be used to avoid short-ID collisions.
The enrolled product path SHALL derive those names and targets from trusted inventory and SHALL NOT require an operator-maintained static target list.
An address or name match alone SHALL NOT establish identity, admission, or Peer Grant authority.
Changing the advertised address changes the canonical BEAM name and SHALL require a certificate-authenticated inventory update, a new Peer Grant, and deliberate reconnect.
Static target overrides MAY remain for documented source-development and explicit compatibility operation, but SHALL NOT establish product trust.

Distributed Erlang membership is a high-trust code boundary, not a per-function capability sandbox.
A scoped Peer Grant reduces credential blast radius and cross-Node impersonation, but it does not restrict an authenticated peer to individual Runtime Endpoint functions.
Production BEAM SHALL therefore be limited to signed first-party Orchard releases on operator-controlled admitted Macs inside restricted private networks.
External providers, third-party adapters, tenant-controlled compute, and partially trusted machines SHALL remain outside the BEAM mesh.

The initial stable operator-facing production BEAM failure vocabulary SHALL include:

* `beam_target_not_in_trusted_inventory`
* `beam_target_not_admitted`
* `beam_peer_certificate_invalid`
* `beam_peer_identity_mismatch`
* `beam_peer_name_not_authorized`
* `beam_peer_grant_missing`
* `beam_peer_grant_not_active`
* `beam_peer_grant_expired`
* `beam_peer_grant_revoked`
* `beam_peer_grant_generation_mismatch`
* `beam_peer_credential_mismatch`
* `beam_peer_disconnect_incomplete`
* `beam_peer_rotation_incomplete`
* `beam_distribution_disabled`
* `beam_distribution_unavailable`
* `beam_target_invalid`
* `beam_target_unknown`
* `beam_node_unavailable`
* `beam_node_timeout`
* `beam_rpc_failed`

These failures SHALL be visible through shared operator diagnostics without exposing certificates, grant values, hashes, local paths, or raw OTP exception terms.
The current adapter outcomes `unknown_beam_node`, `node_unavailable`, `node_timeout`, and `beam_rpc_error` SHALL normalize to `beam_target_unknown`, `beam_node_unavailable`, `beam_node_timeout`, and `beam_rpc_failed` before reaching CLI, Console, or tests.
Transport and liveness failures SHALL remain distinguishable from Peer Grant and certificate failures.
When BEAM is selected, none of these failures may cause the same Runtime Endpoint operation to retry through gRPC compatibility.
Certificate and Peer Grant recovery through the explicitly selected gRPC/mTLS control path is not an inference fallback.

The gRPC/mTLS path SHALL remain available for enrollment, Node and Controller Certificate lifecycle, Peer Grant delivery and recovery, diagnostics, explicit Runtime Endpoint compatibility, future external or non-BEAM adapters, and explicit operator opt-out.
The Python/MLX Worker Runtime SHALL remain a Node Agent-local subprocess and SHALL NOT receive Node Certificates, BEAM Peer Grants, or BEAM membership.

Definitions:

* **Runtime Endpoint**: the scheduler-selected execution boundary that can receive model runtime work from the Controller.
* **Runtime Endpoint Interface**: the Controller-facing operations and observations for status, model readiness, model unloading, inference execution, cancellation, prefix-cache scoring, runtime telemetry, Placement Capacity, and streaming events.
* **Runtime Endpoint Observation**: a durable Controller-recorded snapshot of endpoint status, capability, availability, placement, and capacity signals.
* **Runtime Endpoint Availability**: the scheduler-facing availability of a Runtime Endpoint for new work, independent of whether the endpoint is backed by an Orchard-managed Node, external compute, or a provider integration.
* **Placement Capacity**: a Runtime Endpoint Observation for a Model Placement that reports the model reference, active request count, and max concurrency.
* **Worker Runtime**: the Node Agent-local process/protocol boundary for Python, MLX, and future non-BEAM model execution.
* **gRPC Compatibility Adapter**: the adapter that maps Runtime Endpoint Interface semantics to and from `proto/cluster/v1` and `NodeRuntimeService`.

Compatibility protocol: **gRPC over HTTP/2 + TLS 1.3 + mTLS**

Compatibility ports:

* controller gRPC ingress: `8444`
* node agent gRPC ingress: `9444`

#### 7.5.1 Controller-side service

Controller-side node lifecycle RPC remains a first-party management surface while Runtime Endpoint execution moves behind the Runtime Endpoint Interface.

```proto
service ClusterMembershipService {
  rpc RegisterNode(RegisterNodeRequest) returns (RegisterNodeResponse);
  rpc Heartbeat(HeartbeatRequest) returns (HeartbeatResponse);
  rpc ReportStatus(StatusReportRequest) returns (Ack);
  rpc RenewCertificate(RenewCertificateRequest) returns (RenewCertificateResponse);
}
```

The certificate-authenticated control path that delivers and recovers the BEAM
Peer Grant already created during admission (§7.5.0) is a distinct
Controller-side service defined in `proto/cluster/v1/peer_grant.proto`. It only
returns the exact authorized grant; it never mints authority, and lost
responses SHALL re-return the same authorized generation after identity,
certificate, admission, generation, and expiry are revalidated.

```proto
service ControllerPeerGrantService {
  rpc RetrieveBeamPeerGrant(RetrieveBeamPeerGrantRequest)
      returns (RetrieveBeamPeerGrantResponse);
}
```

#### 7.5.2 Node-side service

`NodeRuntimeService` is the current gRPC Compatibility Adapter service for Runtime Endpoint operations.
The Controller domain code SHALL depend on Runtime Endpoint Interface semantics rather than generated protobuf request or response types.

```proto
service NodeRuntimeService {
  rpc GetStatus(StatusRequest) returns (StatusResponse);
  rpc EnsureModelLoaded(EnsureModelLoadedRequest) returns (EnsureModelLoadedResponse);
  rpc UnloadModel(UnloadModelRequest) returns (Ack);
  rpc ExecuteInference(ExecuteInferenceRequest) returns (stream InferenceEvent);
  rpc CancelInference(CancelInferenceRequest) returns (Ack);
  rpc ScorePrefixCache(ScorePrefixCacheRequest) returns (ScorePrefixCacheResponse);
  rpc RunDiagnostics(RunDiagnosticsRequest) returns (RunDiagnosticsResponse);
}
```

#### 7.5.2a Worker-side service (node-agent ↔ worker)

The Worker Runtime Interface is provider-neutral even while MLX is the required v1 macOS implementation.
Its protocol source, version policy, binding generation authority and output manifest, descriptor golden, and conformance fixtures SHALL be owned outside any runtime-provider implementation.
Generated consumer copies MAY live under a runtime-provider package when their only authority is the neutral generator and required validation checks every committed output for drift.
Every supported provider SHALL pass provider-neutral negotiation, health, load, unload, generation, streaming, cancellation, capacity, failure-normalization, and version-skew conformance, plus applicable real-hardware acceptance.

The Worker Runtime Interface remains Node Agent-local.
The Controller communicates with the Runtime Endpoint, not directly with Worker Runtime subprocesses.

```proto
service WorkerRuntimeService {
  rpc GetStatus(WorkerStatusRequest) returns (WorkerStatusResponse);
  rpc LoadModel(LoadModelRequest) returns (Ack);
  rpc UnloadModel(UnloadModelRequest) returns (Ack);
  rpc Generate(ExecuteInferenceRequest) returns (stream InferenceEvent);
  rpc Cancel(CancelInferenceRequest) returns (Ack);
  rpc ScorePrefixCache(ScorePrefixCacheRequest) returns (ScorePrefixCacheResponse);
}
```

#### 7.5.3 Required messages

```proto
message RegisterNodeRequest {
  string bootstrap_token = 1;      // optional if cert mode
  string csr_pem = 2;              // required in bootstrap mode
  string hostname = 3;
  string advertise_addr = 4;
  uint32 rpc_port = 5;
  map<string,string> facts = 6;    // chip, os version, agent version
  bytes capabilities_json = 7;
}

message RegisterNodeResponse {
  string node_id = 1;
  string lifecycle_state = 2;
  bytes signed_cert_pem = 3;
  bytes ca_bundle_pem = 4;
  uint64 heartbeat_interval_ms = 5;
}

message HostedToolCapability {
  string name = 1;
  string version = 2;
  string adapter_kind = 3;
}

message HostedToolReadiness {
  string name = 1;
  string version = 2;
  bool ready = 3;
  string readiness_code = 4;
  string readiness_message = 5;
}

message StatusRequest {}

message RuntimeNodeMetadata {
  string node_id = 1;
  string display_name = 2;
  string hostname = 3;
  string agent_version = 4;
  string listen_host = 5;
  uint32 listen_port = 6;
  string worker_backend = 7;
}

message RuntimeHealth {
  bool ready = 1;
  string health_code = 2;
  string health_message = 3;
  ModelRef affected_model = 4;
}

message RuntimeMemoryBudget {
  ModelRef model_ref = 1;
  string mode = 2;
  bool budget_available = 3;
  bool headroom_available = 4;
  string status_code = 5;
  string status_message = 6;
  string source = 7;
  uint64 max_recommended_working_set_size_bytes = 8;
  double utilization = 9;
  uint64 target_working_set_bytes = 10;
  uint64 overhead_bytes = 11;
  uint64 resident_memory_bytes = 12;
  uint64 estimated_headroom_bytes = 13;
  uint64 kv_cache_bytes_per_token = 14;
  uint64 prefill_workspace_bytes_per_token = 15;
  uint64 recommended_context_tokens = 16;
}

message RuntimePrefixCacheStatus {
  ModelRef model_ref = 1;
  string implementation = 2;
  bool enabled = 3;
  uint32 entry_count = 4;
  uint64 total_bytes = 5;
  uint64 hits = 6;
  uint64 misses = 7;
  uint64 failures = 8;
  uint64 stores = 9;
  uint64 evictions = 10;
  uint32 configured_max_entries = 11;
  uint64 configured_max_bytes = 12;
  string status_code = 13;
  string status_message = 14;
  uint64 session_started_unix_ms = 15;
  repeated string prefix_cache_fingerprints = 16;
}

message RuntimeModelPlacement {
  ModelRef model_ref = 1;
  uint32 active_request_count = 2;
  uint32 max_concurrency = 3;
}

// Bounded process-lifetime monotonic crash count for one model identifier.
// counter_version is controller-internal deduplication state, never a metric label.
message WorkerCrashCounter {
  string model_id = 1;
  uint64 count = 2;
  string counter_version = 3;
}

message StatusResponse {
  WorkerState worker_state = 1;
  repeated ModelRef loaded_models = 2;
  // Active runtime requests across the node.
  uint32 active_request_count = 3;
  RuntimeNodeMetadata node_metadata = 4;
  RuntimeHealth runtime_health = 5;
  repeated HostedToolCapability hosted_tool_capabilities = 6;
  repeated HostedToolReadiness hosted_tool_readiness = 7;
  repeated RuntimeMemoryBudget runtime_memory_budgets = 8;
  repeated RuntimePrefixCacheStatus runtime_prefix_cache_statuses = 9;
  bool supports_prompt_token_ids = 10;
  repeated RuntimeModelPlacement runtime_model_placements = 11;
  // Node-owned Runtime Concurrency Enforcement Limit.
  // Only explicit unmanaged compatibility may normalize absent or zero to 1.
  uint32 max_concurrency = 12;
  repeated WorkerCrashCounter worker_crash_counters = 13;
}

message EnsureModelLoadedRequest {
  string node_id = 1;
  string model_id = 2;
  string version = 3;
  string artifact_sha256 = 4;
  bool preload = 5;
  uint64 deadline_unix_ms = 6;
  string artifact_source_uri = 7;
}

enum ModelLoadFailureCategory {
  MODEL_LOAD_FAILURE_CATEGORY_UNSPECIFIED = 0;
  MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID = 1;
  MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED = 2;
  MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE = 3;
  MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT = 4;
  MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED = 5;
  MODEL_LOAD_FAILURE_CATEGORY_INTERNAL = 6;
}

message EnsureModelLoadedResponse {
  bool already_loaded = 1;
  PlacementState placement_state = 2;
  ModelLoadFailureCategory failure_category = 3;
  string failure_code = 4;
  string failure_message = 5;
  bool worker_supports_prompt_token_ids = 6;
  optional RuntimeModelPlacement placement_capacity = 7;
}

`StatusResponse.supports_prompt_token_ids` MAY inform opt-in scheduler preference only. `EnsureModelLoadedResponse.worker_supports_prompt_token_ids` remains the authoritative per-request dispatch gate for controller-supplied `prompt_token_ids`.

enum FinishReason {
  FINISH_REASON_UNSPECIFIED = 0;
  FINISH_REASON_STOP = 1;
  FINISH_REASON_LENGTH = 2;
  FINISH_REASON_TOOL_CALLS = 3;
}

message GenerationParams {
  uint32 max_output_tokens = 1;
  double temperature = 2;
  double top_p = 3;
  repeated string stop_sequences = 4;
  bytes tools_json = 5;
  bytes tool_choice_json = 6;
}

message ScorePrefixCacheRequest {
  string request_id = 1;
  string controller_session_id = 2;
  ModelRef model_ref = 3;
  // Opaque HMAC fingerprint (hmac-sha256:<64 lowercase hex>) derived with the
  // same algorithm as ExecuteInferenceRequest.cache_affinity_fingerprint.
  // Prompt bytes and token IDs are forbidden on this RPC in v1.
  string cache_affinity_fingerprint = 4;
  uint64 deadline_unix_ms = 5;
}

message ScorePrefixCacheResponse {
  // ok | disabled | unavailable | model_not_loaded | timeout |
  // invalid_request | error | unsupported_version
  string status_code = 1;
  string status_message = 2;
  bool resident_fingerprint_match = 3;
  // resident_fingerprint | recent_fingerprint_only | no_match | unknown
  string score_tier = 4;
  uint64 session_started_unix_ms = 5;
}

message ExecuteInferenceRequest {
  string request_id = 1;
  string controller_session_id = 2;
  string model_id = 3;
  string version = 4;
  bytes rendered_prompt_utf8 = 5;
  uint32 input_tokens = 6;
  GenerationParams params = 7;
  uint64 deadline_unix_ms = 8;
  bytes metadata_json = 9;
  string cache_affinity_fingerprint = 10;
  repeated uint32 prompt_token_ids = 11;
  bool return_token_ids = 12;
  bool return_logprobs = 13;
}

message InferenceEvent {
  oneof event {
    Accepted accepted = 1;
    OutputTextDelta output_text_delta = 2;
    ToolCallDelta tool_call_delta = 3;
    UsageUpdate usage = 4;
    Completed completed = 5;
    Failed failed = 6;
    Progress progress = 7;
    TokenDelta token_delta = 8;
  }
}

message TokenDelta {
  repeated uint32 token_ids = 1;
  repeated float logprobs = 2;
}

message ToolCallDelta {
  string tool_call_id = 1;
  string delta_json = 2;
}

message Completed {
  FinishReason finish_reason = 1;
  TokenUsage usage = 2;
}
```

Internal tool-calling wire semantics:

* `GenerationParams.tools_json` SHALL contain a UTF-8 JSON array of the request tools; empty bytes mean tools omitted or disabled for the request
* `GenerationParams.tool_choice_json` SHALL contain a UTF-8 JSON scalar or object matching the public `tool_choice` value; empty bytes mean `null`
* `ToolCallDelta.delta_json` SHALL encode an object with the following logical shape:

```json
{
  "index": 0,
  "type": "function",
  "function": {
    "name": "lookup_weather",
    "arguments_delta": "{\"city\":\"Sing"
  }
}
```

* `ToolCallDelta.tool_call_id` SHALL remain stable for the life of that tool call within the request
* tool-call deltas SHALL preserve zero-based call index and append-only argument fragments in arrival order
* function arguments SHALL be derived from the provider's parsed function result, not the raw model-native tool wrapper; the Worker Runtime owns this normalization
* a complete-call parser MAY buffer one model-native block and emit one complete normalized argument fragment per parsed call; streaming does not require forwarding unparsed model tokens
* before publishing calls from a parsed block, the worker SHALL validate every call's requested function name and JSON argument object; malformed or unrequested calls SHALL fail without publishing that block or echoing its generated contents in errors
* cancellation or truncation SHALL discard unvalidated tool blocks; required closing markers MUST be present, and delimiter-free formats MUST reach a clean generation stop before parsing
* if a request completes successfully after emitting one or more tool-call deltas, the terminal `Completed.finish_reason` SHALL be `FINISH_REASON_TOOL_CALLS`

Internal token-streaming wire semantics:

* `ExecuteInferenceRequest.return_token_ids` and `ExecuteInferenceRequest.return_logprobs` are opt-in internal runtime capabilities; both default to false (omitted) and gate emission of `TokenDelta`
* `TokenDelta` SHALL be emitted only when the request opts in; when neither flag is set no `TokenDelta` is emitted and behavior is unchanged
* `TokenDelta.token_ids` carries raw sampled token IDs; `TokenDelta.logprobs`, when requested and available, aligns index-wise with `token_ids`
* raw sampled `TokenDelta.token_ids` MAY NOT align 1:1 with detokenized `OutputTextDelta` text deltas
* `TokenDelta` SHALL NOT be emitted after the terminal `Completed`/`Failed` event
* token-ID and logprob emission is fail-open: an unavailable or failed logprob source SHALL degrade to omitted `logprobs` and SHALL NOT fail the generation
* this is an internal runtime wire capability only; it is NOT exposed through the public `/v1` API, and the §7.2.4 public-API restriction on `logprobs`/`top_logprobs` remains in force in v1
* an explicit negotiated reasoning mode SHALL reject `return_token_ids = true` or `return_logprobs = true` before dispatch because the current `TokenDelta` does not carry a projection channel and can expose reconstructable hidden or framing tokens
* omitted `model_default + legacy_blended` requests preserve the existing `TokenDelta` opt-in behavior; negotiated modes MUST NOT enable either flag until a separately accepted channel-aware token-event contract defines projection, capture, and mixed-version behavior

Hosted-tool capability/readiness wire semantics:

* `StatusResponse.hosted_tool_capabilities` SHALL describe static hosted-tool advertisement only; it SHALL NOT be used to imply current readiness
* `StatusResponse.hosted_tool_readiness` SHALL describe dynamic readiness only; it SHALL NOT create hosted-tool identity independent of capability advertisement
* both hosted-tool lists SHALL align to controller registry identity via `name` + `version`, with canonical ref `tool://<name>@<version>`
* `hosted_tool_capabilities` and `hosted_tool_readiness` SHALL default to empty when omitted by an older node agent
* omitted hosted-tool fields SHALL mean “no advertised hosted tools” and SHALL preserve old-node / new-controller compatibility

Runtime memory-budget wire semantics:

* `StatusResponse.runtime_memory_budgets` SHALL report observe-only memory-budget snapshots for loaded runtime/model paths
* omitted or empty `runtime_memory_budgets` SHALL mean no memory-budget observation is available
* omitted or empty `runtime_memory_budgets` SHALL NOT be treated as a node status error, readiness failure, or admission failure
* `RuntimeMemoryBudget.status_code` values in this slice are: `ok`, `disabled`, `device_info_unavailable`, `device_info_invalid`, `resident_memory_unavailable`, `compute_failed`, `invalid_status`
* `RuntimeMemoryBudget.resident_memory_bytes` is copied from static manifest-derived model metadata; it is a lower-bound/payload-size estimate, not a runtime memory probe
* positive resident-memory metadata MAY make `status_code = ok` and `headroom_available = true` when the observe-only arithmetic has enough inputs; when `memory_admission.enabled = true`, that exact positive observation MAY be used by `Orchard.Scheduler.MultiNode` only as a non-gating, non-excluding ranking preference below loadedness, requested-placement active request count when known, health, live prefix-cache fingerprint match, historical cache affinity, and any enabled safe-tokenization capable-worker preference
* neither `RuntimeMemoryBudget.status_code` nor `RuntimeMemoryBudget.resident_memory_bytes` is an enforcement input; they remain observe-only and SHALL NOT alter readiness, request admission rejection, model admission, scheduler eligibility, hosted-tool eligibility, public error contracts, or queue ordering. The worker-side `memory_budget_mode = enforce` path (see §6.4) samples a live memory signal rather than these observe-only fields, so its abort behavior is not driven by `status_code` or `resident_memory_bytes`
* absent, empty, stale, malformed, disabled, unavailable, invalid, device-info-failed, compute-failed, non-`ok`, or `headroom_available != true` memory telemetry SHALL be rank-neutral and fail open
* `estimated_headroom_bytes` SHALL NOT be used as a threshold, continuous score, request-rejection input, or operator-tunable memory admission knob in this slice
* `RuntimeMemoryBudget.recommended_context_tokens` is an advisory, observe-only, memory-policy-derived context recommendation; `0` means unknown or not computable. It is computed fail-open as `min(catalog max_context_tokens, estimated_headroom_bytes / kv_cache_bytes_per_token)` and SHALL NOT override or gate the catalog `max_context_tokens`, request admission, model admission, scheduler eligibility, queue ordering, or `memory_budget_mode` enforcement
* scheduler memory eligibility SHALL continue to use the scheduler/model/node inputs defined elsewhere in this spec; Phase 4E promotes only the hard-coded `status_code = ok` plus `headroom_available = true` case to a non-excluding scheduler-ranking preference

Runtime prefix-cache observation semantics:

* Runtime Endpoint Observations SHALL report observe-only aggregate prefix-cache snapshots for loaded runtime/model paths
* the current gRPC Compatibility Adapter maps those observations to and from `StatusResponse.runtime_prefix_cache_statuses` through the existing `GetStatus` probe
* `prefix_cache_scoring.ranking_mode` defaults to `:observe_only`; in observe-only mode Orchard MAY issue a bounded `ScorePrefixCache` RPC only for the already-selected candidate, after ranking, and at most once per logical request
* when `prefix_cache_scoring.ranking_mode = :tie_only`, Orchard MAY additionally score only the challenger in the leading rank-equivalence group (equal on current ranking elements except final deterministic `node_id`, including any enabled safe-tokenization capable-worker preference), with total scored candidates capped at 2 per logical request (incumbent + challenger)
* both caps are per logical request and SHALL span its Inference Attempts; Automatic Attempt Retry SHALL NOT reallocate them, so an alternate-Node attempt SHALL score only within the unconsumed remainder and SHALL preserve deterministic base order fail-open once the request budget is exhausted
* tie-only mode SHALL NOT introduce top-N scoring, all-candidate scoring, prompt-byte fan-out, token-ID fan-out, or parallel score fan-out
* omitted or empty `runtime_prefix_cache_statuses` SHALL mean no prefix-cache observation is available
* omitted, empty, stale, unavailable, or invalid prefix-cache observations SHALL NOT be treated as a node status error, readiness failure, admission failure, model-admission failure, or scheduler-eligibility failure
* `RuntimePrefixCacheStatus.status_code` values in this slice are: `ok`, `disabled`, `unavailable`, `error`, `invalid_status`
* `RuntimePrefixCacheStatus.enabled` SHALL represent worker configuration capability, not active cache availability; `enabled=false` is reserved for explicitly disabled cache configuration
* public prefix-cache telemetry SHALL NOT expose prompt text, prompt tokens, tenant identifiers, raw prompt fingerprints, raw token sequences, or raw prefix-cache fingerprint sets
* `ExecuteInferenceRequest.cache_affinity_fingerprint` is an optional controller-derived opaque HMAC fingerprint. The controller SHALL populate it only when both `cache_affinity.enabled=true` and `cache_affinity.live_fingerprint_match_enabled=true`; otherwise it SHALL be omitted or empty.
* worker `WorkerPrefixCacheStatus.prefix_cache_fingerprints` and node-agent `RuntimePrefixCacheStatus.prefix_cache_fingerprints` SHALL carry only controller-derived `hmac-sha256:<64 lowercase hex>` values. Workers SHALL retain a bounded recent FIFO buffer of these values with default capacity 8 and implementation cap 64. The set is an approximation of recent request locality, not proof of current prefix-cache residency.
* the controller SHALL validate, deduplicate, and cap `RuntimePrefixCacheStatus.prefix_cache_fingerprints` to at most 64 entries before scheduler use. Invalid entries SHALL be dropped fail-open.
* raw prefix-cache fingerprint sets SHALL be scheduler-internal only. Persistence and tenant/operator telemetry surfaces SHALL expose only derived non-linkable fields such as fingerprint count, warmth indicator, and selected-candidate match boolean; they SHALL NOT persist or render the raw set.
* `ScorePrefixCacheRequest` in v1 SHALL carry only `cache_affinity_fingerprint` (`hmac-sha256:<64 lowercase hex>`). Prompt bytes and token IDs SHALL NOT be sent on this path.
* worker score behavior SHALL be non-mutating in v1: scoring SHALL NOT deep-copy cache entries, trim tokens, update LRU order, or mutate Phase 4B `hits`/`misses`/`failures` counters.
* `ScorePrefixCacheResponse.status_code` vocabulary is: `ok`, `disabled`, `unavailable`, `model_not_loaded`, `timeout`, `invalid_request`, `error`, `unsupported_version`.
* `ScorePrefixCacheResponse.score_tier` vocabulary is: `resident_fingerprint`, `recent_fingerprint_only`, `no_match`, `unknown`. `recent_fingerprint_only` is diagnostic/approximate and SHALL NOT be treated as authoritative residency.
* in `:observe_only` mode, score telemetry remains ranking-neutral and SHALL NOT alter runtime readiness, request admission, model admission, scheduler eligibility, queue ordering, hosted-tool eligibility, `worker_generation_mode`, or `memory_budget_mode` enforcement
* in `:tie_only` mode, score MAY affect ranking only as a bounded conditional step before final deterministic `node_id`, only for the leading rank-equivalence group (all current ranking elements equal except `node_id`, including any enabled safe-tokenization capable-worker preference), and only when an authoritative resident challenger (`status_code = "ok"`, `resident_fingerprint_match = true`, `score_tier = "resident_fingerprint"`) is compared against a comparable `ok` non-resident incumbent (`status_code = "ok"`, `resident_fingerprint_match = false`, `score_tier` is `"no_match"` or `"recent_fingerprint_only"`)
* in `:tie_only` mode, deterministic `node_id` ordering remains the fallback whenever promotion conditions are not met; any non-`ok`, timeout, `UNIMPLEMENTED`/`unsupported_version`, missing, malformed, or transport-failure score outcome for either incumbent or challenger SHALL preserve base order fail-open and SHALL never be surfaced as tenant-facing request errors

Runtime capacity and Placement Capacity observation semantics:

* `WorkerStatusResponse.active_request_count` SHALL report active `Generate` calls in that worker process
* `WorkerStatusResponse.max_concurrency` SHALL report the worker's effective overlapping `Generate` capacity; omitted or zero values SHALL be treated as worker capacity `1` by the node agent
* `StatusResponse.active_request_count` SHALL report aggregate active runtime requests across all loaded models on the node
* `StatusResponse.max_concurrency` SHALL report the Runtime Concurrency Enforcement Limit that the node agent will enforce across loaded models
* omitted or zero `StatusResponse.max_concurrency` SHALL mean the Runtime Concurrency Enforcement Limit is unknown or legacy; an explicitly unmanaged source-development or compatibility adapter MAY normalize it to `1`, while an admitted production Node SHALL receive Effective Dispatch Limit `0`
* Runtime Endpoint Observations SHALL report active request count and max concurrency for each loaded runtime/model path as Placement Capacity
* the current gRPC Compatibility Adapter maps Placement Capacity to and from `StatusResponse.runtime_model_placements` through the existing `GetStatus` probe
* omitted or empty Placement Capacity SHALL mean no explicit per-placement capacity observation is available
* omitted or empty Placement Capacity SHALL NOT be treated as an endpoint status error, readiness failure, admission failure, model-admission failure, or scheduler-eligibility failure for otherwise idle candidates
* a matching placement capacity observation is valid only when exactly one entry matches the requested `model_ref`, `active_request_count >= 0`, and `max_concurrency > 0`
* duplicate matching entries, malformed matching entries, non-matching entries, or `max_concurrency <= 0` SHALL make placement capacity unknown for that request
* a valid matching placement observation SHALL NOT override a shared authority decision with no positive available slots; under `f11_enforcing`, this includes exhausted Dispatch Headroom
* unknown placement capacity SHALL NOT prove eligibility for an already-active loaded-model candidate; an already-active loaded-model candidate MAY remain eligible only when exactly one valid matching entry reports `active_request_count < max_concurrency`
* when multiple eligible candidates remain, the scheduler SHALL rank by the requested placement's active request count before live cache-affinity and the remaining tie-breaks when a valid matching Placement Capacity observation is available; otherwise it SHALL use the endpoint aggregate `active_request_count`
* controller queue capacity MAY be refreshed from Runtime Endpoint Observations; loaded placement observations contribute only to their matching model/version lane, while cold/no-placement endpoint observations contribute conservative source-scoped capacity for queued lanes without exceeding the shared authority decision's available slots
* stale, unavailable, non-loaded, invalid, exhausted, ineligible, or transport-failed observations SHALL clear their endpoint-owned queue capacity sources instead of preserving stale admission capacity
* BEAM Runtime Endpoint observations MAY refresh queue capacity only when the target resolves back to the same persisted node identity; address-only or mismatched BEAM observations SHALL NOT publish queue capacity
* node-agent request admission SHALL reject a new runtime request when aggregate active request count has reached the effective aggregate worker request limit, even if the requested model placement has remaining per-placement capacity
* cancellation or terminal completion SHALL release aggregate node capacity so another loaded model can use the freed slot
* stream generation mode SHALL report `max_concurrency = 1` at both node and placement levels

* controller persistence of selected prefix-cache diagnostics in `requests.scheduler_decision` SHALL be guarded by `orchard_controller.inference.cache_introspection.enabled`, which defaults to `false`; when disabled, prefix-cache fields SHALL be stripped before scheduler-decision persistence
* score-RPC collection SHALL be default-off behind `orchard_controller.inference.prefix_cache_scoring.enabled` (default `false`).
* when both `prefix_cache_scoring.enabled=true` and `cache_introspection.enabled=true`, the controller MAY persist only sanitized flat `selected_prefix_cache_score_*` scalars for the selected candidate; for non-`ok` score status only bounded status/tier/source diagnostics MAY persist.
* when `cache_introspection.enabled=true`, the controller SHALL persist only sanitized flat `selected_prefix_cache_*` scalars for the selected candidate and SHALL NOT persist the raw nested `prefix_cache_status` map; non-`ok` statuses SHALL persist only status code and enabled flag
* this Phase 4B/4C/4D contract is traceable to the Phase 4 worker-prefix-cache introspection, bounded HMAC fingerprint publication, and score prefix-cache RPC planning artifacts

#### 7.5.3a Negotiated reasoning-generation contract

Reasoning generation and parsing SHALL be a versioned capability of the transport-independent Runtime Endpoint Interface and provider-neutral Worker Runtime contract.
Reasoning capability SHALL advertise complete supported tuples of generation policy, projection, model artifact digest, chat-template digest, render contract and version, parser family and version, runtime contract version, and event-binding version.
Separate lists whose Cartesian product could authorize a tuple that was not explicitly advertised are invalid capability evidence.
Candidate-time observations are advisory selection evidence only and cannot replace the loaded-worker execution proof; the narrow negotiated reasoning eligibility exception is specified below.
The Controller SHALL select an endpoint for an explicit `final_only` or `reasoning_structured` request only when a fresh observation advertises the exact complete tuple.
The sole carve-out is the pre-start queue re-grant specified below, where the earlier wave's placement may be reused strictly as a non-authoritative scheduling hint: that hint SHALL claim no reasoning support and SHALL confer no invocation authority, and the authoritative `PrepareInference` proof before model invocation SHALL stand in for the fresh observation.
Missing, stale, false, malformed, or unknown capability evidence SHALL prove no support for selection; whether such a result also counts toward exhaustion is decided by the closed probe result classes below.
An endpoint without a negotiated reasoning contract SHALL receive and emit legacy requests and events only.

For every negotiated dispatch, the loaded Worker Runtime SHALL validate the requested tuple and produce an authoritative execution-acceptance proof before model invocation.
That proof SHALL echo the complete tuple and identify the loaded worker incarnation that will execute the Request.
The Node Agent and Worker Runtime MUST NOT begin model execution, emit content, or emit usage before producing that proof.
The Controller SHALL validate the proof before accepting the attempt as running or forwarding any later event.
A missing, malformed, stale, or mismatched proof SHALL fail as `runtime_incompatible` before model invocation and SHALL NOT be repaired by a later status observation.
That Controller-detected acceptance failure SHALL record `retry_decision = not_retryable` and MUST NOT trigger Automatic Attempt Retry, unless caller cancellation or disconnect caused the terminal outcome or deadline terminalization was already proven before the proof failure won the terminal race; those outcomes retain `cancelled` and `retry_exhausted`, respectively.
An arbitrary Worker or Runtime Endpoint `Failed` event with code `runtime_incompatible` SHALL remain insufficient to authorize retry.
The accepted additive encoding uses an indivisible ten-field tuple of generation policy, projection, model artifact digest, chat-template digest, render contract and version, parser family and version, runtime contract version, and event-binding version; source provenance is not tuple identity. `WorkerCapabilities` field 8 is the deferred `WorkerLoadedBinding` allocation and field 9 is its sibling reasoning envelope, with shared cross-boundary tuple, evidence, preparation, and proof definitions in `proto/cluster/v1/reasoning.proto`. The implementation MUST re-confirm those field allocations at implementation time and block rather than substitute a conflicting number or shape. That shared file keeps cross-boundary reasoning types out of both the Worker package and the Controller transport package, and it makes the provider-neutral Worker Runtime boundary depend on `cluster.v1`; relocating or removing it is owned by the later `cluster.v1` deprecation sequencing and SHALL NOT be attempted by this contract or its implementation.

Reasoning evidence SHALL belong to exactly one valid loaded binding and that Worker Runtime's `service_incarnation`; every advertised tuple SHALL match that binding's artifact digest and resolve its selected profile exactly once. A present incomplete envelope, duplicate or conflicting tuple, unknown required value, missing binding, load replacement, unload, failed destructive unload, or worker teardown SHALL prove no support for selection and invalidate affected evidence and preparations; the probe result classes below decide whether such a result also counts toward exhaustion.

Reasoning evidence SHALL be available only through an opt-in live observation projection with a remaining freshness budget. It SHALL NOT be persisted in heartbeats or durable observations, and forwarding or serialization SHALL NOT refresh it. The explicit negotiated Request is the sole opt-in for that projection; no separate operator configuration flag SHALL enable, disable, or widen it. For an explicit negotiated Request only, the Controller MAY apply a narrow reasoning-specific eligibility predicate to a fresh exact tuple and select only an already loaded placement. This exception SHALL NOT make generic capability evidence authoritative for readiness, request admission, model admission, placement capacity, legacy scheduling, retry, or ordinary Runtime Endpoint projection. Only a fresh exact tuple SHALL permit selection, and an unloaded placement SHALL NOT be selected merely to discover reasoning support.

Every probe result SHALL fall into exactly one of three closed classes, because selection evidence SHALL NOT double as exhaustion evidence:

* **Proving.** A completed well-formed response whose evidence carries the exact tuple within its remaining freshness budget. That placement is observed, and this is the only class that permits selection.
* **Confirmed non-support.** A completed well-formed response that either explicitly reports the reasoning projection or the requested tuple unsupported, including the §13.1 mixed-version response of a binding that advertises no negotiated reasoning contract at all, or affirmatively returns valid evidence with an absent or mismatched tuple. That placement is observed and non-proving, and it counts toward exhaustion.
* **Unknown.** A completed response whose evidence is syntactically malformed or otherwise structurally invalid, including a present incomplete envelope, a duplicate or conflicting tuple, or an unknown required value, and likewise a timeout, a task exit, a transport failure, a missing response, or an otherwise incomplete probe. That placement SHALL remain unobserved: the result fails selection exactly as confirmed non-support does, but it SHALL NOT count toward exhaustion and SHALL route to the transient queue-waitable pre-dispatch unavailability specified below, because such a response was unreadable rather than a denial of support.

That reasoning-specific eligibility predicate SHALL consider only placements at §5.6 Tier 0 residency, whether resident from earlier traffic or prewarmed by a §6.10 `preload = true` pinning policy, so negotiated reasoning availability depends on loaded capacity that already exists. Orchard SHALL NOT load, cache, or download an artifact to create a negotiated candidate.

The predicate SHALL NOT reclassify ordinary capacity scarcity or unknown support as incompatibility. The §7.2.7 `503 server_error` plus `runtime_incompatible` pre-dispatch mapping SHALL apply only when the requested model has no loaded placement on an active trusted Node, or when every loaded placement of that model was probed and each returned confirmed non-support. When a proving placement exists but cannot be dispatched because aggregate slots or Dispatch Headroom are exhausted, placement concurrency is exceeded, or tenant active capacity is exhausted, and likewise whenever any loaded placement's support remains unknown through an unknown-class result, an elapsed wave deadline, or a withheld target, the Request SHALL take its existing `cluster_busy` or `model_busy` outcome and remain queue-waitable under §5.4's controller queue contract. Every one of those is transient pre-dispatch unavailability rather than proven incompatibility: a capacity-blocked, unreachable, or withheld loaded placement SHALL NOT be read as proof of no support, and none of those outcomes SHALL record `retry_decision = not_retryable`. Because a breaker-suppressed target is never probed, a breaker that opens after a fresh proof SHALL be handled by ordinary §5.10 scheduler suppression and §5.4 queue handling and SHALL NOT reclassify reasoning compatibility. That equivalence is limited to the queue outcome semantics: §12.4 still resolves the negotiated deadline through the loaded-only formula, so queue wait and wave time consume the same remaining request budget rather than a widened one.

The live observation SHALL run as one bounded wave over the reachable loaded-placement universe rather than the capacity-eligible subset: every loaded placement of the requested model on a scheduler-fresh active trusted Node satisfying the §5.5 health condition exactly as stated there, including those ordinary §5.5 eligibility excludes solely for exhausted aggregate slots or Dispatch Headroom, exceeded placement concurrency, or exhausted tenant active capacity, deduplicated on the same normalized target identity §5.5 uses for the candidate universe, ordered by the §5.7 ranking as it would apply to those placements with the deterministic lexicographic `node_id` tie-break last. Observing the capacity-blocked placements too is what lets exhaustion distinguish absent support from merely absent free capacity. A target that is not scheduler-fresh, fails that health condition, or is suppressed by the node-level or `(node, model)` placement-level §5.10 breaker SHALL be withheld from the wave rather than probed, so a placement that ranks ahead on its low active-request count cannot hold an in-flight slot it will never answer, and §5.10 suppression is not circumvented; a withheld target's support stays unknown.

The wave SHALL hold at most four probes in flight and SHALL advance through that deterministic order as probes complete, observing each placement at most once. Because the §5.7 ranking is capability-blind, a fixed leading window would strand reasoning-capable placements behind incapable higher-ranked ones; the advancing window SHALL NOT do so. One **2000 ms** deadline SHALL bound the whole wave rather than each target, and an individual probe transport SHALL NOT be retried.

The wave SHALL resolve to the highest-ranked proving placement, never to whichever probe answered first. A proof from a lower-ranked placement SHALL NOT end the wave until every higher-ranked in-flight probe has resolved non-proving, so completion latency SHALL NOT displace the §5.7 ranking. The wave SHALL otherwise stop on exhaustion of that ordered universe or when the wave deadline elapses. Exhaustion SHALL prove absent support only when every placement in that universe was probed and each returned confirmed non-support. An unknown-class result, an elapsed deadline, or a Node the wave withheld leaves support unknown, and unknown support SHALL route to the transient queue-waitable branch rather than to the permanent mapping.

The wave budget SHALL be per logical Request rather than per scheduling pass: one initial fresh wave, plus at most one further fresh wave for a real Automatic Attempt Retry after attempt 1 has started. A §5.4 pre-start busy re-grant SHALL run no new wave. It SHALL carry the wave's selected placement only as the non-authoritative scheduling hint carved out above from the fresh-observation selection rule. That hint SHALL claim no reasoning support and SHALL confer no invocation authority; `PrepareInference` remains the authoritative gate and SHALL revalidate the exact tuple against the current loaded binding before invocation, so a re-granted pass never invokes on expired selection evidence. A re-granted pass whose hinted placement still cannot be dispatched, or whose hint an unload or load replacement has invalidated, SHALL requeue or terminalize under §5.4's existing queue-wait budget and `queue_timeout` outcome rather than by re-probing.

Automatic Attempt Retry SHALL run its second wave fresh rather than reusing attempt 1's evidence, because forwarding SHALL NOT refresh a freshness budget and stale evidence proves no support. Attempt 2's wave SHALL apply `exclude_node_ids` first, rebuild and reorder its universe by that same deterministic rule, advance through it under the same four-in-flight bound and one **2000 ms** wave deadline with no transport retry, and obtain a new `PrepareInference` proof for the different selected endpoint. Both waves SHALL draw on the same absolute deadline §12.4 assigned. When that wave proves no different eligible candidate, the retry decision SHALL resolve to `no_alternative_node` unless an earlier reason in the §5.8 decline precedence applies.

The proof is carried by unary `PrepareInference` before negotiated execution. It SHALL return the authoritative complete-tuple and worker-incarnation proof plus an opaque single-use authorization bound to the Request, tuple, loaded binding, and current loaded worker instance. The Controller SHALL redeem the authorization only through the matching execution Request. Expiry, cancellation, duplicate redemption, worker restart, or loaded-instance replacement invalidates the authorization. A failed preparation leaves invocation, content, and usage at zero. Node Agent ownership of `Accepted` remains unchanged; negotiated `Accepted` follows successful preparation redemption.

The additive terminal wire contract SHALL preserve presence-aware exact cumulative totals: a present zero is known zero and absent `Failed.usage` is missing evidence, never zero. Issue #327 owns that wire representation. Durable `output_usage_status` persistence and Controller-synthesized lower-bound usage remain #329 work. Reasoning-token subsets remain Worker-internal.

Automatic retry SHALL pin all ten tuple fields but not worker incarnation, selected profile, preparation identity, or authorization. Operator retry SHALL reuse `requests.canonical_request["reasoning"]` only when full capture retained a valid value; otherwise it SHALL fail closed with `retry_source_unavailable` and SHALL NOT rerender historical messages, renegotiate, downgrade, or add a persistence column. Production tuple registries SHALL remain empty and no production tuple may be advertised or selected until parser, accounting, and capture guarantees plus model-qualification governance accept the exact tuple.

For a negotiated mode, the Worker Runtime SHALL run the pinned versioned stateful reasoning parser over the ordered decoded stream before tool-call classification and before caller stop-sequence classification.
Only final-answer text SHALL enter tool-call parsing.
Caller stop sequences SHALL apply only to ordinary final-answer text in the negotiated pipeline and SHALL NOT terminate hidden or selected reasoning.
Once tool-call emission begins, the existing rule preventing stop truncation of tool-call JSON remains in force.
Parser control markers are framing and MUST NOT be emitted as reasoning, final text, or tool content.
The legacy pipeline SHALL retain its existing tool and stop ordering when the reasoning control is omitted.
Tool argument byte preservation applies after provider normalization under §7.5.2; model-native wrappers are not public function arguments.

Unknown or unqualified output in omitted `legacy_blended` mode SHALL remain undifferentiated raw content under the existing pipeline.
An explicit `final_only` or `reasoning_structured` request SHALL fail closed when parser state is malformed, ambiguous, or cannot satisfy the pinned contract.
That failure MUST NOT fall back to raw blended output, expose the ambiguous bytes through an error, reclassify them as final text, or pass them to tool parsing.
The terminal failure SHALL be deterministic and non-retryable unless the failure occurred before model execution and independently satisfies the closed retry gates in §5.8.
For a negotiated Request with `generation_policy = disabled`, any observed reasoning frame or reasoning content SHALL terminalize as a generation-policy conformance failure.
For a negotiated Request with `generation_policy = enabled`, terminal completion without valid non-empty reasoning content SHALL terminalize as a generation-policy conformance failure.
Both failures SHALL use the post-execution `terminal_conformance + internal_error` mapping in §7.2.7, expose no selected output or parser content, and remain non-retryable.
`generation_policy = model_default` does not require reasoning to be present or absent, but all negotiated parser and projection rules still apply.

The Worker Runtime SHALL discard hidden reasoning content at the Worker contract boundary after accounting and MUST NOT forward it as text, metadata, errors, diagnostics, or an untyped event.
A typed internal reasoning delta MAY cross the Worker and Runtime Endpoint boundaries only when `projection = reasoning_structured`, the complete contract was negotiated before execution, and both bindings advertise support.
No new reasoning event SHALL be sent to an older or non-advertising binding.

Every Worker-originated terminal event SHALL carry exact cumulative total output usage for that attempt, including reasoning.
The Controller SHALL record that Worker-originated total with `output_usage_status = exact` in terminal Inference Attempt evidence.
When the Worker Runtime can prove an exact reasoning-token subset, it MAY retain that subset as Worker-internal non-content evidence; an unavailable or unproven subset SHALL remain unknown rather than defaulting to zero.
A Controller-synthesized terminal failure SHALL use the latest validated cumulative usage with `output_usage_status = lower_bound` when the Controller cannot prove the exact terminal total.
The reasoning-token subset MUST NOT cross the Runtime Endpoint or public API boundary until separate presence-aware contracts are accepted.

Automatic Attempt Retry for a negotiated Request SHALL pin the exact model artifact digest, chat-template digest, render contract and version, parser family and version, projection, generation policy, runtime contract version, and event-binding version from attempt 1.
Attempt 2 SHALL select a different endpoint that proves support for that same contract or Orchard SHALL decline retry.
Retry MUST NOT rerender, renegotiate, downgrade, or silently switch to `legacy_blended`.
An omitted legacy Request SHALL preserve `effective_contract.mode = legacy` and the existing legacy retry semantics rather than fabricating nullable negotiated identity.

#### 7.5.4 Node registration flow

```text
Admin creates bootstrap token or provisions node
  -> node agent starts
  -> RegisterNode
  -> controller creates/updates node record as registered
  -> controller returns signed cert
  -> admin admits node
  -> node heartbeats
  -> node becomes active
```

#### 7.5.5 ExecuteInference semantics

`ExecuteInference` SHALL:

* require placement already `loaded` or be preceded by `EnsureModelLoaded`
* return `Accepted` before long prefill starts
* stream deltas in order
* allow ordered mixtures of `output_text_delta`, `tool_call_delta`, `usage`, and `progress`
* allow typed internal reasoning deltas only under the negotiated contract in §7.5.3a
* include exactly one terminal `Completed` or `Failed`
* stop emitting additional events after the terminal event
* preserve normalized tool-call argument bytes exactly once tool-call emission has begun; stop-sequence handling SHALL NOT truncate tool-call JSON fragments
* when `prompt_token_ids` is non-empty, validate that `len(prompt_token_ids) == input_tokens` before any model invocation; on mismatch, return a structured `prompt_token_ids_length_mismatch` failure; on match, use the supplied IDs directly; when the field is empty, legacy workers and legacy dispatch paths continue to re-encode `rendered_prompt_utf8`
* a controller that receives a worker stream failure with code `prompt_token_ids_length_mismatch` SHALL emit `[:orchard, :tokenizer, :parity_drift]` with structured request/model/node metadata and a bounded worker message; the controller SHALL NOT parse length values from the message text
* a controller that observes catalog drift SHALL emit `[:orchard, :tokenizer, :catalog_drift]` with `%{count: 1}`, request/model metadata, `endpoint`, `bundle_id`, trusted `bundle_sha256` when available, `catalog_sha256`, bounded `added` token metadata, full `added_count`, and explicit `partial_detection: true`; the event SHALL NOT include `removed` entries until runtime helper re-extraction or source-tagged manifests exist
* be cancelled by request id

#### 7.5.6 Orphan request handling

Node agent SHALL cancel any active request if:

* controller stream disconnects
* `controller_session_id` is no longer current
* reconnection does not occur within 5000 ms

---

## 8. Database Schema

Postgres is the source of truth.

### 8.1 Extensions and enums

```sql
create extension if not exists pgcrypto;

create type node_state as enum (
  'provisioned',
  'registered',
  'admitted',
  'active',
  'cordoned',
  'draining',
  'maintenance',
  'decommissioning',
  'removed'
);

create type node_health as enum (
  'healthy',
  'degraded',
  'unhealthy',
  'unreachable'
);

create type node_admission_decision_kind as enum (
  'rejected',
  'rejection_cleared',
  'admitted'
);

create type node_dispatch_capacity_policy_state as enum (
  'shadow_legacy',
  'approved_explicit',
  'enforcing'
);

create type dispatch_capacity_enforcement_phase as enum (
  'pre_cutover',
  'enforcing'
);

create type beam_peer_grant_state as enum (
  'pending_delivery',
  'staged',
  'active',
  'superseded',
  'revoked',
  'expired',
  'delivery_failed'
);

create type worker_state as enum (
  'starting',
  'idle',
  'busy',
  'stopping',
  'failed',
  'stopped'
);

create type model_catalog_state as enum (
  'registered',
  'active',
  'deprecated',
  'retired'
);

create type placement_state as enum (
  'absent',
  'downloading',
  'downloaded',
  'verifying',
  'cached',
  'loading',
  'loaded',
  'unloading',
  'evicted',
  'failed'
);

create type request_state as enum (
  'received',
  'validated',
  'admitted',
  'queued',
  'scheduled',
  'dispatching',
  'running',
  'streaming',
  'completed',
  'failed',
  'cancelled',
  'timed_out',
  'interrupted'
);

create type tenant_status as enum ('active', 'suspended', 'deleted');
create type portal_user_status as enum ('invited', 'active', 'disabled');
create type api_key_status as enum ('active', 'revoked', 'expired');
create type actor_type as enum ('user', 'operator', 'service_account', 'api_key', 'node', 'system');
create type payload_capture_mode as enum ('none', 'metadata', 'full');
```

### 8.2 Core tables

```sql
create table node_pools (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  scheduling_weight integer not null default 100,
  default_max_cold_start_ms integer not null default 15000,
  labels jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table nodes (
  id uuid primary key default gen_random_uuid(),
  pool_id uuid references node_pools(id),
  hostname text not null,
  display_name text not null unique,
  advertise_addr text not null,
  canonical_beam_name text,
  rpc_port integer not null default 9444,
  state node_state not null default 'provisioned',
  health node_health not null default 'unreachable',
  join_method text not null check (join_method in ('bootstrap_token', 'certificate')),
  certificate_serial text,
  capabilities jsonb not null default '{}'::jsonb,
  labels jsonb not null default '{}'::jsonb,
  physical_memory_bytes bigint,
  chip_family text,
  os_version text,
  agent_version text,
  last_heartbeat_at timestamptz,
  admitted_at timestamptz,
  cordon_reason text,
  maintenance_reason text,
  decommission_reason text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table node_dispatch_capacity_policies (
  node_id uuid primary key references nodes(id) on delete cascade,
  policy_state node_dispatch_capacity_policy_state not null,
  controller_dispatch_ceiling integer,
  approved_by_actor_type actor_type,
  approved_by_actor_id text,
  approved_at timestamptz,
  approval_reason text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (policy_state = 'shadow_legacy'
      and controller_dispatch_ceiling is null
      and approved_by_actor_type is null
      and approved_by_actor_id is null
      and approved_at is null
      and approval_reason is null)
    or
    (policy_state in ('approved_explicit', 'enforcing')
      and controller_dispatch_ceiling is not null
      and controller_dispatch_ceiling >= 0
      and approved_by_actor_type is not null
      and approved_by_actor_id is not null
      and approved_at is not null
      and approval_reason is not null)
  )
);

create table dispatch_capacity_authority (
  singleton boolean primary key default true check (singleton),
  enforcement_phase dispatch_capacity_enforcement_phase not null default 'pre_cutover',
  required_contract_version integer not null default 1 check (required_contract_version > 0),
  cutover_by_actor_type actor_type,
  cutover_by_actor_id text,
  cutover_at timestamptz,
  cutover_reason text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (enforcement_phase = 'pre_cutover'
      and cutover_by_actor_type is null
      and cutover_by_actor_id is null
      and cutover_at is null
      and cutover_reason is null)
    or
    (enforcement_phase = 'enforcing'
      and cutover_by_actor_type is not null
      and cutover_by_actor_id is not null
      and cutover_at is not null
      and cutover_reason is not null)
  )
);

create table controller_instances (
  id uuid primary key,
  certificate_uri_san text not null unique,
  certificate_identifier text not null,
  certificate_fingerprint_sha256 text not null,
  canonical_beam_name text not null unique,
  beam_authorization_root_id uuid not null unique,
  authorization_root_custody_ref text not null,
  status text not null check (
    status in ('enrolled', 'operational', 'recovery_required', 'retired')
  ),
  software_version text,
  dispatch_capacity_contract_version integer not null default 0
    check (dispatch_capacity_contract_version >= 0),
  dispatch_capacity_consumers_ready boolean not null default false,
  dispatch_capacity_capability_observed_at timestamptz,
  first_enrolled_at timestamptz not null,
  last_seen_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table beam_peer_grants (
  id uuid primary key default gen_random_uuid(),
  generation bigint not null check (generation > 0),
  cluster_id uuid not null,
  controller_id uuid not null references controller_instances(id),
  controller_beam_name text not null,
  controller_certificate_identifier text not null,
  controller_certificate_fingerprint_sha256 text not null,
  beam_authorization_root_id uuid not null,
  node_id uuid not null references nodes(id),
  node_beam_name text not null,
  node_certificate_identifier text not null,
  node_certificate_fingerprint_sha256 text not null,
  contract_version integer not null check (contract_version > 0),
  purpose text not null,
  state beam_peer_grant_state not null default 'pending_delivery',
  secret_hash bytea not null check (octet_length(secret_hash) = 32),
  issued_at timestamptz not null,
  not_before_at timestamptz not null,
  cutover_at timestamptz,
  expires_at timestamptz not null,
  delivery_evidence jsonb not null default '{}'::jsonb,
  activation_evidence jsonb not null default '{}'::jsonb,
  supersession_evidence jsonb not null default '{}'::jsonb,
  failure_evidence jsonb not null default '{}'::jsonb,
  revocation_evidence jsonb not null default '{}'::jsonb,
  delivered_at timestamptz,
  activated_at timestamptz,
  superseded_at timestamptz,
  failed_at timestamptz,
  revoked_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cluster_id, controller_id, node_id, purpose, generation),
  check (expires_at > not_before_at),
  check (cutover_at is null or cutover_at >= not_before_at),
  check (cutover_at is null or cutover_at <= expires_at)
);

create table node_heartbeats (
  id bigserial primary key,
  node_id uuid not null references nodes(id) on delete cascade,
  observed_at timestamptz not null default now(),
  health node_health not null,
  available_memory_bytes bigint,
  swap_used_bytes bigint,
  cpu_load_1m numeric(8,2),
  thermal_pressure text,
  active_requests integer not null default 0,
  payload jsonb not null default '{}'::jsonb
);

create table node_admission_candidates (
  id uuid primary key default gen_random_uuid(),
  node_id uuid references nodes(id) on delete set null,
  source text not null check (
    source in (
      'runtime_endpoint_observation',
      'provisioned_placeholder',
      'registered_node'
    )
  ),
  admission_category text not null check (
    admission_category in (
      'pending_observed',
      'pending_provisioned',
      'pending_registered',
      'rejected',
      'admitted'
    )
  ),
  observed_identity jsonb not null default '{}'::jsonb,
  target_ref text,
  endpoint_transport text check (endpoint_transport in ('grpc', 'beam', 'external')),
  endpoint_target text,
  inventory jsonb not null default '{}'::jsonb,
  compatibility_evidence jsonb not null default '{}'::jsonb,
  last_observed_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    source <> 'runtime_endpoint_observation'
    or last_observed_at is not null
  )
);

create table models (
  id uuid primary key default gen_random_uuid(),
  model_id text not null,
  version text not null,
  state model_catalog_state not null default 'registered',
  format text not null check (format in ('mlx', 'gguf')),
  capabilities jsonb not null default '{}'::jsonb,
  capability_evidence jsonb,
  tokenizer jsonb not null default '{}'::jsonb,
  artifact_uri text,
  artifact_sha256 text not null,
  artifact_size_bytes bigint not null,
  resident_memory_bytes bigint not null,
  kv_cache_bytes_per_token bigint not null,
  prefill_workspace_bytes_per_token bigint not null,
  max_context_tokens integer not null,
  default_parameters jsonb not null default '{}'::jsonb,
  runtime_requirements jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(model_id, version)
);

create table model_placements (
  id uuid primary key default gen_random_uuid(),
  node_id uuid not null references nodes(id) on delete cascade,
  model_id uuid not null references models(id) on delete cascade,
  state placement_state not null default 'absent',
  local_path text,
  bytes_on_disk bigint not null default 0,
  resident_bytes bigint not null default 0,
  checksum_verified boolean not null default false,
  pinned boolean not null default false,
  pin_priority integer not null default 100,
  active_request_count integer not null default 0,
  max_concurrency integer not null default 1,
  last_used_at timestamptz,
  load_started_at timestamptz,
  load_completed_at timestamptz,
  evicted_at timestamptz,
  last_error_code text,
  last_error_message text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(node_id, model_id)
);

create table workers (
  id uuid primary key default gen_random_uuid(),
  node_id uuid not null references nodes(id) on delete cascade,
  model_id uuid not null references models(id) on delete cascade,
  placement_id uuid not null references model_placements(id) on delete cascade,
  slot smallint not null default 0,
  runtime_adapter text not null,
  state worker_state not null,
  pid integer,
  listen_path text,
  capabilities jsonb not null default '{}'::jsonb,
  last_heartbeat_at timestamptz,
  restart_count integer not null default 0,
  last_error_code text,
  last_error_message text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(node_id, model_id, slot)
);

create table tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  status tenant_status not null default 'active',
  default_pool_id uuid references node_pools(id),
  request_body_capture_mode payload_capture_mode not null default 'metadata',
  settings jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table portal_users (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  email text not null,
  normalized_email text not null,
  password_hash text,
  status portal_user_status not null default 'invited',
  session_epoch bigint not null default 0,
  disabled_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(tenant_id, normalized_email),
  check (length(normalized_email) > 0),
  check (password_hash is null or length(password_hash) > 0),
  check (session_epoch >= 0),
  check ((status = 'active' and password_hash is not null and disabled_at is null)
    or (status = 'invited' and disabled_at is null)
    or (status = 'disabled' and disabled_at is not null))
);

create table portal_invite_tokens (
  id uuid primary key default gen_random_uuid(),
  portal_user_id uuid not null unique references portal_users(id) on delete cascade,
  token_hash bytea not null unique,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  inserted_at timestamptz not null default now(),
  check (octet_length(token_hash) = 32)
);

create table service_accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null,
  owner_contact text not null,
  owner_name text,
  team text,
  external_ref text,
  description text,
  purpose text,
  metadata jsonb not null default '{}'::jsonb,
  disabled_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(tenant_id, name),
  unique(tenant_id, external_ref)
);

create table api_keys (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenants(id),
  service_account_id uuid references service_accounts(id),
  portal_user_id uuid references portal_users(id) on delete set null,
  name text not null,
  token_prefix text not null unique,
  secret_hash bytea not null,
  issuance_surface text not null default 'governance',
  expires_at timestamptz,
  last_used_at timestamptz,
  revoked_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (tenant_id is not null and service_account_id is null)
    or
    (tenant_id is null and service_account_id is not null)
  ),
  check (issuance_surface in ('governance', 'developer_portal')),
  check (
    (issuance_surface = 'governance' and portal_user_id is null)
    or
    (issuance_surface = 'developer_portal' and tenant_id is not null and service_account_id is null)
  )
);

create table portal_sessions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  portal_user_id uuid not null references portal_users(id) on delete cascade,
  token_hash bytea not null unique,
  session_epoch bigint not null,
  issued_at timestamptz not null,
  last_seen_at timestamptz not null,
  absolute_expires_at timestamptz not null,
  inserted_at timestamptz not null default now(),
  check (octet_length(token_hash) = 32),
  check (session_epoch >= 0),
  check (last_seen_at >= issued_at),
  check (absolute_expires_at > issued_at)
);

create table portal_login_throttles (
  organization_fingerprint bytea not null,
  user_fingerprint bytea not null,
  source_fingerprint bytea not null,
  failure_count integer not null default 0,
  blocked_until timestamptz,
  last_failed_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_fingerprint, user_fingerprint, source_fingerprint),
  check (octet_length(organization_fingerprint) = 32),
  check (octet_length(user_fingerprint) = 32),
  check (octet_length(source_fingerprint) = 32),
  check (failure_count >= 0)
);

create table quotas (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null,
  requests_per_minute integer,
  concurrent_requests integer,
  input_tokens_per_day bigint,
  output_tokens_per_day bigint,
  max_context_tokens integer,
  max_output_tokens integer,
  max_queue_wait_ms integer not null default 3000,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table requests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique,
  endpoint text not null check (endpoint in ('chat_completions', 'responses')),
  tenant_id uuid not null references tenants(id),
  principal_type text not null default 'tenant' check (principal_type in ('tenant', 'service_account')),
  api_key_id uuid references api_keys(id),
  service_account_id uuid references service_accounts(id),
  model_id uuid not null references models(id),
  requested_model text not null,
  node_id uuid references nodes(id),
  worker_id uuid references workers(id),
  retry_of_request_id uuid references requests(id),
  idempotency_key text,
  body_hash bytea,
  state request_state not null default 'received',
  stream boolean not null default false,
  payload_capture_mode payload_capture_mode not null default 'metadata',
  canonical_request jsonb,
  request_shape jsonb,
  request_payload jsonb,
  response_payload jsonb,
  response_hash bytea,
  response_preview text,
  sampling_params jsonb not null default '{}'::jsonb,
  response_format jsonb not null default '{}'::jsonb,
  scheduler_decision jsonb,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  output_usage_status text check (output_usage_status is null or output_usage_status in ('exact', 'lower_bound')),
  reserved_output_tokens integer not null default 0,
  first_token_at timestamptz,
  completed_at timestamptz,
  timeout_at timestamptz,
  http_status integer,
  error_code text,
  error_message text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (principal_type <> 'service_account' or service_account_id is not null),
  check (
    payload_capture_mode = 'full'
    or (
      canonical_request is null
      and request_payload is null
      and response_payload is null
      and error_message is null
    )
  ),
  check (
    payload_capture_mode <> 'none'
    or (request_shape is null and response_preview is null)
  ),
  check (
    payload_capture_mode = 'full'
    or error_code is null
    or error_code in (
      'acquisition_failed',
      'artifact_not_found',
      'cancelled',
      'checksum_mismatch',
      'cluster_busy',
      'deadline_exceeded',
      'insufficient_memory',
      'internal_error',
      'load_timeout',
      'manifest_not_found',
      'mlx_backend_unavailable',
      'model_busy',
      'model_invalid',
      'node_timeout',
      'node_unavailable',
      'orchestration_error',
      'queue_full',
      'queue_timeout',
      'request_cancelled',
      'request_caller_disconnect',
      'request_client_disconnect',
      'request_controller_restarted',
      'request_interrupted',
      'request_timeout',
      'resource_exhausted',
      'rpc_error',
      'rpc_resource_exhausted',
      'rpc_unavailable',
      'runtime_incompatible',
      'runtime_unavailable',
      'timed_out',
      'timeout',
      'tool_execution_cancelled',
      'tool_execution_failed',
      'tool_execution_indeterminate_cancel_ack_missing',
      'tool_execution_indeterminate_controller_restarted',
      'tool_execution_indeterminate_executor_unreachable',
      'tool_execution_indeterminate_result_not_observed',
      'tool_execution_indeterminate_timeout_after_start',
      'tool_execution_timed_out',
      'tool_failed',
      'tool_timeout',
      'tooling_not_supported',
      'unexpected_placement_state',
      'worker_down',
      'worker_unavailable',
      'worker_unloaded'
    )
  ),
  check (response_preview is null or char_length(response_preview) <= 512)
);

create table request_events (
  id bigserial primary key,
  request_id uuid not null references requests(id) on delete cascade,
  seq integer not null,
  event_type text not null,
  state request_state,
  occurred_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  unique(request_id, seq)
);

create table audit_logs (
  id bigserial primary key,
  scope text not null default 'tenant' check (scope in ('tenant', 'cluster')),
  tenant_id uuid references tenants(id),
  api_key_id uuid references api_keys(id) on delete restrict, -- accepted target (§10.11), pending migration
  actor_type actor_type not null,
  actor_id text,
  -- Accepted target schema and typed authentication fields (§10.11), pending migration.
  payload_schema text,
  actor_principal_type text,
  actor_credential_type text,
  actor_credential_id uuid,
  action text not null,
  target_type text not null,
  target_id text,
  occurred_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  check (
    (scope = 'tenant' and tenant_id is not null)
    or
    (scope = 'cluster' and tenant_id is null)
  )
);

create table node_admission_decisions (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid references node_admission_candidates(id) on delete set null,
  node_id uuid references nodes(id) on delete set null,
  decision node_admission_decision_kind not null,
  actor_type actor_type not null,
  actor_id text,
  reason text,
  observed_identity jsonb not null default '{}'::jsonb,
  target_ref text,
  audit_log_id bigint references audit_logs(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  decided_at timestamptz not null default now(),
  inserted_at timestamptz not null default now()
);
```

`requests.output_usage_status` SHALL be a nullable expand-migration column with no default and no backfill.
A null status SHALL mean the row predates durable usage-status persistence; Orchard MUST NOT infer, backfill, or present `exact` or `lower_bound` for such a row.

`node_admission_candidates` SHALL store first-observed Runtime Endpoint metadata before it is reconciled to a trusted Node.
Rows MAY also link review state for provisioned placeholders or registered Nodes through `node_id`, but `admission_category` remains derived review state, not a `node_state` lifecycle enum.
At candidate creation time, `node_id` SHOULD be present for `source = 'provisioned_placeholder'` or `source = 'registered_node'` when the referenced Node row exists.
`node_id` MAY later become null through retention cleanup because candidate rows retain bounded snapshot fields in `observed_identity`, `target_ref`, `endpoint_transport`, `endpoint_target`, `inventory`, and `compatibility_evidence`.
`last_observed_at` SHALL be populated for `source = 'runtime_endpoint_observation'` and whenever the candidate row represents a concrete Runtime Endpoint observation.
`last_observed_at` MAY be null for provisioned placeholder or registered Node review rows before any Runtime Endpoint observation has occurred.
Candidate `observed_identity`, `inventory`, `compatibility_evidence`, `target_ref`, and `endpoint_target` SHALL be sanitized and bounded.
They MUST NOT contain plaintext secrets, credentials, DSNs, prompt bodies, response bodies, raw local evidence logs, local tool session identifiers, or machine-specific prompt exports.
`target_ref` and `endpoint_target` are operator-review references only and SHALL NOT prove Node identity ownership.
No uniqueness or reconciliation decision SHALL depend on `target_ref` or `endpoint_target` alone.

`controller_instances` SHALL store durable Controller membership identity and only an opaque local custody reference for the BEAM Authorization Root.
The custody reference SHALL NOT contain the root value, a recoverable encoding of the root, credentials, or machine-specific path details exposed through operator surfaces.

The immutable `beam_peer_grants` scope columns SHALL not change after insert.
Lifecycle transitions SHALL update only state, bounded sanitized evidence, transition timestamps, and `updated_at`.
Grant evidence SHALL NOT contain the plaintext secret, root material, certificate private keys, raw OTP exception terms, or local custody paths.

`node_admission_decisions` SHALL store durable admission decisions for rejection, rejection clearance, and admission after rejection.
A rejection SHALL write `decision = 'rejected'`, actor, decided timestamp, reason, observed identity or node reference, target reference when applicable, and `audit_log_id`.
Clearing a rejection SHALL write `decision = 'rejection_cleared'` and a related audit event.
Admitting after rejection SHALL write `decision = 'admitted'` and a related audit event.
Decision rows SHALL NOT be updated in place to change the historical decision; later decisions append new rows.
At decision creation time, either `candidate_id` or `node_id` SHOULD be present when the referenced candidate or Node exists.
Both references MAY later become null through retention cleanup, because decision rows retain bounded snapshot fields in `observed_identity`, `target_ref`, `reason`, `metadata`, and `audit_log_id` when present.

Audit log `scope` SHALL distinguish tenant-scoped and cluster-scoped governance events.
Tenant-scoped audit events SHALL set `scope = 'tenant'` and a non-null `tenant_id`.
Cluster-scoped audit events SHALL set `scope = 'cluster'` and a null `tenant_id`.
Node admission candidate review, node admission rejection, rejection clearance, admission after rejection, Controller Dispatch Ceiling approval or change, dispatch-capacity enforcement cutover, Controller-instance retirement, node decommission, and Active/Standby status-affecting writes SHALL use cluster-scoped audit events unless a future accepted contract makes them tenant-owned.
Audit log `actor_type` SHALL identify the provenance class of the action.
`operator` represents operator and admin product surfaces such as Orchard Console, Orchard CLI, Operator API, and Admin API actions.
`actor_id` MAY be null for `system` actions, historical anonymous Console records, and bounded local recovery actions that do not authenticate a named human.
The accepted named-Console target SHALL use the actual Console Identity UUID under §10.11; a local recovery actor SHALL NOT be represented as a named human.
Audit log `payload` MAY include `surface` to preserve the originating product surface, for example `console` or `cli`, when that context is useful for governance review.
For the migrated credential family, server-known provenance SHALL be `console` or `admin_api`; a portable CLI's HTTP request SHALL use `admin_api` and SHALL NOT establish trusted CLI provenance through a client claim.

The audit schema above includes accepted target columns and restrictive key-reference retention required by §10.11; it does not claim those migrations are implemented.
Expand migrations SHALL add nullable schema and typed authentication fields without backfilling historical attribution or rewriting append-only audit rows.
New discriminated events SHALL meet §10.11's schema-specific requirements; null discriminators SHALL preserve legacy decoding.
Credential, session, and identity cleanup SHALL retain stable historical actor, authenticating-credential, and target identifiers and MUST NOT null, rewrite, or cascade-delete them.
The current pre-cutover key foreign-key behavior that permits `ON DELETE SET NULL` SHALL be replaced before cleanup is accepted under the named authorization contract.

### 8.3 Supplemental governance tables

The `console_identity` RoleBinding subject below is an accepted target extension under §10.11 and remains pending implementation with Console Identity and Session storage.
The extension SHALL preserve existing machine/inference subjects and SHALL NOT convert their descriptive metadata into human grants.

```sql
create table role_bindings (
  id uuid primary key default gen_random_uuid(),
  -- console_identity is an accepted target subject (§10.11), pending migration.
  principal_type text not null check (principal_type in ('tenant', 'service_account', 'api_key', 'console_identity')),
  principal_id uuid not null,
  role text not null check (role in ('admin', 'operator', 'tenant_admin', 'inference_client')),
  tenant_scope_id uuid references tenants(id) on delete cascade,
  inserted_at timestamptz not null default now(),
  unique(principal_type, principal_id, role, tenant_scope_id)
);

create table provisioning_batches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  actor_type text not null default 'operator',
  actor_id text,
  status text not null check (status in ('applying', 'applied', 'failed', 'output_failed')),
  row_count integer not null default 0,
  api_clients_created_count integer not null default 0,
  api_clients_updated_count integer not null default 0,
  api_tokens_created_count integer not null default 0,
  api_tokens_rotated_count integer not null default 0,
  api_tokens_revoked_count integer not null default 0,
  input_sha256 text,
  error_summary jsonb not null default '{}'::jsonb,
  started_at timestamptz not null,
  completed_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table routing_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenants(id),
  name text not null,
  allowed_pool_ids uuid[] not null default '{}',
  preferred_pool_ids uuid[] not null default '{}',
  residency_preference text not null check (
    residency_preference in ('required_loaded', 'prefer_loaded', 'allow_cold_load')
  ),
  max_cold_start_ms integer not null default 15000,
  max_queue_wait_ms integer not null default 3000,
  priority integer not null default 100,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table tenant_model_access (
  tenant_id uuid not null references tenants(id) on delete cascade,
  model_id uuid not null references models(id) on delete cascade,
  enabled boolean not null default true,
  routing_policy_id uuid references routing_policies(id),
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, model_id)
);

create table bootstrap_tokens (
  id uuid primary key default gen_random_uuid(),
  token_prefix text not null unique,
  token_hash bytea not null,
  pool_id uuid references node_pools(id),
  expected_hostname text,
  single_use boolean not null default true,
  expires_at timestamptz not null,
  used_at timestamptz,
  inserted_at timestamptz not null default now()
);

create table cluster_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
```

### 8.4 Required indexes and constraints

```sql
create index idx_node_heartbeats_node_observed_at
  on node_heartbeats(node_id, observed_at desc);

create index idx_node_admission_candidates_category_observed
  on node_admission_candidates(admission_category, last_observed_at desc nulls last);

create index idx_node_admission_candidates_node
  on node_admission_candidates(node_id)
  where node_id is not null;

create index idx_node_admission_candidates_open_target_ref
  on node_admission_candidates(target_ref)
  where node_id is null
    and target_ref is not null
    and admission_category in ('pending_observed', 'rejected');

create index idx_node_admission_decisions_candidate_decided
  on node_admission_decisions(candidate_id, decided_at desc)
  where candidate_id is not null;

create index idx_node_admission_decisions_node_decided
  on node_admission_decisions(node_id, decided_at desc)
  where node_id is not null;

create index idx_node_admission_decisions_audit_log
  on node_admission_decisions(audit_log_id)
  where audit_log_id is not null;

create unique index idx_nodes_canonical_beam_name
  on nodes(canonical_beam_name)
  where canonical_beam_name is not null;

create index idx_node_dispatch_capacity_policies_state
  on node_dispatch_capacity_policies(policy_state, updated_at desc);

create index idx_controller_instances_status_seen
  on controller_instances(status, last_seen_at desc nulls last);

create index idx_beam_peer_grants_controller_node_generation
  on beam_peer_grants(cluster_id, controller_id, node_id, purpose, generation desc);

create index idx_beam_peer_grants_state_expiry
  on beam_peer_grants(state, expires_at);

create unique index idx_beam_peer_grants_one_active
  on beam_peer_grants(cluster_id, controller_id, node_id, purpose)
  where state = 'active';

create unique index idx_beam_peer_grants_one_staged
  on beam_peer_grants(cluster_id, controller_id, node_id, purpose)
  where state = 'staged';

create index idx_model_placements_node_state
  on model_placements(node_id, state);

create index idx_model_placements_model_state
  on model_placements(model_id, state);

create index idx_requests_tenant_inserted_at
  on requests(tenant_id, inserted_at desc);

create index idx_requests_active_by_tenant
  on requests(tenant_id, state)
  where state in ('admitted','queued','scheduled','dispatching','running','streaming');

create unique index idx_requests_tenant_idempotency
  on requests(tenant_id, idempotency_key)
  where idempotency_key is not null;

create unique index idx_service_accounts_tenant_name
  on service_accounts(tenant_id, name);

create unique index idx_service_accounts_tenant_external_ref
  on service_accounts(tenant_id, external_ref)
  where external_ref is not null;

create index idx_service_accounts_tenant_team
  on service_accounts(tenant_id, team);

create index idx_api_keys_service_account_inserted_at
  on api_keys(service_account_id, inserted_at);

create index idx_api_keys_portal_user_inserted_at
  on api_keys(portal_user_id, inserted_at)
  where portal_user_id is not null;

create index idx_portal_sessions_user_expiry
  on portal_sessions(portal_user_id, absolute_expires_at);

create extension if not exists btree_gist;

alter table api_keys
  add constraint api_keys_service_account_active_name_no_overlap
  exclude using gist (
    service_account_id with =,
    name with =,
    tsrange(
      inserted_at,
      greatest(
        inserted_at,
        least(
          coalesce(revoked_at, 'infinity'::timestamp),
          coalesce(expires_at, 'infinity'::timestamp)
        )
      ),
      '[)'
    ) with &&
  )
  where (service_account_id is not null);

create unique index idx_role_bindings_unique_assignment
  on role_bindings(principal_type, principal_id, role, tenant_scope_id);

create index idx_provisioning_batches_tenant_inserted_at
  on provisioning_batches(tenant_id, inserted_at);

create index idx_audit_logs_tenant_occurred_at
  on audit_logs(tenant_id, occurred_at desc)
  where scope = 'tenant';

create index idx_audit_logs_cluster_occurred_at
  on audit_logs(occurred_at desc)
  where scope = 'cluster';
```

### 8.5 Data retention defaults

* `node_heartbeats`: 7 days
* `node_admission_candidates`: unresolved candidates until admin resolution; resolved candidate metadata 90 days minimum
* `node_admission_decisions`: 365 days minimum
* `controller_instances`: retained while enrolled or referenced by retained Peer Grant history
* `beam_peer_grants`: pending, staged, and active records retained; terminal lifecycle history 365 days minimum
* `request_events`: 30 days
* `requests`: 90 days metadata minimum
* `audit_logs`: 365 days minimum

Payload retention follows the effective capture mode snapshotted on each Request; see §10.10.

---

## 9. Observability

The implementation SHALL expose:

* Prometheus metrics
* OpenTelemetry traces
* structured JSON logs

OpenTelemetry Erlang/Elixir currently documents traces as stable while metrics/logs are still developing. Therefore this system SHALL use **OTel for tracing** and a **native Prometheus endpoint for metrics**, rather than relying on OTel metrics as the primary metric path. ([OpenTelemetry][7])

### 9.1 Metrics endpoint

* controller: `/metrics`
* node agent: `/metrics` optional, disabled externally by default

The Controller SHALL serve `GET /metrics` on its existing HTTP listener and SHALL NOT create a separate metrics listener. The route SHALL require the cluster-scoped operator-or-admin service-account bearer boundary defined for the Operator API. Metrics initialization, collection, aggregation, and rendering are non-authoritative: their failure SHALL NOT prevent Controller boot or alter inference, admission, quota, scheduling, dispatch, recovery, or persistence outcomes. An authorized scrape MAY return `503` when valid exposition cannot be produced.

The protected site-local endpoint MAY expose the canonical stable Tenant identifier as the raw `tenant` label. Orchard SHALL NOT hash, alias, truncate, or substitute that identifier for the pilot, and SHALL NOT include a user identifier as a metric label. Any later external metrics egress SHALL remove tenant and user dimensions before transmission.

Required metric families:

**HTTP/API**

* `orchard_http_requests_total{endpoint,method,status}`
* `orchard_http_request_duration_seconds_bucket{endpoint,status}`

**Inference**

* `orchard_inference_requests_total{endpoint,tenant,model,status}`
* `orchard_inference_request_duration_seconds_bucket{tenant,model,status}`
* `orchard_inference_attempts_total{attempt,outcome,failure_class}`
* `orchard_inference_attempt_duration_seconds_bucket{attempt,outcome}`
* `orchard_inference_retries_total{reason,result}`
* `orchard_input_tokens_total{tenant,model}`
* `orchard_output_tokens_total{tenant,model}`
* `orchard_decode_tokens_per_second_bucket{model,node}`

Logical Request metrics SHALL count admission, quota, tokens, public outcome, and Request duration once per Request.
Attempt metrics SHALL count every started attempt.
For `orchard_inference_attempts_total`, `attempt` SHALL be `1` or `2`, `outcome` SHALL use the closed `attempt_outcome` vocabulary in §3.7.1, and `failure_class` SHALL use the closed §3.7.1 failure vocabulary for non-completed attempts or the metric-only value `none` for completed attempts.
`orchard_inference_retries_total` SHALL emit exactly once for each Request whose attempt 1 records a retry decision.
Its closed `reason` vocabulary SHALL be `retried`, `not_retryable`, `output_committed`, `cancelled`, `budget_exhausted`, `identity_unresolved`, `occupancy_unresolved`, or `no_alternative_node`, and its closed `result` vocabulary SHALL be `succeeded`, `failed`, or `declined`.
`reason = "retried"` SHALL pair only with `result` of `succeeded` or `failed`; each attempt 1 decline reason SHALL pair only with `result = "declined"`; `retry_exhausted` SHALL never label this counter.
A retried Request whose attempt 2 does not complete SHALL emit `result = "failed"`, including cancelled and timed-out attempt 2 outcomes.
Metric labels SHALL use closed vocabularies and SHALL NOT contain Request IDs, Node IDs, target addresses, claim tokens, or arbitrary runtime codes.

**Scheduler**

* `orchard_scheduler_decisions_total{result,tier}`
* `orchard_scheduler_duration_seconds_bucket`
* `orchard_scheduler_queue_depth{tenant}`
* `orchard_scheduler_rejections_total{reason}`

**Node/runtime**

* `orchard_node_heartbeat_lag_seconds{node}`
* `orchard_node_available_memory_bytes{node}`
* `orchard_node_swap_used_bytes{node}`
* `orchard_active_requests{node,model}`
* `orchard_model_load_duration_seconds_bucket{node,model}`
* `orchard_model_resident{node,model}`
* `orchard_worker_crashes_total{node,model}`

**Quotas/governance**

* `orchard_quota_rejections_total{tenant,reason}`
* `orchard_api_key_auth_failures_total`
* `orchard_audit_events_total{action,outcome}`

The audit action label SHALL use only `tenant`, `api_key`, `service_account`, `role_binding`, `routing_policy`, `tenant_model_access`, `node_admission`, `node_lifecycle`, `circuit_breaker`, `cluster`, or `portal_user`.
The audit outcome label SHALL use only `succeeded`, `failed`, or `denied`.
Those eleven domains and three outcomes reserve exactly 33 audit series.
The accepted Controller metrics floor is 2,597 series.
The already accepted and implemented inference attempt and retry families add 229 series, so the runtime worksheet SHALL total 2,826 and retain 2,174 series of headroom below the 5,000-series ceiling.

### 9.2 Tracing

Required trace spans:

* `http.request`
* `auth.authenticate`
* `auth.authorize`
* `tokenize.render`
* `admission.check`
* `scheduler.select_node`
* `dispatch.ensure_model_loaded`
* `dispatch.execute_inference`
* `worker.prefill`
* `worker.decode`
* `stream.forward`
* `accounting.commit`

Required trace attributes:

* `request.id`
* `tenant.id`
* `model.id`
* `model.version`
* `node.id`
* `worker.id`
* `api.endpoint`
* `queue.wait_ms`
* `cold_load`
* `first_token_ms`
* `input_tokens`
* `output_tokens`

### 9.3 Logging

All logs SHALL be JSON, one object per line.

Required fields:

* `ts`
* `level`
* `component`
* `event`
* `msg`
* `request_id`
* `tenant_id`
* `node_id`
* `model`
* `error_code`
* `attrs` object

No secrets SHALL be logged.
Prompt/response bodies SHALL only be logged when tenant capture mode = `full`.
Hidden reasoning content SHALL never be logged, traced, attached to metrics, included in crash evidence, or placed in diagnostic payloads, including when capture mode is `full`.

### 9.4 Recommended Grafana dashboards

1. **Cluster Overview**

   * requests/sec
   * p50/p95 latency
   * active requests
   * queue depth
   * error rate

2. **Scheduler**

   * scheduler latency
   * decision tier distribution
   * rejection reasons
   * queue wait by tenant

3. **Nodes & Residency**

   * per-node available memory
   * swap usage
   * active workers
   * loaded models
   * model load time

4. **Tenant Usage**

   * requests/minute
   * input/output tokens per day
   * quota rejection count
   * top models per tenant

5. **Failures**

   * request terminal states
   * worker crashes
   * node unreachable incidents
   * model load failures

---

## 10. Security Model

### 10.1 Authentication

Supported auth types:

* API keys
* service accounts
* node certificates
* bootstrap tokens for initial node join only
* named Console password authentication and revocable Console Sessions as the accepted target in §10.11
* existing Portal password authentication and Portal Sessions, confined to Developer Portal access

### 10.2 API keys

Key format:

```text
orchard_sk_<prefix>_<secret>
```

Requirements:

* `<prefix>` is the canonical unpadded base64url encoding of 12 random bytes and is exactly 16 characters
* `<secret>` is the canonical unpadded base64url encoding of 32 random bytes and is exactly 43 characters
* persisted and displayed `token_prefix = orchard_kp_<prefix>`
* DB stores:

  * `token_prefix`
  * `secret_hash = sha256(<secret>)`, where the hash input is the exact encoded 43-character secret component
* comparison MUST be constant-time
* key secret displayed once only at creation
* revocation is immediate
* plaintext secrets MUST NOT be stored in Postgres, audit logs, provisioning batches, or durable local evidence artifacts

Previously issued `orch_<public>.<secret>` API Tokens SHALL remain valid compatibility credentials.
Compatibility authentication SHALL preserve their existing `orch_<public>` lookup prefix and complete-token SHA-256 semantics without rewriting persisted credentials.

Tenant-direct API Keys SHALL remain supported for manual, bootstrap, compatibility, and Developer Portal paths.
Developer Portal minting SHALL persist `issuance_surface = 'developer_portal'` and the signed-in Portal User's `portal_user_id`.
The portal SHALL enforce at most 10 active portal-minted tenant-direct keys per Portal User, excluding revoked and expired keys.
Portal User ownership SHALL remain minting-gate provenance only.
Public Inference Bearer authentication SHALL continue to resolve `orchard_sk_*` tenant-direct keys as `principal_type = tenant` without consulting `portal_user_id`.
Legacy portal-minted keys with null `portal_user_id` SHALL remain valid Bearer credentials until explicitly revoked and SHALL remain operator-visible only.
Bulk provisioning SHALL create service-account-owned API Tokens by default.
API Tokens owned by the same Service Account SHALL NOT have duplicate active names unless explicit Key Rotation mode creates a replacement and revokes the previous active token or tokens.

### 10.3 Service accounts

Service accounts are non-interactive principals.
Product-facing operator surfaces SHALL label service accounts as API Clients.
Owner Contact, Owner Name, Team, External Reference, Description, Purpose, and metadata MAY describe an API Client.
Owner Contact and Team SHALL NOT authenticate, authorize, own quota, define model access, define routing policy, or create a nested Tenant.
An API Client may be disabled.
API Client Disablement SHALL block all owned API Tokens without mutating each token's revoked state.
They may be:

* tenant-scoped

Keys may belong to:

* a tenant directly
* a service account

### 10.4 Authorization / RBAC

Roles:

* `admin`
* `operator`
* `tenant_admin`
* `inference_client`

Permissions:

* `admin`: full cluster access
* `operator`: runtime operations, diagnostics, request cancel/retry, no tenant/key mutation unless also admin
* `tenant_admin`: tenant-scoped key/quota/model-access management only
* `inference_client`: public inference only

Bulk-provisioned API Clients SHALL receive tenant-scoped `inference_client` access by default.
Public inference requests authenticated by service-account-owned API Tokens SHALL require `inference_client` access for the effective Tenant.
No implicit cross-tenant access.

These role summaries SHALL NOT themselves widen a transport's admission or complete a command-family migration.
For the accepted credential family, §10.11 defines the authoritative action/resource/scope policy, exact-Tenant privilege classification, own-session access, and action-time revalidation.
Non-migrated Console families SHALL permit only action-time cluster-admin authority or fail closed when named Console authentication is activated.

### 10.5 Node trust

Supported join modes:

1. **Bootstrap token**

   * one-time or time-limited token
   * node generates local keypair and CSR
   * controller signs node cert after validation

2. **Certificate mode**

   * pre-issued client certificate
   * controller maps cert identity to node record

### 10.6 Internal transport

Certificate-backed node lifecycle RPC, production first-party BEAM Distribution, and current gRPC compatibility transports SHALL use:

* TLS 1.3
* mutual TLS
* controller CA generated through an explicit node-trust initialization operation or imported by admin
* SAN validation against node id / controller id
* certificate renewal before expiry

Production first-party BEAM Distribution SHALL additionally enforce the BEAM Peer Grant contract in §7.5.0.
Certificate identity alone SHALL NOT authorize a production OTP distribution connection.
Current source-development and packaged first-cut shared-cookie behavior SHALL remain visibly transitional until the enrolled Production BEAM Operating Model passes its required packaged acceptance.

The internal node-trust initialization operation SHALL remain separate from `orchardctl cluster init`, which is credential-only per §11.9.

Node cert lifetime default:

* 90 days

Renewal threshold:

* 30 days before expiry

### 10.7 Public transport

Public API transport SHALL be configured by a first-class transport mode. Valid values are:

* `reverse_proxy` - the controller listens on a local HTTP backend and an operator-managed reverse proxy terminates public HTTPS.
* `direct_https` - the controller terminates HTTPS with operator-provided certificate material or explicit local-CA helper output.
* `plain_http_localhost` - the controller listens on loopback HTTP only for local development or break-glass recovery; this mode is degraded and MUST NOT be treated as production public transport.

Public client traffic SHALL use HTTPS in `reverse_proxy` and `direct_https` modes. Orchard SHALL NOT assume a public certificate provider. Paid CAs, proprietary CAs, internal PKI, and air-gapped certificate distribution all map to `direct_https` with operator-provided certificate material.

Certificate provenance SHALL be modeled separately from transport mode as `cert_source`. Valid values are `operator_provided`, `generated_local_ca`, and `unknown`. Runtime classification SHALL resolve `transport_mode` first, apply `ORCHARD_TRANSPORT_MODE` precedence, and discard legacy TLS environment variables that are inconsistent with the selected mode before resolving `cert_source`. For `reverse_proxy` and `plain_http_localhost`, `cert_source` SHALL be `unknown`. For `direct_https`, runtime SHALL resolve `cert_source` in this order:

1. If both mode-consistent `ORCHARD_TLS_CERTFILE` and `ORCHARD_TLS_KEYFILE` are set, `cert_source` is `operator_provided`. Explicit cert/key overrides win over any local metadata file.
2. Otherwise, if Orchard TLS metadata records `generated_local_ca` and the referenced generated cert/key files exist, `cert_source` is `generated_local_ca`.
3. Otherwise, `cert_source` is `unknown`.

The mapping from operator deployment patterns to runtime state SHALL be:

| Operator deployment pattern | `transport_mode` | `cert_source` |
| --- | --- | --- |
| Reverse proxy TLS termination | `reverse_proxy` | `unknown` |
| Direct HTTPS with operator certificate | `direct_https` | `operator_provided` |
| Paid or proprietary CA | `direct_https` | `operator_provided` |
| Internal PKI or air-gapped HTTPS | `direct_https` | `operator_provided` |
| Explicit Orchard local-CA helper output | `direct_https` | `generated_local_ca` |
| Break-glass local HTTP | `plain_http_localhost` | `unknown` |

`ORCHARD_TRANSPORT_MODE` is authoritative when set. Legacy `ORCHARD_TLS_DISABLED`, `ORCHARD_TLS_CERTFILE`, `ORCHARD_TLS_KEYFILE`, and `ORCHARD_TLS_CACERTFILE` environment variables SHALL remain compatibility shims for one release. When `ORCHARD_TRANSPORT_MODE` is set, legacy variables SHALL be accepted only when consistent with the selected mode; conflicting legacy values SHALL emit a deprecation warning and the new mode SHALL win unless the combination is structurally invalid. When `ORCHARD_TRANSPORT_MODE` is unset, runtime SHALL derive the mode from legacy variables: `ORCHARD_TLS_DISABLED=true` maps to `plain_http_localhost`, cert/key overrides map to `direct_https`, and a fresh install with no TLS envs maps to `plain_http_localhost`. Invalid mode values, partial cert/key overrides, malformed CIDRs, and other structurally invalid combinations SHALL fail closed at wrapper preflight or boot.

`/ca.crt` SHALL publish a CA certificate only when `cert_source` is `generated_local_ca`. It SHALL return not found for `operator_provided` and `unknown`. Orchard SHALL NOT publish an operator CA, internal PKI root, proprietary CA, or public CA bundle unless a future explicit operator-CA publication feature is designed and specified.

Forwarded headers SHALL be trusted only in `reverse_proxy` mode and only from configured trusted proxies. The default trusted proxy set SHALL be loopback only: `127.0.0.1/32` and `::1/128`. Operators MAY configure non-loopback trusted proxy CIDRs with `ORCHARD_TRUSTED_PROXIES`. If reverse-proxy mode binds the backend listener to a non-loopback address without explicit trusted proxies, Orchard SHALL fail closed at preflight or boot. Spoofed `x-forwarded-*` headers from untrusted clients SHALL be ignored or rejected and MUST NOT affect public URL, scheme, host, port, or client IP derivation.

### 10.8 Secrets at rest

Secrets SHALL be stored:

* in Postgres only as hashes, never plaintext
* private keys SHOULD be stored in the distribution profile's approved credential store or protected filesystem paths; macOS Keychain remains the macOS native distribution profile's credential store
* bootstrap tokens stored only as hash
* Portal User passwords stored only as a password hash, never plaintext
* Portal Invite tokens stored only as a hash, with plaintext shown only in the newly issued URL
* Developer Portal session tokens stored only as a hash
* accepted named-Console passwords stored only through a slow password KDF, with Console Session bearers and single-use setup tokens stored only as hashes under §10.11

Portal User password hashing SHALL use a slow password KDF.
It SHALL NOT reuse API key SHA-256 hashing.
Copy invite SHALL mint a fresh token, invalidate prior unused tokens, extend expiry, and SHALL NOT persist the plaintext token or invite URL.

### 10.9 Audit requirements

Audit logs SHALL capture:

* tenant creation/update/suspend
* API key create/revoke
* Portal User invite, invite reissue, invite redemption, and disable
* service account changes
* API Client Disablement
* provisioning batch start/completion/failure
* Access Level assignment
* Key Rotation and token replacement
* quota changes
* model import/activate/retire
* routing policy changes
* node admission/decommission
* Node Admission Candidate rejection
* Node Admission rejection clearance
* node admission after rejection
* registration or trust event used to permit re-admission
* Controller Dispatch Ceiling creation, approval, raising, lowering, and enforcement-state change
* operator drain/cancel/retry actions
* upgrade actions

Every effective Portal User creation, invite issue or reissue, redemption, disablement, Portal-owned API Key mint, and effective revoke SHALL commit its tenant-scoped audit row inside the same outermost `AuditWriter.transaction/1` boundary as the authoritative mutation.
The mutation and audit row SHALL roll back together when audit insertion fails, and no secret-bearing success result SHALL be returned.
Successful audit telemetry SHALL be emitted only after that outer transaction commits.
A direct audit insertion inside an unmanaged transaction SHALL fail before persistence.
A savepoint-rolled-back audit row SHALL NOT publish a queued success observation.
Failure to verify post-commit metric eligibility SHALL mark metrics reporting degraded without altering the already committed domain result or withholding its success value, and a later successful verification MAY recover that degradation.
A rejected request or true no-op SHALL NOT create a success audit row or succeeded audit observation.

Portal User creation SHALL use `portal_user.invited`.
First invite issuance SHALL use `portal_user.invite_issued`, invite replacement SHALL use `portal_user.invite_reissued`, redemption SHALL use `portal_user.invite_redeemed`, and effective disablement SHALL use `portal_user.disabled`.
Portal-owned API Key mint and effective revoke SHALL reuse `api_key.created` and `api_key.revoked`.
Before named Console cutover, Console actions retain the implemented baseline of `actor_type = 'operator'`, null `actor_id`, and `surface = 'console'`.
After cutover, authenticated Console actions SHALL use the actual Console Identity UUID as non-null `actor_id` and typed authentication references under §10.11, including Console-originated Portal administration.
Historical anonymous rows SHALL remain unchanged.
Redemption and Portal-owned key actions SHALL use `actor_type = 'user'`, the Portal User ID as `actor_id`, and `surface = 'developer_portal'` as provenance only.
Portal User actions SHALL target the Portal User, while key actions SHALL target the API Key and set the matching `api_key_id`.

Portal lifecycle audit payloads SHALL use closed per-action allowlists.
Under the accepted target, new Portal lifecycle and self-service rows SHALL select `payload_schema = 'portal_lifecycle.v1'`, while management-family revocation SHALL select `credential_management.v1` under §10.11 even when its target was minted through Portal.
Schema selection SHALL follow the executing operation, not issuance provenance; the following Portal payloads SHALL remain unchanged for Portal lifecycle operations, including named Console-originated Portal administration.
`portal_user.invited`, `portal_user.invite_redeemed`, and `portal_user.disabled` SHALL contain exactly `surface`.
`portal_user.invite_issued` and `portal_user.invite_reissued` SHALL contain exactly `surface` and the committed invite `expires_at`.
Portal-owned `api_key.created` and `api_key.revoked` SHALL contain only `name`, `token_prefix`, `owner_type`, `surface`, `issuance_surface`, `portal_user_id`, and `expires_at` when present.
Audit payloads SHALL exclude plaintext API Token secrets, API Key secret hashes, Portal User email addresses or passwords, Portal Invite tokens, hashes, or URLs, Developer Portal session tokens or hashes, raw request fields, source addresses, raw errors, and `previous_invite_existed`.
Provisioning Batch records SHALL include non-secret counts, status, input hash, timestamps, and sanitized error summaries only.
Observed target references and admission-candidate metadata in audit payloads SHALL be sanitized and MUST NOT include secrets.

### 10.10 Data governance

Tenant setting `request_body_capture_mode`:

* `none`
* `metadata`
* `full`

Default = `metadata`

The capture lattice is `none < metadata < full`.
The effective mode SHALL resolve before the first Request write and SHALL be snapshotted in `requests.payload_capture_mode`.
Later Tenant changes, terminal paths, attempts, automatic retries, and operator retries MUST NOT widen that snapshot.
For the Responses API, `store=false` SHALL cap `full` at `metadata`, SHALL NOT widen a narrower Tenant mode, and SHALL NOT disable required accounting or audit metadata.

`none`:

* store request and response hashes, usage, state, timestamps, and stable error codes
* store no prompt, response, preview, request shape, raw tool argument, raw runtime error text, or other caller or model content

`metadata`:

* additionally store a fixed allowlisted request shape containing counts, types, lengths, approved identifiers, and hashes
* caller metadata values, stop text, tool definitions, tool arguments, rendered prompts, and input content are not shape
* a content preview is optional and SHALL be stored only when its source exceeds 512 Unicode code points
* a metadata preview SHALL contain complete source grapheme clusters totaling at most 511 Unicode code points plus one ellipsis and therefore SHALL NOT equal the complete source

`full`:

* store full payloads and final outputs
* convenience previews remain bounded to 512 Unicode code points without splitting a grapheme cluster
* a streaming Request stores its assembled final output only at terminal completion and does not durably duplicate individual chunks

Reasoning retention SHALL follow projection rather than generation alone.
Reasoning hidden by `projection = final_only` is ephemeral under `none`, `metadata`, and `full`.
Hidden reasoning MUST NOT enter `canonical_request` content, `request_payload`, `response_payload`, `request_events`, `response_preview`, scheduler metadata, logs, traces, metrics, audit payloads, crash evidence, or diagnostics.
The canonical Request MAY retain only the closed non-content reasoning policy, provenance, contract identifiers, and exact or unknown usage detail allowed by its effective capture mode.
If a later accepted contract enables public `reasoning_structured`, `full` SHALL retain that selected public reasoning in the exact assembled response payload needed for idempotent replay, while `none` and `metadata` SHALL retain no reasoning content.
For `projection = final_only`, `response_preview` SHALL derive only from final-answer text.
If a later accepted contract enables `projection = reasoning_structured`, its preview SHALL also derive only from final-answer text and MUST NOT contain selected public reasoning.
For omitted `projection = legacy_blended`, `response_preview` SHALL preserve the existing derivation from undifferentiated public assistant text without parsing, stripping, or reclassification.
`response_hash` SHALL hash the exact assembled public terminal response after projection and SHALL be independent of SSE framing and chunk boundaries.
Idempotent replay SHALL return the retained historical public response payload exactly and MUST NOT rerender, reparse, reproject, or recover hidden reasoning.
Existing Request rows SHALL NOT be reclassified by delimiter matching, parser heuristics, or model-family inference.

Capture enforcement SHALL cover every content-bearing field on `requests` and `request_events`, including canonical input, request payloads, response payloads, previews, sampling stop text, response-format content, scheduler decisions, error text, model-generated tool arguments, and request-step results.
Non-`full` Request-event and scheduler metadata SHALL use field-specific type checks and closed operational vocabularies rather than key-only allowlists.
Non-`full` scheduler metadata MAY retain the opaque `hmac-sha256:<64 lowercase hex>` cache-affinity key and its closed typed operational fields because the scheduler requires that non-recoverable feedback for later placement.
Untrusted tool-call identifiers retained for request-step correlation SHALL be replaced with deterministic hashes, and model-generated tool names and raw target references SHALL NOT persist outside `full`.
`body_hash` and `response_hash` are integrity anchors and do not authorize content recovery or replay.
Idempotent replay requires a retained `response_payload`; otherwise Orchard SHALL return `idempotency_not_replayable`.
Existing `none` and `metadata` rows that contain forbidden content SHALL be purged in place rather than relabeled as `full`.
When legacy nested event or scheduler values cannot be proven safe by the migration, Orchard SHALL discard the entire nested payload rather than copy key-allowlisted values forward; the migration MAY retain only a syntactically valid cache-affinity HMAC and its closed typed operational fields.
The purge verification SHALL explicitly enumerate every content-bearing Request column and `request_events.payload`, and schema-drift coverage SHALL fail when a new text, JSON, or binary Request column is not classified.

---

### 10.11 Named Console and shared management authorization target

This section accepts the policy decisions in [ADR 0033](docs/decisions/0033-cross-surface-authorization.md).
The linked OpenSpec requirements below are the accepted detailed contracts for operation carriers, request/result envelopes, revisions, closed audit schemas, and acceptance scenarios.
They remain binding implementation requirements under this section; `SPEC.md` prevails in any conflict.
Their precise requirement links SHALL be updated if the change package is subsequently archived or synced.
Acceptance settles the target design only: named authentication, the shared operation implementation, schema migrations, cutover, and the first COMPLETE family remain pending.
The current shared Basic Auth/anonymous audit/local CLI baseline is temporary and SHALL NOT be presented as satisfying this target.

#### 10.11.1 Principals, sessions, and setup

Principal, credential, session, grant, action, resource, scope, and audit actor SHALL remain distinct concepts.
A Console Identity SHALL be a named human principal with a stable UUID, unique normalized login name, `pending_setup`, `enabled`, or `disabled` state, a password verifier after setup, and an authentication epoch.
Typed RoleBindings SHALL admit `console_identity` subjects while preserving existing Tenant, API Client (`service_account`), and API Key subjects.
Identity names, API Client Owner Contact, Team, and other descriptive metadata SHALL NOT establish authority or merge identities.
An API Client SHALL remain non-interactive; Portal identities/sessions, Public Inference principals, Node certificates, node-join Bootstrap Tokens, Peer Grants, and host-local authority SHALL retain their separate audiences.
Console SHALL NOT mint or retain an administrator API Token to act on a named user's behalf.

Local password login SHALL use a slow password KDF, generic rate-limited failures, effective HTTPS under the trusted-proxy contract, CSRF protection for browser writes, and validated LiveView origins.
Successful login SHALL mint a fresh independent opaque bearer, persist only its hash in a server-side Console Session, and rotate a distinct Secure, HttpOnly, SameSite=Lax cookie.
A Console Session SHALL bind one identity and its authentication epoch with creation/activity timestamps, expiry, and revocation state.
Using server time, it SHALL expire when `now >= min(created_at + 12 hours, last_activity_at + 30 minutes)`.
Only successful authorized client operations in an explicit server-owned activity class, including explicit list, inspect, and revoke preview, MAY advance activity monotonically while authority is still valid.
Background polling, heartbeats, subscriptions, asynchronous delivery, denied checks, and completion after expiry SHALL NOT revive or extend authority.
This bookkeeping is the sole preview side-effect exception and SHALL NOT be claimed as evidence of human presence.
An agent using a browser session has that session's authority; hidden controls, tool allowlists, and agent labels SHALL NOT be treated as authorization restrictions.
Identity disablement SHALL invalidate all sessions and outstanding setup invitations; session revocation/logout SHALL end only its target session.
Password reset, identity reenablement, SSO, fine-grained delegated agents, and WebMCP implementation remain deferred.

Identity provisioning SHALL execute through active-Controller-owned operations.
After cutover in `named_active`, a named cluster-admin Console Session SHALL invoke the same creation, inspection, invitation, and disable operations under its own authority without acquiring an API Token.
Admin API transport SHALL require a currently enabled cluster-admin API Client before or after cutover and SHALL NOT admit a Console cookie.
The first identity SHALL explicitly request cluster `admin` without an implicit default; subsequent initial assignments SHALL be cluster `admin`/`operator` without Tenant scope or `tenant_admin` within one exact existing Tenant, and scoped/operator provisioning SHALL require an already enabled named cluster admin.
Creation SHALL atomically persist the pending identity, explicit initial grant, and audit without enabling Console authority until redemption.
Setup SHALL activate only pending identities through a bounded, single-use, hash-only invitation delivered over protected HTTPS outside legacy Basic Auth.
Setup material SHALL NOT enter HTTP paths/query strings, logs, or durable plaintext storage, and retries SHALL NOT recover plaintext.
There SHALL be no public signup, Basic Auth identity conversion, environment-seeded named administrator, or new unauthenticated authority-minting endpoint.
Lost administrator authority SHALL first use the existing protected local machine-credential recovery contract; named provisioning SHALL then use ordinary authenticated Admin APIs without impersonating a human or introducing a local identity-setup/grant bypass.
[Named setup has authenticated carriers and bounded recovery](openspec/changes/cross-surface-authorization-contract/specs/management-authorization/spec.md#requirement-named-setup-has-authenticated-carriers-and-bounded-recovery) SHALL govern the exact setup/provisioning routes, initial-grant matrix, request/result envelopes, revisions, idempotency, invitation lifetime/bindings, replacement, one-time delivery, redemption, disablement, and recovery sequence.

#### 10.11.2 Action-time authority and the first complete family

Each migrated Console/API/CLI adapter SHALL construct trusted caller context from its own supported authentication mechanism and invoke one Controller-owned action/resource/scope policy and domain operation boundary.
Unknown actions, missing grants, stale credentials/sessions, disabled principals, epoch mismatch, and scope mismatch SHALL deny by default.
Admission at an HTTP plug, page, socket, tool, or command SHALL NOT authorize a later operation; every protected read, preview, mutation, and data delivery SHALL resolve current authority.
The active Controller and authoritative Postgres SHALL be required for family reads, previews, and writes; Standby or unavailable authority SHALL return stable refusal without cached success or local Repo fallback.
Normal API transport admission SHALL remain API Client-only under §§7.3 and 7.4, even when Console permits narrower named-human authority.

Authority-changing writers and protected operations SHALL share transaction-scoped fences in deterministic typed-principal UUID order, followed by credential/session and resource rows in deterministic typed-ID order.
Fences SHALL exist independently of grant rows, protect insertion of absent grants, deduplicate actor/target identity, and cover every affected principal in batch mutations before any change.
After acquiring fences, operations SHALL reread actor validity, principal state, epoch, grants, target ownership, and privilege classification before authorization.
The writer closure SHALL include Console/API/CLI revoke, Portal self-service and Portal session/logout/epoch paths, Console identity/session/setup lifecycle, API Client disablement, grant changes, bulk provisioning/rotation, and every retained local recovery or direct-database CLI entry point.
Larger families MAY remain unmigrated, but their authority-changing writes SHALL NOT bypass these fences or the applicable atomic audit contract.
If a restrictive authority change commits first, the operation SHALL fail from current authority; if the operation commits first, later revocation SHALL NOT undo that effect.
Protected reads SHALL linearize at admission to the server transmission queue under current authority, not at earlier database fetch; stale fetched data SHALL be revalidated before admission, while already admitted bytes cannot be recalled.
One bounded acknowledgement of an already committed mutation, including self-revocation, MAY be delivered under that transaction's authorization without becoming a fresh protected read.
Already admitted Public Inference work SHALL retain its existing lifecycle; credential revocation blocks subsequent authentication and SHALL NOT silently cancel in-flight inference.

The first family SHALL provide metadata list, inspect, revoke preview, and revoke for exactly `api_key`, `api_token`, and `console_session`.
Cluster admins SHALL manage every target; an exact-Tenant Console `tenant_admin` SHALL manage only that Tenant's wholly inference-only API credentials.
For tenant-direct keys, classification SHALL examine the union of Tenant-principal and key-specific grants; for API Tokens, it SHALL examine API Client-principal and key-specific grants.
Every retained grant in that union SHALL be `inference_client` within the same authoritative Tenant for Tenant-admin eligibility; zero grants remain eligible when ownership matches.
Cluster, foreign-Tenant, or non-inference grants SHALL exclude the target even when the owner is disabled or the credential is expired/revoked.
Multiple Tenant-admin grants SHALL NOT combine into permission over a privileged or cross-Tenant target.
`operator` alone SHALL convey no API-credential management permission; every valid Console Identity MAY inspect/revoke its own sessions, and only cluster admins MAY manage another identity's sessions.
Missing, out-of-scope, or wrong supported-kind targets SHALL yield indistinguishable `not_found` before revision comparison; lists SHALL filter before pagination without leaking excluded counts or records.
Credential creation/rotation, API Client disablement, general grant editing, and other management families remain separately contracted work; existing Portal self-service SHALL retain its narrower operation while joining shared serialization.

Every credential-family surface and retained alias SHALL delegate to the same authoritative operation or be removed; standalone management-revoke and local Repo fallback SHALL NOT survive migration.
Inspection SHALL expose only bounded non-secret metadata and SHALL NOT disclose reusable secrets, verifiers, cookies, raw request metadata, or secret-bearing errors.
Preview SHALL identify the exact target, revision, consequences, and confirmation requirements without domain mutation or successful mutation audit.
Execution SHALL freshly authorize the caller and target and require current revision preconditions, an explicit reason and confirmation, and acknowledgement when revoking the caller's own credential/session.
Authorized already-revoked retries SHALL be true no-ops that waive only revision equality, never required request shape, confirmation, reason, acknowledgement, authentication, or scope.
Effective revocation and audit SHALL commit atomically once; audit failure SHALL preserve prior lifecycle state, and a lost response SHALL remain an unknown client outcome until authorized inspection or retry resolves it.
[Complete credential inspection and revocation surfaces](openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-complete-credential-inspection-and-revocation-surfaces) SHALL govern exact routes, portable commands, existing delegates, and aliases.
[Inspection exposes bounded metadata only](openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-inspection-exposes-bounded-metadata-only) SHALL govern the closed projection, filters, pagination, cursor binding, and no-store responses.
[Credential carriers preserve exact request and result contracts](openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-credential-carriers-preserve-exact-request-and-result-contracts) SHALL govern request/result envelopes, CLI flags, protected credential files, and TLS/redirect policy.
[Revocation requires current preview preconditions and explicit acknowledgement](openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-revocation-requires-current-preview-preconditions-and-explicit-acknowledgement) SHALL govern revision inputs and equality across target states, confirmation/reason constraints, self-revocation, and retry mechanics.
[Family leadership failures and audit are coherent](openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-family-leadership-failures-and-audit-are-coherent) SHALL govern refusal mappings, atomic rollback, and lost-response handling.

#### 10.11.3 Accountable audit and retained references

Authenticated management actions SHALL record the actual stable principal and separate non-secret authenticating-record attribution, preserving `actor_type = 'operator'` for Console and API Client management actors.
The target `api_key_id` SHALL identify the affected key rather than the caller's credential; session targets SHALL leave it null.
API Key and API Token revocation SHALL preserve the established `api_key.revoked` action, `api_key` target type, and existing key target reference.
Closed audit schemas SHALL be selected by the executing operation, not credential issuance provenance; Portal lifecycle/self-service SHALL preserve §10.9's payloads and Portal User actor without acquiring management authority.
Session events and privileged API credentials SHALL use cluster audit scope with null Tenant; wholly inference-only API credentials within one Tenant SHALL use that exact Tenant scope under the same conservative grant classification as authorization.
Historical null discriminators SHALL retain legacy decoding without inferred identities; cleanup SHALL preserve all recorded actor/authentication/target identifiers under §8.
Local recovery SHALL retain its separate actor contract without inventing a human UUID.
Every effective mutation and its required audit SHALL commit atomically with explicit action-domain telemetry mappings; successful telemetry SHALL occur only after commit, and no-op, denied, or preview outcomes SHALL NOT fabricate successful mutation audit.
[Named audit attribution preserves historical evidence and closed schemas](openspec/changes/cross-surface-authorization-contract/specs/management-authorization/spec.md#requirement-named-audit-attribution-preserves-historical-evidence-and-closed-schemas) SHALL govern typed actor/authentication fields and the exact identity, session, and policy lifecycle action/schema/payload mappings, including audit-before-cookie and audit-before-access publication.
[Family leadership failures and audit are coherent](openspec/changes/cross-surface-authorization-contract/specs/credential-management/spec.md#requirement-family-leadership-failures-and-audit-are-coherent) SHALL govern the exact credential-management schemas, payloads, scope, target references, and server-known surface provenance.
[Portal Lifecycle Mutations Produce Atomic Tenant Audit Evidence](openspec/changes/cross-surface-authorization-contract/specs/developer-api-key-portal/spec.md#requirement-portal-lifecycle-mutations-produce-atomic-tenant-audit-evidence) and [Portal Audit Payloads Are Bounded And Secret-Free](openspec/changes/cross-surface-authorization-contract/specs/developer-api-key-portal/spec.md#requirement-portal-audit-payloads-are-bounded-and-secret-free) SHALL govern operation-selected Portal lifecycle schemas and their unchanged closed payloads.

#### 10.11.4 Cutover, rollback, and completion

Named Console authority SHALL use a durable singleton with `pre_cutover`, `named_active`, or `rollback_console_disabled` state and a required Console-auth contract version covering action policy, session validity, every credential/grant writer, authority fences, and audit semantics.
Activation SHALL require the acting named cluster admin's currently valid, unexpired, unrevoked Console Session, enabled identity, current epoch and grant, plus fresh compatible evidence for every non-retired eligible Controller, including Standby and disconnected instances that may return.
Historical login or stale Controller evidence SHALL NOT suffice; missing compatibility evidence SHALL block until refreshed or the instance is explicitly retired and isolated.
Persistent host/service launch gates, ingress fencing, and authority-database access isolation SHALL prevent incompatible writers from running against the live post-cutover store, including retained direct-database CLI writers.
Ingress gates SHALL cover direct backend HTTP listeners and actual Console LiveView handshake/transport, close existing sockets, and block the affected listener when safe separation is impossible.
At activation, legacy browser markers SHALL be invalidated and shared Basic Auth or production `auth: :none` SHALL no longer authorize Console; no automatic downgrade or parallel fallback is permitted.
Every non-migrated protected Console route, event, parameter, asynchronous result, subscription, and data-delivery path SHALL enforce a fresh cluster-admin guard or fail closed before scoped named sessions gain access.

Restricted pre-cutover named login/logout SHALL exist outside Basic Auth for preparation only under [Named Console sessions are revocable authentication results](openspec/changes/cross-surface-authorization-contract/specs/management-authorization/spec.md#requirement-named-console-sessions-are-revocable-authentication-results).
Activation and restoration SHALL be same-origin HTTPS operations outside Basic Auth without general LiveView transport, using the acting current named cluster-admin session with CSRF, explicit preview, state/version preconditions, and typed confirmation.
API Bearers, supplied session UUIDs, and historical login evidence SHALL NOT substitute for the acting current Console Session.
[Policy preparation has explicit named-session carriers](openspec/changes/cross-surface-authorization-contract/specs/management-authorization/spec.md#requirement-policy-preparation-has-explicit-named-session-carriers) SHALL govern exact activation/restoration routes, request/result fields, required state/version handling, and confirmation literals.
Before any pre-cutover binary starts, rollback SHALL close Console HTTP/LiveView, terminate sockets, persist Console-disabled launch configuration, and isolate incompatible API/CLI/Portal/database writers from the live authority store.
An older binary cannot enforce a new database marker; Console disablement alone is insufficient, and a downgrade profile without verifiable writer isolation SHALL be unsupported.
After compatible software and host/service/database/ingress proof are restored, only restricted setup, named login/logout, and restoration preview/confirmation MAY reopen, permitting fresh setup/login when no valid session survives.
Provisioning in that recovery state SHALL still require authenticated Admin API authority, and local recovery SHALL only recover the machine credential.
Restoration SHALL revalidate the acting named admin's current session, epoch, and grant and atomically commit policy state plus `console_auth.access_restored` before general access opens.
Failed verification, audit, or enablement SHALL keep general Console and LiveView closed across restart/failover; software rollback SHALL NOT erase durable cutover state or retain the COMPLETE claim in an isolated historical environment.

Only reviewed implementation evidence for admitted-authority parity across Console/API/portable CLI, failure and concurrency behavior, coverage, live transport fencing, compatible writers, and closure of every alternate family path SHALL permit the credential family to be marked COMPLETE.
OpenSpec structural validation and acceptance of this contract SHALL NOT satisfy that gate.
Other command families and Tenant-admin machine/API/CLI admission SHALL remain explicitly deferred.

---

## 11. Packaging and Deployment

Distribution requirements are scoped by distribution profile.
DMG, Orchard.app, launchd, Keychain, Apple signing, notarization, and stapling requirements in this section SHALL remain mandatory for the macOS native distribution profile and MUST NOT be imposed on portable Orchard control-plane core validation or the Linux Controller profile.
Generic Product Version, provenance, trust, secret-free artifact, role, rollback, retained-state, and protocol compatibility requirements remain shared where applicable.

The accepted Linux Controller profile uses operator-provided external Postgres and contains only portable applications and assets compatible with that profile.
Its final distribution format, host manager, paths, service integration, and publication contract remain deferred to a separate change.
No Linux distribution is supported by this contract-only amendment.

The macOS native distribution profile SHALL use a signed and notarized **DMG** containing `Orchard.app` for interactive installation and the app-owned root-authorized service lifecycle.
The initial source-availability transition SHALL be source-only under the Apache License, Version 2.0, for covered Orchard-authored software and technical documentation, with Copyright 2026 AI Singapore.
Third-party software, models, tokenizers, assets, and other separately licensed material SHALL be excluded from that grant and remain subject to their own terms and notices.
Orchard logos and distinctive brand assets, including tracked assets under `apps/orchard_controller/priv/static/images/` and `assets/brand/`, are excluded from that grant, and trademark rights are not granted.
Source visibility alone SHALL NOT grant rights beyond the applicable license terms.
Source availability SHALL NOT be represented as public binary availability or support, and initial source publication provides no official binary, supported release, SLA, or maintenance commitment.
A supported public binary requires an explicit release decision plus every applicable build, verification, signing, notarization, stapling, and publication gate.
Native PKG distribution is not a supported current Orchard distribution channel.
Legacy PKG receipt detection SHALL be retained solely to prevent silent app ownership takeover of an existing installation, as required by §11.4, and does not define a supported distribution channel, a release artifact, or a validation gate.
Any future native package or additional distribution channel SHALL require a fresh accepted OpenSpec proposal and a separate implementing pull request that updates this contract, security posture, operator documentation, and validation gates before support is claimed.

Apple recommends notarization for directly distributed macOS software, and a signed DMG is a preferred direct-distribution format outside the App Store. ([Apple Developer][8])

### 11.1 Installed components

Required installed artifacts:

```text
/Applications/Orchard.app                    # app-owned install and tray surface
/usr/local/bin/orchardctl                           # CLI
/Library/Application Support/Orchard/
  config/
  data/
  models/
  bundles/
  logs/
  support/
/Library/LaunchDaemons/com.orchard.controller.plist
/Library/LaunchDaemons/com.orchard.node-agent.plist
/Library/LaunchDaemons/com.orchard.postgres.plist   # managed DB mode only
/Library/LaunchAgents/com.orchard.tray.plist
```

### 11.2 launchd services

System daemons:

* `com.orchard.controller`
* `com.orchard.node-agent`
* `com.orchard.postgres` (optional)

User agent:

* `com.orchard.tray`

Apple documents launchd as the daemon/agent manager on macOS, and distinguishes user agents from daemons. ([Apple Support][2])

Required launchd properties:

* `RunAtLoad = true`
* `KeepAlive = true`
* stdout/stderr redirected to product log path
* restart throttling enabled
* dedicated non-root service user preferred


### 11.3 DMG And Release Distribution Contents

DMG SHALL include `Orchard.app` as the primary interactive install artifact.
It SHALL NOT include or require a native PKG artifact under the current distribution contract.

The release distribution set SHALL place release notes, a DMG SHA-256 checksum, and the before/after app-signing manifests alongside the DMG.
These sidecars remain outside the DMG because Amore owns final image assembly and notarization, and changing the image afterward would invalidate that outer trust boundary.

The app bundle SHALL be verified before DMG assembly.
The mounted DMG SHALL be verified after assembly, and nested code signatures and entitlement digests SHALL match the verified input app.
An outer distribution tool that changes nested code or entitlements SHALL cause the release handoff to fail closed.
Amore SHALL be the current outer DMG assembly, notarization, stapling, hosting, and publication integration.
Orchard SHALL feature-detect the required Amore CLI surface and SHALL keep nested signing and verification under Orchard control.

### 11.4 Root-Authorized App Service Lifecycle

`Orchard.app` SHALL own a service lifecycle interface for role-aware install, update, uninstall, and status operations.
System-root install, update, and uninstall operations SHALL require effective root privileges with effective user id 0.
Validation against a non-system root SHALL relocate every installed path and SHALL simulate launchd effects without mutating the host installation.

App-owned install and update SHALL preflight the payload and target before stopping services.
If a failure occurs after any app-owned install, update, or uninstall mutation begins, Orchard.app SHALL attempt a complete rollback before returning failure.
Complete app rollback SHALL restore the prior app-owned payload, command links, launchd plists, role marker, and prior loaded-service state, and SHALL report whether rollback completed successfully.
If required rollback cannot be completed or verified, the app lifecycle SHALL classify the installed state as uncertain, SHALL fail closed for the affected lifecycle role, and SHALL NOT start the Node Agent.

The current contract does not define Managed Node Agent Handover, a zero-overlap replacement protocol, shared lifecycle exclusion, durable start-eligibility state, one-shot launch authorization, or provisional child acceptance.
Controller and Node Agent version compatibility does not imply that concurrent processes may safely share one Node Identity Root.
A future managed replacement or cross-installer handover protocol SHALL require a fresh accepted OpenSpec proposal and a separate implementing pull request before it becomes supported behavior.

The BEAM Peer Grant Store Lock is the operation-scoped lock used by `Orchard.Node.BeamPeerGrantStore` to serialize one grant store install or load operation, including atomic publication when installing in the owner-only Node Identity Root.
It SHALL end with that store operation and SHALL NOT become a process-lifetime Node Identity Root Lease.
Install and update SHALL preserve operator-owned `config`, `data`, `models`, `bundles`, `logs`, and non-app-owned contents under the retained `support/` namespace.
Default uninstall SHALL remove app-owned payloads, installed commands and links, launchd plists, install markers, and app-owned support entries while retaining those operator-owned contents.
Destructive purge behavior is not part of the v1 app lifecycle contract.
The app lifecycle SHALL preserve complete existing TLS state, SHALL reject partial TLS state before mutation, SHALL NOT generate or trust production TLS material, and SHALL NOT mutate system trust stores.
The app lifecycle SHALL refuse system-root install, update, and uninstall while a `com.orchard.pkg` receipt exists, SHALL fail closed before any mutation, and SHALL report that blocking receipt in non-mutating lifecycle status.
That refusal prevents silent app ownership takeover of a legacy installation; it does not make native PKG a supported distribution channel, release artifact, operator workflow, or validation gate.
Orchard SHALL sign nested Mach-O libraries and executables with their required entitlements before signing app helpers, the main app executable, and the outer app bundle.
Orchard SHALL verify the nested payload and final app bundle before handing the app to the DMG distribution layer.

`Orchard.app` and its DMG distribution SHALL remain generic and SHALL NOT embed customer identifiers, database DSNs, production TLS material, deployment secrets, or product-license activation state.

### 11.5 Managed Database Mode

Managed Database Mode in this section is a macOS native distribution profile capability.
It is not part of the first Linux Controller profile.

Managed DB mode SHALL:

* run Postgres in a local container runtime on Apple Silicon
* bind only to loopback
* persist data under application support path
* expose health via `pg_isready`
* start before controller ready-state

Implementation choice:

* use Apple Containerization-based runtime, with the open-source `container` implementation acceptable as the packaged runtime interface

Apple’s Containerization project is a Swift package for Linux containers on macOS using Apple Silicon virtualization, and `container` is its CLI implementation. ([Apple Open Source][9])

### 11.6 External Database Mode

External Database Mode is the required database mode for the accepted Linux Controller profile and remains supported for the macOS native distribution profile.

External DB mode SHALL support:

* PostgreSQL 16+
* TLS connections
* verify-full mode by default
* separate DSN for migrations optional
* configurable pool sizes
* no local Postgres helper service

### 11.7 Offline / air-gapped support

Air-gapped install SHALL support:

* offline DMG transfer
* offline model bundle import
* no required network egress
* manual app update media
* prepackaged container image tar for managed Postgres mode

Offline install flow:

1. transfer the signed DMG distribution set and model bundles
2. verify transferred model media against detached evidence obtained through an independently trusted channel
3. install `Orchard.app` and run its root-authorized lifecycle for the selected role
4. run `orchardctl cluster init`
5. import model bundles from removable media
6. recompute each final stored Artifact Bundle digest and compare it with the authoritative Catalog value or a trusted external export
7. bootstrap/join nodes via offline-generated token or imported certs

Top-level Model Manifest `sha256` SHALL NOT be used for either verification checkpoint.
Pre-import media evidence and the final post-import Artifact Bundle digest may differ when import rewrites `manifest.json`.

### 11.8 Tray/menu bar app

The Tray/Menu Bar App is a macOS native distribution profile component.
The first Linux Controller profile is headless and does not require a desktop equivalent.

Tray app SHALL provide:

* local daemon status
* controller/node role display
* node join status
* recent errors
* open logs
* version/build info

### 11.9 CLI

The target portable CLI SHALL own argument parsing, client authentication, confirmation presentation, and output formatting.
Normal Controller-state operations SHALL execute inside the active Controller through authenticated, authorized, leader-aware, and audited Controller-owned domain operations shared with Console clients.
The portable CLI MUST NOT require direct Ecto Repo access, Controller application modules, launchd, Darwin native helpers, or local Controller release evaluation for normal operator operations after their command-family migrations are accepted.

Host-local service management, process fencing, environment materialization, local trust-store mutation, terminal custody, and support collection SHALL belong to platform host tooling.
Mixed commands SHALL separate Controller-owned and host-local operations.
A narrow locally authenticated Controller bootstrap or recovery channel MAY remain only for operations that cannot yet use ordinary administrator credentials, and it SHALL invoke the same Controller-owned domain operations rather than become a general direct-Repo fallback.

The existing local Controller-runtime CLI authority below remains the implemented migration baseline.
It SHALL be replaced command family by command family only through separately reviewed security-led changes with explicit authentication, authorization, audit, leader, idempotency, confirmation, secret-output, and degraded-Controller contracts.
The accepted first family in §10.11 covers credential list, inspect, revoke preview, and revoke, but remains unimplemented and MUST NOT be marked COMPLETE until its implementation and closure gates pass.
That family SHALL use portable `orchardctl credentials list`, `credentials inspect <kind> <id>`, and `credentials revoke <kind> <id>` commands with an explicit HTTPS Controller and protected API Token file.
The existing `orchardctl api-keys revoke` alias SHALL delegate through that same authenticated family, resolving persisted credential kind on the server without a local Repo fallback.
Named Console setup from the CLI or recovery path SHALL use authenticated Admin APIs after obtaining ordinary administrator API authority; existing `cluster init --force-new-admin --yes --output <path>` recovery SHALL remain bounded to machine-credential recovery and SHALL NOT become a local identity-provisioning bypass.

Required commands:

* `orchardctl cluster init`
* `orchardctl node join`
* `orchardctl nodes list`
* `orchardctl nodes inspect`
* `orchardctl nodes pending`
* `orchardctl nodes admit`
* `orchardctl nodes reject`
* `orchardctl nodes cordon`
* `orchardctl nodes uncordon`
* `orchardctl nodes drain`
* `orchardctl nodes maintenance`
* `orchardctl nodes resume`
* `orchardctl nodes decommission`
* `orchardctl api-clients bulk-provision`
* `orchardctl models import`
* `orchardctl requests inspect`
* `orchardctl upgrade plan`

Node-admission CLI commands SHALL provide stable human and JSON output for list, inspect, pending-review, admit, and reject workflows.
`orchardctl nodes admit` and `orchardctl nodes reject` SHALL support side-effect-free `--dry-run` Action Preview output and explicit execution gates, including `--yes` for execution and `--reason` for rejection.
`orchardctl nodes admit` SHALL accept optional `--controller-dispatch-ceiling <non-negative-integer>` and required `--capacity-policy-reason <non-empty-text>`.
When the ceiling flag is omitted, the CLI SHALL preview and persist the explicit new-admission default `1`; its human and JSON previews SHALL include the resolved ceiling, durable enforcement phase, phase-derived policy state, blockers, warnings, consequences, and confirmation requirements.
CLI admission execution SHALL record actor type `operator` with bounded local Controller-runtime principal provenance and SHALL use the same leader-only atomic Node Admission, policy, admission-decision, and cluster-audit transaction as the Admin API.
For source-dev and packaged local use, node-admission CLI commands are local operator/admin commands that execute in the controller runtime context rather than proving Admin API bearer-token authorization.
They SHALL still enforce the same leader-only write-path, admission, confirmation, cluster-scoped audit, and shared-presenter semantics as the Admin API.

Node lifecycle CLI commands SHALL provide side-effect-free `--dry-run` Action Preview output in stable human and JSON forms.
Lifecycle execution SHALL enforce the preview's confirmation requirements, including `--yes`, consequence acknowledgement for drain and decommission, and a typed node id for decommission.
Node lifecycle CLI commands use the same local controller-runtime authority boundary as node-admission CLI commands and SHALL enforce the same leader-only write-path, mutation-time revalidation, cluster-scoped audit, and shared-presenter semantics.
Manual `draining -> maintenance` execution SHALL remain blocked with a `drain_completion_unverified` blocker until drain completion can be verified.

`orchardctl cluster init` SHALL mint the first cluster-admin credential as a local, one-shot, audited controller-host operation.
It SHALL create a service-account-owned API Client holding a cluster-scoped `admin` RoleBinding and an API Token whose secret is intentionally published exactly once through a required operator-chosen `--output` path with preflight, persisting only the token hash and prefix.
The command SHALL follow the cluster-init-only protected file-backed One-time Secret Output profile defined in this section, which does not modify the bulk-provisioning contract in §7.4.4 or the `OrchardCLI.ExclusiveOutput` contract.
This profile SHALL create its credential-bearing inode only inside an owner-only staging namespace that is mode `0700` before the inode exists.
The staged inode SHALL be ACL-free, mode `0600`, and identity-verified before plaintext is written.
The command SHALL write and sync the complete payload through a descriptor bound to that inode, close the publication descriptor, install the inode at the operator-selected path without clobbering an existing entry, verify the final identity and protection, sync the containing directory, remove the staging link, and sync the containing directory again before confirming publication.
A successful publication under this profile SHALL leave the operator-selected path as the only intentional plaintext pathname created by that operation.
This exactly-once guarantee does not assert that a failed operation had no filesystem side effects.
Metadata cleanup under this profile SHALL move a candidate into a unique quarantine pathname and verify its identity after that move before deletion.
A discrete foreign or replaced entry discovered after quarantine SHALL be restored without clobbering when safe or retained in quarantine, and the command SHALL return nonzero rather than delete it.
Cleanup of a staging namespace that could not be protected SHALL revalidate the bound parent hierarchy, match the created namespace by identity, remove only a matching empty directory non-recursively, and retain any identity mismatch or non-empty entry.
The command SHALL report restored and retained cleanup outcomes distinctly, and SHALL keep qualified quarantine pathnames out of machine-readable cleanup categories and persisted audit evidence.
The supported pathname APIs do not provide atomic inode-conditional deletion against a continuously adversarial process running as root or the same operating-system account; that actor is outside this bounded cleanup guarantee.
Credential-authority commit, output publication, and logical containment are independent outcome axes for this profile.
After credential-authority commit, unconfirmed publication or unresolved containment SHALL return nonzero, state that plaintext may remain, and expose only the affected API Token prefix plus secret-free recovery guidance.
Logical containment is best effort through the bound inode descriptor and does not claim physical-media sanitization or guaranteed byte erasure when the filesystem refuses truncation, sync, close, link, rename, or unlink operations.
Credential issuance commits independently of filesystem publication and the issued credential remains active if a post-commit publication or containment step fails.
JSON contract `orchard.cluster_management.cluster_init.v2` SHALL report `credential_authority`, `publication`, and `containment` independently.
Confirmed publication SHALL return success only after file sync, no-clobber final-path installation, final identity and mode verification, staging-link removal, and both containing-directory syncs.
A cleanup-descriptor close anomaly after confirmed publication SHALL remain success with a warning.
Unconfirmed publication or unresolved containment after credential commit SHALL return nonzero, state that plaintext may remain, omit plaintext and secret-bearing identifiers from diagnostics and audit records, identify the credential only by its API Token prefix, and provide revocation and recovery guidance.
The command SHALL distinguish confirmed logical containment from unresolved containment and SHALL NOT claim rollback, absence of all filesystem side effects, or physical-storage sanitization.
It SHALL refuse with a stable `cluster_already_initialized` error when an enabled cluster-scoped `admin` RoleBinding already exists.
An explicit `--force-new-admin` recovery flag SHALL mint an additional admin credential without resetting, deleting, or mutating existing credentials, and SHALL require confirmation and record a cluster-scoped audit event.
`orchardctl cluster init` uses the same local controller-runtime authority boundary and leader-only write-path gate as node-admission CLI commands.
First-admin provisioning is a local controller-host CLI operation, not an Admin API endpoint; Bootstrap Tokens remain scoped to node join only per §10.1.
`orchardctl cluster init` is credential-only: TLS material remains provisioned separately per §11.4, and the app-owned install lifecycle SHALL NOT seed admin credentials.
Successful initialization output SHOULD direct operators to provision named admin API Clients and then revoke the bootstrap credential.

`orchardctl requests inspect` SHALL render a request's persisted scheduler explanation through the shared scheduler explanation reason-code contract in stable human and JSON forms.
Broader request execution diagnostics beyond persisted scheduler explanations remain future work.

---

## 12. Failure Handling

### 12.1 Node failure

Detection:

* no heartbeat > 15s -> `unreachable`

Behavior:

* scheduler immediately excludes node
* after Output Commitment, an affected Request terminalizes as `failed` through the stable Node-loss mapping and SHALL NOT use Automatic Attempt Retry
* before Output Commitment, the Controller applies the closed execution-resolution, capacity-release, identity, deadline, caller, and failure-taxonomy gates and retries at most once only when every gate passes
* controller or process failure after dispatch remains the sole owner of Request state `interrupted` under §3.6
* node remains in lifecycle state but health becomes `unreachable`

Recovery:

* on heartbeat resumption, health recalculated
* loaded placements may be reused after state refresh
* a new accepted background Runtime Endpoint Observation is required before the node becomes schedulable again

### 12.2 Worker crash

Behavior:

* node agent marks affected worker `failed`
* an in-flight Request fails or retries at most once only when no Output Commitment occurred and execution resolution, deadline, capacity release, identity, and failure classification satisfy the closed retry gates
* worker restart backoff:

  * 1s, 2s, 4s, 8s, 16s, capped 30s
* after 5 crashes in 10 minutes:

  * placement marked `failed`
  * placement breaker opened

Recovery:

* operator can clear breaker
* forced reload or model unload/reload

### 12.3 Model load failure

Behavior:

* `EnsureModelLoaded` returns failure code and message
* placement state -> `failed`
* request fails if no alternate candidate exists
* if a different eligible Node exists and the transient load failure satisfies every closed retry gate before Output Commitment, retry once within the original deadline

Common error codes:

* `artifact_not_found`
* `checksum_mismatch`
* `insufficient_memory`
* `runtime_incompatible`
* `load_timeout`

### 12.4 Request timeout

Controller SHALL assign `timeout_at` once at Request creation during admission.
Queueing, scheduling, model loading, attempt 1, cleanup, evidence persistence, alternate scheduling, and attempt 2 SHALL share that absolute deadline.
Model-load and execution deadlines SHALL be capped by the remaining time and SHALL NOT extend `timeout_at`.
An explicit negotiated reasoning Request SHALL resolve `timeout_at` through the loaded-only formula for every resolved `residency_preference`: the selected generation budget alone, with neither a `max_queue_wait_ms` nor a `max_cold_start_ms` term.
`allow_cold_load` SHALL NOT widen that deadline, because §5.6 restricts the Request to already loaded Tier 0 candidates, and the configured maximum-request-deadline ceiling SHALL cap the result exactly as it caps any other Request.
Queue wait and the at most two §7.5.3a reasoning waves a logical Request may run SHALL consume that same budget rather than extend it, so a negotiated Request matches legacy traffic in queue outcome semantics but not in deadline duration.

On timeout:

* if queued: remove and mark `timed_out`
* if running/streaming: send cancel to node
* if node fails to cancel within grace period, force kill worker
* if the cancel drain times out without a resolved execution outcome, the Active Controller SHALL quarantine that Node per §4.6.2 so its unresolved occupancy is never redispatched as free capacity
* usage charges the selected terminal attempt's exact generated output tokens when proven, including hidden reasoning, and otherwise uses the latest validated cumulative usage with `output_usage_status = lower_bound`

Default timeout:

* `120000 ms`

### 12.5 Controller restart

Behavior:

* active client connections drop
* on startup, controller scans requests in non-terminal states
* these requests become `interrupted`
* controller queries nodes for active executions
* node agents cancel orphaned executions after controller session loss
* clients should retry with `Idempotency-Key` if safe

### 12.6 Postgres unavailable

Behavior:

* controller readiness false
* new requests rejected with `503 control_plane_unavailable`
* no scheduler activity
* existing node-local workers continue running only until active client/controller sessions end
* operator/admin writes blocked

Recovery:

* once DB restored, caches refresh and controller resumes leader tasks

### 12.7 Supportable failure invariants

The system SHALL guarantee:

* no request is terminal in two different states
* no node in non-`active` lifecycle state receives new work
* no auto-retry occurs after Output Commitment
* caller disconnect prevents retry and terminalizes as cancelled under the unified public mapping
* no alternate capacity is acquired while attempt 1 execution or release remains unresolved
* no pinned placement is auto-evicted
* quota reservations are always released on terminal reconciliation and never between attempts

---

## 13. Upgrade Strategy

### 13.1 Versioning rules

* Orchard Product Version is distinct from REST API path versions, gRPC package versions, Build Provenance, Apple build numbers, and independently versioned internal components.
* The root `VERSION` file is the canonical Orchard Product Version storage and SHALL contain exactly one ASCII pre-1.0 SemVer line followed by one terminal newline, with no comments, surrounding whitespace, additional lines, or build metadata.
* The umbrella and every first-party OTP application SHALL derive Mix project version metadata from root `VERSION`, and normal validation SHALL fail on any disagreement.
* Ordinary commits and merges SHALL retain the current Product Version and use the full source commit, build date, and build channel as distinct Build Provenance.
* Normal source validation SHALL accept a valid development Product Version without requiring or creating a release transition, tag, candidate, artifact, or publication state.
* external REST API path version: `/v1`
* internal gRPC package version: `cluster.v1`
* schema migrations are forward-only
* controller version `N` MUST support node agent versions `N` and `N-1`
* node agent version `N` MUST support bundled worker version `N` only

The reasoning-generation contract SHALL preserve the `N` and `N-1` support window with explicit capability negotiation.
A Controller and Node Agent pair that does not negotiate the complete reasoning contract SHALL exchange legacy requests and legacy event variants only.
When an older Controller communicates with a newer Node Agent through an otherwise supported protocol pairing, the Node Agent MUST NOT infer reasoning mode or emit a new reasoning event.
A Controller `N` communicating with a Node Agent `N-1` MAY dispatch an omitted public request through the complete legacy pipeline.
A Controller `N` MUST NOT dispatch an explicit `final_only` or `reasoning_structured` request to a Node Agent `N-1` unless that endpoint affirmatively advertises the exact pinned reasoning contract and compatible event binding as one complete supported tuple.
If no loaded placement proves that tuple under §7.5.3a's exhaustion rule, Orchard SHALL fail the explicit request before dispatch with the `503 server_error` plus `runtime_incompatible` mapping in §7.2.7.
A completed response from an `N-1` binding that advertises no negotiated reasoning contract is confirmed non-support under those probe result classes, so a loaded universe in which every placement answers that way exhausts and fails closed under that mapping rather than remaining queue-waitable until `queue_timeout`.
An endpoint that advertises the tuple but cannot reproduce it in the authoritative pre-execution acceptance proof SHALL fail under the same mapping before model invocation.
The Controller MUST NOT send a new request field to an older binding or accept a new event variant from an endpoint that did not advertise it.
Rolling upgrades SHALL NOT silently downgrade an explicit reasoning mode, change its public projection, or widen capture.

### 13.2 Migration strategy

All DB migrations SHALL follow **expand / migrate / contract**.

The accepted named-authorization migration SHALL additionally satisfy §10.11's whole-authority-writer compatibility and cutover contract.
Additive Console Identity/Session/RoleBinding and typed audit storage SHALL precede activation; acceptance of the design SHALL NOT authorize production cutover or declare its migrations complete.
Every retained API, CLI, Portal, session, grant, batch, and local recovery writer SHALL participate in the common authority fences before activation, even when its larger command family remains unmigrated.

Rules:

* additive columns/tables first
* new code reads both old and new where needed
* background backfill if required
* destructive drops only after all nodes/controllers run compatible version

The expand migration SHALL create the singleton durable dispatch-capacity authority row in phase `pre_cutover` with required contract version `1`.
The F11 dispatch-capacity migration SHALL create `shadow_legacy` policy rows only for non-removed production Nodes whose Node Admission committed before the expand migration, using durable `admitted_at` or equivalent admission history, and SHALL leave their Controller Dispatch Ceiling null during that temporary state.
Durably removed Nodes with revoked trust and successful removal audit SHALL retain historical policy evidence but SHALL NOT block approval or cutover.
Before enforcement cutover, new admissions SHALL write `approved_explicit` policy with an explicit ceiling before admission commits.
The migrate phase SHALL require operator approval without telemetry backfill and verify that all capacity consumers use the shared evaluation.
Cutover SHALL lock the singleton phase and migration advisory lock, quiesce every non-removed admitted production Node to zero live temporary claims and new fresh zero-active aggregate evidence under the Controller-local gates, validate the expected `pre_cutover` phase and fresh compatible all-consumers-ready evidence for every non-retired Controller instance, atomically advance approved policies to `enforcing`, record cutover provenance, and set the durable phase to `enforcing` in one transaction.
After enforcement cutover, new admissions SHALL write `enforcing` policy with an explicit ceiling before admission commits.
Admission SHALL select the singleton phase for update inside its transaction, including on an otherwise empty cluster, and SHALL fail closed if the phase is missing, malformed, or unsupported by that Controller.
The contract phase SHALL reject any otherwise eligible admitted production Node without an enforcing explicit policy and MAY strengthen persistence constraints after the bounded legacy cohort is removed.

Migration ownership SHALL be protected by advisory lock.

### 13.3 Controller upgrade

For named authorization, the generic upgrade sequences below SHALL be constrained by §10.11's durable cutover/rollback states, compatible-writer evidence, host/service launch gates, ingress fencing, and isolation from the live post-cutover authority database.
Console disablement alone SHALL NOT make an incompatible API, CLI, Portal, or direct-database writer safe to run.
Downgrades without verifiable database isolation SHALL be unsupported, and an isolated historical environment SHALL NOT retain the COMPLETE credential-family claim.

**Single-controller deployment**

1. stop public traffic or accept brief outage
2. backup config + DB
3. run the app-owned update lifecycle
4. start controller
5. run migrations
6. wait for readiness

**Active/Standby deployment**

1. ensure standby present
2. upgrade standby
3. standby acquires compatible schema
4. move traffic / leadership
5. upgrade former leader
6. restore steady state

### 13.4 Node agent upgrade

For each node:

1. cordon
2. drain
3. run the app-owned update lifecycle
4. keep the Node cordoned if the lifecycle reports failure, rollback failure, or uncertain installed state
5. verify the intended Node Agent version, heartbeat, and status synchronization after the service is started
6. uncordon

This supports rolling worker-plane upgrades without full cluster downtime.
The Controller `N` support window for Node Agent versions `N` and `N-1` provides protocol compatibility across sequential node upgrades.
It does not authorize concurrent Node Agent processes to share one Node Identity Root and does not define a zero-overlap replacement protocol.
Any future managed handover guarantee requires a fresh accepted OpenSpec proposal and a separate implementing pull request.

### 13.5 Worker upgrade

Workers are bundled with node agent.
Worker upgrade occurs through the app-owned Node Agent update lifecycle.
No standalone worker upgrade path in v1.

### 13.6 Managed Postgres upgrade

* minor version: replace container image, restart during maintenance window
* major version: explicit backup/restore or pg_upgrade workflow
* managed Postgres major upgrades are not rolling in single-host mode

### 13.7 Upgrade preflight checks

`orchardctl upgrade plan` SHALL validate:

* backup exists
* no node in `decommissioning`
* queue empty or within tolerance
* no active drain operations
* all nodes at compatible starting versions
* DB reachable and lockable

---

## 14. Implementation Roadmap

### Milestone 0 - Skeleton and packaging foundation

Deliver:

* umbrella repo
* controller release boots
* node agent release boots
* Postgres repo/migrations
* launchd plists
* Orchard.app and DMG packaging skeleton
* `/health/live`, `/health/ready`

Acceptance:

* controller starts on macOS
* node agent starts on macOS
* `Orchard.app` assembles as a valid app bundle and passes sandboxed service-lifecycle rollback and retention tests
* the verified app assembles into a mountable DMG without nested signature or entitlement drift
* the app-owned lifecycle installs launchd services correctly

### Milestone 1 - Single-node inference MVP

Deliver:

* one-node all-in-one mode
* model catalog import
* exact tokenization helper
* `GET /v1/models`
* `POST /v1/chat/completions`
* streaming SSE for chat completions
* MLX worker adapter
* requests + request_events persistence

Acceptance:

* local chat completion works end-to-end
* streamed tokens relay through controller
* request state transitions persisted
* cancellation works

### Milestone 2 - Responses API and governance core

Deliver:

* `POST /v1/responses`
* OpenAI-compatible response object subset
* tenants
* API keys
* quotas
* audit logs
* idempotency keys

Acceptance:

* tenant-scoped inference works
* quota rejection path works
* `/v1/responses` stream emits typed events
* audit events emitted for key governance actions

### Milestone 3 - Node lifecycle and cluster join

Deliver:

* bootstrap token flow
* certificate join flow
* node registration
* heartbeats
* pools
* admission API and admission-review CLI commands
* cordon/drain/maintenance/decommission
* Console node status and admission-review pages

Acceptance:

* second node joins cluster
* admin admits node
* health transitions behave as specified
* drain prevents new scheduling

### Milestone 4 - Multi-node scheduler and placements

Deliver:

* scheduler candidate filtering
* tiered scoring
* queueing
* model placements
* `EnsureModelLoaded`
* bounded Automatic Attempt Retry before Output Commitment
* scheduler explanation endpoint

Acceptance:

* requests land on best loaded node
* cached/cold tier behavior works
* Automatic Attempt Retry performs at most one second attempt on a different Node before Output Commitment, within one absolute deadline, with release-before-acquire ordering and durable attempt evidence
* text, tool-call identity, and structured-output commitment prevent retry while empty text and control events do not
* admission, idempotency, quota reservation, logical Request metrics, and capture policy remain exactly once per Request
* each started attempt records bounded evidence, breaker attribution, and attempt metrics without high-cardinality metric labels
* scheduler explanation matches actual decision

### Milestone 5 - Observability and diagnostics

Deliver:

* Prometheus metrics
* OTel tracing
* structured logs
* node diagnostics endpoint
* recommended Grafana dashboards JSON

Acceptance:

* p95 latency visible in Grafana
* a request trace spans auth→schedule→execute→stream

### Milestone 6 - Security hardening and air-gap

Deliver:

* mTLS internal RPC
* cert renewal
* key rotation
* retention modes
* offline model import workflow
* managed Postgres container mode
* offline DMG and app-owned install flow

Acceptance:

* node join via bootstrap produces signed cert
* internal gRPC compatibility rejects non-mTLS clients
* production first-party BEAM rejects missing, expired, revoked, wrong-generation, wrong-name, wrong-certificate, and wrong-identity Peer Grant connections without automatic gRPC fallback
* air-gapped installation completes with no internet access

### Milestone 7 - Upgrade safety and Active/Standby controller

Deliver:

* advisory-lock leadership
* standby controller mode
* rolling worker-node upgrade procedures
* migration lock and expand/contract enforcement
* `orchardctl upgrade plan`

Acceptance:

* standby controller can assume leadership
* rolling node upgrade causes no cluster-wide outage
* schema migration ownership is exclusive
* interrupted requests reconcile correctly after controller handover

### Milestone 8 - Portable Orchard control-plane core and Linux Controller profile

This is a vNext platform-expansion milestone.
It does not rewrite completed macOS acceptance in Milestones 0–7.

Deliver:

* portable Orchard control-plane core dependency boundaries with no unconditional Apple or accelerator toolchain requirement
* Darwin host artifacts outside portable CLI compilation
* required Linux validation for the portable Orchard control-plane core and provider-neutral conformance
* Controller release authority independent from CLI implementation
* provider-neutral Worker Runtime protocol ownership and generated bindings
* additive normalized artifact, runtime-provider, acceleration, device-resource, memory-domain, and failure contracts
* separate host capability-provider and runtime-provider evidence
* macOS app-owned lifecycle behind a host adapter without claiming an unimplemented cross-process handover protocol
* security-led migration of normal CLI command families to Controller-owned operations
* Linux Controller platform profile with operator-provided external Postgres

Acceptance:

* portable Orchard control-plane core applications compile, lint, test, and produce coverage in the required Linux portability lane without Xcode, launchd, MLX, CUDA, or Darwin native-helper compilation
* macOS host-lifecycle, Orchard.app/DMG, and MLX validation run as separate applicable macOS lanes
* credential-free signing-contract validation remains distinct from release-only Developer ID signing, notarization, stapling, and publication
* macOS all-in-one, split-role, Orchard.app, DMG, launchd, retained-state, air-gap, and MLX acceptance remain green
* the Controller release does not load CLI implementation to obtain Controller authority
* the portable CLI does not require direct Repo authority or Darwin native compilation for normal Controller-state operations
* Worker Runtime contracts have provider-neutral ownership, generated bindings, version negotiation, drift checks, and conformance coverage
* the mixed-platform acceptance profile proves a Linux Controller with external Postgres operating an admitted macOS Node under the macOS MLX Node runtime profile across trust, Runtime Endpoint observation, scheduling, streaming, cancellation, restart, and failure behavior
* production BEAM admission for the Linux Controller profile satisfies ADR 0012 provenance, identity, host-control, network, and mixed-platform acceptance gates
* `SPEC.md`, decisions, OpenSpec specs, tests, documentation, and implementation agree before the Linux Controller profile is declared supported

---

This spec defines the supported v1 Apple Silicon macOS platform profile and the accepted vNext platform-expansion target for the portable Orchard control-plane core.
The coding agent should implement it in milestone order, preserving wire compatibility and state-machine behavior exactly as written where fields, states, and transitions are explicitly defined.
Architecture acceptance does not declare an unimplemented platform profile supported.

[1]: https://developers.openai.com/api/docs/guides/migrate-to-responses/ "https://developers.openai.com/api/docs/guides/migrate-to-responses/"
[2]: https://support.apple.com/guide/terminal/script-management-with-launchd-apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac "https://support.apple.com/guide/terminal/script-management-with-launchd-apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac"
[3]: https://github.com/ml-explore/mlx "https://github.com/ml-explore/mlx"
[4]: https://www.postgresql.org/docs/current/explicit-locking.html "https://www.postgresql.org/docs/current/explicit-locking.html"
[5]: https://developers.openai.com/api/reference/resources/models/methods/list/ "List models | OpenAI API Reference"
[6]: https://developers.openai.com/api/docs/guides/streaming-responses/ "https://developers.openai.com/api/docs/guides/streaming-responses/"
[7]: https://opentelemetry.io/docs/languages/erlang/ "https://opentelemetry.io/docs/languages/erlang/"
[8]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution "https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution"
[9]: https://opensource.apple.com/projects/containerization "https://opensource.apple.com/projects/containerization"
