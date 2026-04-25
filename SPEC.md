# Orchard v2 — Technical Specification

This document is a normative implementation spec for Orchard, a sovereign on-prem LLM orchestration platform optimized for **1–4 Apple Silicon macOS nodes**. It is intended for a coding agent that will build the system incrementally. “MUST”, “SHALL”, and “MUST NOT” are mandatory requirements. “SHOULD” is a strong recommendation.

Unless otherwise noted, implementation-facing names in this spec use the Orchard namespace: `Orchard.*` for Elixir modules, `orchard_*` for OTP apps and repositories, `orchard-*` for binaries/daemons, `orchardctl` for the CLI, and `com.orchard.*` for bundle identifiers, launchd labels, and similar platform identifiers. This naming policy does not apply to OpenAI-compatible wire protocol fields, endpoints, event names, or error envelopes, which SHALL remain unchanged for compatibility.

The platform exposes **OpenAI-compatible** inference APIs. Internally, it SHALL treat **`/v1/responses` as the canonical inference abstraction** and implement **`/v1/chat/completions` as a compatibility facade**, because OpenAI currently recommends the Responses API for new projects while keeping Chat Completions supported, and streaming is based on server-sent events. ([OpenAI Developers][1])

---

## 1. System Architecture

### 1.1 Target topology

Supported deployment modes:

1. **All-in-one single node**

   * 1 Mac runs:

     * control plane
     * node agent
     * local worker runtime
     * managed Postgres

2. **Controller + worker nodes**

   * 1 Mac runs control plane
   * 1–3 Macs run node agent + local workers
   * Postgres is either managed on controller host or external

3. **HA-lite control plane**

   * 2 controller instances maximum
   * exactly 1 active leader at a time
   * remains within the overall 1–4 Mac deployment limit
   * active/standby coordination via Postgres advisory lock
   * requires external VIP, reverse proxy, or operator-managed endpoint failover

### 1.2 Core design rules

* No Kubernetes.
* No distributed Erlang cluster across machines.
* No active/active controller mode in v1.
* All durable state SHALL live in Postgres.
* All cross-node control traffic SHALL use **gRPC over mTLS**.
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
                     |  - Public Inference API       |
                     |  - Operator API               |
                     |  - Admin API                  |
                     |  - Auth/RBAC                  |
                     |  - Admission                  |
                     |  - Scheduler                  |
                     |  - Dispatch                   |
                     |  - Request FSMs               |
                     |  - Metrics/Tracing/Logs       |
                     +---------+-----------+---------+
                               |           |
                        SQL / TLS          gRPC / mTLS
                               |           |
                     +---------v--+   +---v--------------------+
                     | Postgres    |   | Node Agent(s)         |
                     | durable DB  |   | - Register/Heartbeat  |
                     +------------ +   | - Model cache         |
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

### 1.4 macOS-specific platform assumptions

The system SHALL be packaged as a native macOS product using **launchd** for system daemons and agents. Managed local Postgres mode SHALL use Apple Silicon-compatible local containerization, with Apple’s Containerization project or the open-source `container` implementation as the supported local runtime path. Apple documents launchd as the system service manager for daemons/agents, and its Containerization project as a macOS Linux-container runtime built on Apple Silicon virtualization. ([Apple Support][2])

### 1.5 First-class runtime

The required v1 worker runtime is **MLX-based**. The default adapter SHALL target **MLX-LM**. Additional compatible runtimes may be added later via a runtime adapter interface. MLX is specifically built for Apple Silicon, and MLX-LM provides text generation on Apple Silicon. ([GitHub][3])

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
| `orchard-controller`    | launchd LaunchDaemon | Main control plane daemon                                    |
| `Orchard.API`           | OTP app              | HTTP API surface: `/v1`, `/ops/v1`, `/admin/v1`              |
| `Orchard.Auth`          | OTP app              | API key auth, service account auth, RBAC                     |
| `Orchard.Admission`     | OTP app              | validation, tenant policy, quotas, idempotency               |
| `Orchard.Scheduler`     | OTP app              | node selection, queueing, fairness, placement decisions      |
| `Orchard.Dispatch`      | OTP app              | gRPC calls to node agents, stream fan-out to clients         |
| `Orchard.Catalog`       | OTP app              | model catalog, artifact manifests, routing policy resolution |
| `Orchard.Nodes`         | OTP app              | node registry, lifecycle, heartbeat snapshots                |
| `Orchard.Requests`      | OTP app              | per-request FSMs and request event logging                   |
| `Orchard.Observability` | OTP app              | metrics, traces, logs                                        |
| `Orchard.Governance`    | OTP app              | tenants, quotas, keys, audit logs                            |

### 2.2 Node-side components

| Component               | Process type         | Responsibility                                   |
| ----------------------- | -------------------- | ------------------------------------------------ |
| `orchard-node-agent`        | launchd LaunchDaemon | Node control endpoint                            |
| `Orchard.Node.Register`      | OTP app              | join, cert renewal, heartbeat                    |
| `Orchard.Node.Models`        | OTP app              | artifact cache, verification, load/unload        |
| `Orchard.Node.Workers`       | OTP app              | worker supervisor, crash recovery                |
| `Orchard.Node.Diagnostics`   | OTP app              | health and support data                          |
| `orchard-worker-supervisor` | spawned child        | manages one or more worker runtime processes     |
| `orchard-worker-mlx`        | spawned child        | MLX runtime server for one loaded model instance |

### 2.3 End-user and operator components

| Component               | Packaging                    | Responsibility                                             |
| ----------------------- | ---------------------------- | ---------------------------------------------------------- |
| Tray/menu bar app       | `.app` + LaunchAgent         | local status, onboarding, logs, support bundle entry point |
| `orchardctl` CLI            | binary                       | admin/operator automation, bootstrap, diagnostics          |
| Managed Postgres helper | LaunchDaemon in managed mode | local DB lifecycle only                                    |

### 2.4 Repository structure

The implementation SHOULD use an umbrella repository with separate Elixir releases:

```text
/apps
  /orchard_shared        # protobufs, common structs, config parsing
  /orchard_controller    # controller release
  /orchard_node_agent    # node agent release
  /orchard_cli           # CLI
/native
  /orchard_worker_mlx    # python runtime adapter
  /orchard_tokenizer     # tokenizer/render helper
/proto
  cluster/v1/*.proto
/packaging
  dmg/
  pkg/
  launchd/
  container/
```

### 2.5 Process boundaries

* Controller and node agent SHALL be separate releases.
* Controller MAY run on a node that also runs a node agent.
* Worker runtimes SHALL be subprocesses supervised by node agent, not permanent launchd services.
* Tokenization/rendering helper MAY be a bundled native or Python helper, but the controller API layer remains Elixir/OTP.

---

## 3. Control Plane Design

### 3.1 Controller runtime model

The controller SHALL be a Phoenix/Plug HTTP service plus a gRPC server and gRPC client pool.

**Required listeners**

* `:8443` HTTPS for public/admin/operator APIs
* `:8444` gRPC/mTLS for node registration/heartbeat/event ingress
* `:9464` Prometheus metrics endpoint

**Required readiness conditions**

* Postgres reachable
* migrations current
* model/tenant/key caches loaded
* if HA-lite enabled: instance is leader for write paths

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
├─ Orchard.RequestSupervisor
├─ Orchard.Scheduler.Supervisor
│  ├─ Orchard.Scheduler.QueueManager
│  ├─ Orchard.Scheduler.Dispatcher
│  └─ Orchard.Scheduler.PlacementReconciler
├─ Orchard.NodeSupervisor
├─ Orchard.AuditSupervisor
├─ Orchard.Observability.Supervisor
└─ Orchard.LeaderTasks
   ├─ Orchard.Leader.LockManager
   ├─ Orchard.Leader.RetentionSweeper
   ├─ Orchard.Leader.QuotaSweeper
   └─ Orchard.Leader.SupportBundleManager
```

### 3.3 Controller leadership

The controller SHALL support:

* **single-controller mode**: one instance, always leader
* **HA-lite mode**: up to two controller instances, one leader

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

### 3.4 Canonical request model

All public inference requests SHALL normalize into one internal struct:

```elixir
%CanonicalRequest{
  internal_id: UUID,
  public_id: String.t(),
  endpoint: :chat_completions | :responses,
  tenant_id: UUID,
  principal_id: UUID | nil,
  api_key_id: UUID | nil,
  model_ref: %{
    model_id: String.t(),
    version: String.t()
  },
  input_items: [map()],
  rendered_prompt: binary() | nil,
  input_token_count: non_neg_integer(),
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
    residency_preference: :required_loaded | :prefer_loaded | :allow_cold_load
  }
}
```

Tooling contract rules:

* request `tools` entries MAY be inline function definitions or registry refs of the form `tool://<name>@<version>`
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

failure exits:
  -> failed
  -> cancelled
  -> timed_out
  -> interrupted
```

Rules:

* `running` means node accepted and worker prefill began
* `streaming` means at least one token or structured delta has been emitted
* `interrupted` is used for controller/process failure after dispatch but before terminal reconciliation
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

### 3.9 Idempotency

The controller SHALL support `Idempotency-Key` on both public inference endpoints.

Rules:

* uniqueness scope: `(tenant_id, idempotency_key)`
* if same key + same body hash already completed and `stream=false`, return stored result
* if same key + same body hash is still active, return `409 request_in_progress`
* if same key reused with different body hash, return `409 idempotency_mismatch`
* streaming responses SHALL NOT be replayed from persisted token chunks in v1

---

## 4. Node Management

### 4.1 Node identity model

A node is an explicitly managed resource representing one macOS Apple Silicon machine.

A node record SHALL include:

* stable `node_id` UUID
* hostname
* advertise address
* pool membership
* chip/memory/runtime capabilities
* trust material reference
* lifecycle state
* current health
* last heartbeat timestamp

### 4.2 Node lifecycle states

| State             | Meaning                                                           | Schedulable |
| ----------------- | ----------------------------------------------------------------- | ----------- |
| `provisioned`     | admin created placeholder/bootstrap issued; node has not joined   | no          |
| `registered`      | node proved identity and submitted inventory                      | no          |
| `admitted`        | admin accepted node into cluster and assigned pool/policy         | no          |
| `active`          | healthy and eligible for scheduling                               | yes         |
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
draining    -> maintenance
maintenance -> active

registered  -> decommissioning
admitted    -> decommissioning
active      -> decommissioning
cordoned    -> decommissioning
maintenance -> decommissioning
decommissioning -> removed
```

### 4.4 Transition rules

* `provisioned -> registered`

  * trigger: successful `RegisterNode`
  * conditions: valid bootstrap token or valid client cert

* `registered -> admitted`

  * trigger: Admin API action
  * conditions: inventory captured, trust established, pool assigned

* `admitted -> active`

  * trigger: first successful healthy heartbeat after admission

* `active -> cordoned`

  * trigger: operator/admin action
  * effect: scheduler excludes node immediately

* `active|cordoned -> draining`

  * trigger: operator/admin action
  * effect: no new requests, wait until `active_request_count == 0`

* `draining -> maintenance`

  * trigger: automatic when drained and requested action specified
  * effect: model preloads disabled, diagnostics allowed

* `maintenance -> active`

  * trigger: operator/admin action
  * conditions: health is not `unreachable` or `unhealthy`

* `* -> decommissioning`

  * trigger: admin action
  * effect: cordon, revoke future scheduling, cancel or drain active work, revoke join trust

* `decommissioning -> removed`

  * trigger: cleanup success
  * effect: no rejoin with same `node_id`

### 4.5 Node health model

Health is orthogonal to lifecycle state.

Valid health values:

* `healthy`
* `degraded`
* `unhealthy`
* `unreachable`

Required controller thresholds:

* heartbeat interval: **2000 ms**
* stale threshold: **6000 ms**
* unreachable threshold: **15000 ms**

Health derivation:

* `healthy`: heartbeat fresh and no local alarm
* `degraded`: fresh heartbeat, but warning condition exists
* `unhealthy`: fresh heartbeat, but serious local error
* `unreachable`: heartbeat older than 15s

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

Node agent SHALL send heartbeats every 2 seconds with:

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

### 4.6.1 Hosted-tool capability and readiness observation

Hosted-tool observation SHALL remain distinct from heartbeat inventory in the current implementation slice.

Rules:

* the active implementation seam for hosted-tool observation SHALL be `NodeRuntimeService.GetStatus` returning `StatusResponse`
* heartbeat payloads MAY carry equivalent hosted-tool data in a later slice, but controller-owned hosted-tool observation SHALL currently be derived from status-probe ingestion
* this contract defines future hosted routing inputs only; it SHALL NOT by itself enable controller-owned hosted `/v1/responses` execution or any other hosted execution behavior

Hosted-tool observation vocabulary:

* **static capability** identifies a node-advertised hosted tool by registry-compatible `name` and `version`, plus the local `adapter_kind`
* **dynamic readiness** reports whether that same advertised hosted tool is currently ready on the node, with `ready`, `readiness_code`, and `readiness_message`
* the controller SHALL derive canonical hosted-tool identity as `tool://<name>@<version>`
* hosted-tool identity SHALL align with controller registry semantics; Orchard SHALL NOT introduce a second hosted-tool naming scheme

Compatibility and defaulting rules:

* absent hosted-tool capability/readiness fields on `StatusResponse` SHALL mean the node advertises no hosted tools
* absent hosted-tool capability/readiness fields SHALL NOT be treated as a status-probe error
* readiness without matching advertised capability for the same `tool://<name>@<version>` SHALL NOT make the node eligible for hosted routing
* absent or empty `runtime_memory_budgets` on `StatusResponse` SHALL mean no memory-budget observation is available
* absent or empty `runtime_memory_budgets` SHALL NOT be treated as a status-probe error
* `runtime_memory_budgets` SHALL remain observe-only telemetry except for the Phase 4E scheduler-ranking guard defined in §5.7 and §7.5.3; it SHALL NOT affect node readiness, model admission, request admission, scheduling eligibility, hosted-tool eligibility, public error contracts, queue ordering, or memory-budget enforcement
* when `memory_admission.enabled = true`, `Orchard.Scheduler.MultiNode` MAY use only `RuntimeMemoryBudget.status_code == "ok"` plus `headroom_available == true` as a positive, non-excluding ranking preference below loadedness, active request count, health, live prefix-cache fingerprint match, and historical cache affinity, and above deterministic `node_id`
* absent, empty, stale, malformed, disabled, unavailable, invalid, device-info-failed, compute-failed, non-`ok`, or `headroom_available != true` memory telemetry SHALL be rank-neutral and fail open
* current `RuntimeMemoryBudget.status_code` vocabulary is: `ok`, `disabled`, `device_info_unavailable`, `device_info_invalid`, `resident_memory_unavailable`, `compute_failed`, `invalid_status`
* absent or empty `runtime_prefix_cache_statuses` on `StatusResponse` SHALL mean no prefix-cache observation is available
* absent or empty `runtime_prefix_cache_statuses` SHALL NOT be treated as a status-probe error
* aggregate `runtime_prefix_cache_statuses` counters SHALL remain observe-only telemetry and SHALL NOT affect node readiness, model admission, request admission, scheduling eligibility, queue ordering, hosted-tool eligibility, or `worker_generation_mode`; the Phase 4C bounded HMAC fingerprint field MAY affect scheduler ranking only as the explicitly configured non-gating tie-breaker defined in §5.7 and §7.5.3
* current `RuntimePrefixCacheStatus.status_code` vocabulary is: `ok`, `disabled`, `unavailable`, `error`, `invalid_status`
* these status codes are observational only in this slice and SHALL NOT gate readiness, admission, or scheduling

Effective readiness rules for future hosted routing:

* a node candidate is effectively ready for a hosted tool only when the controller registry contains an active tool with matching `name` and `version`
* the registry tool `execution_mode` SHALL be `:server_hostable`
* the node SHALL advertise matching static hosted-tool capability for the same `tool://<name>@<version>`
* the node lifecycle state SHALL be `active`
* node health SHALL be `healthy` or `degraded`
* the node observation SHALL be fresh under Orchard's existing freshness thresholds
* dynamic readiness for that tool SHALL exist and have `ready = true`

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
* expose gRPC runtime endpoint
* download/verify model artifacts
* manage worker subprocess lifecycle
* report immediate state changes
* collect diagnostics
* cancel orphaned requests when controller session disappears

### 4.10 Local worker contract

Node agent SHALL own worker lifecycle. Local workers SHOULD speak gRPC over Unix domain sockets, with this minimal internal contract:

* `LoadModel`
* `UnloadModel`
* `Generate`
* `Cancel`
* `Status`

This local API is internal-only and not part of the public compatibility contract.

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

Quota admission SHALL serialize per tenant via advisory transaction lock on hashed tenant id.

Admission accounting:

* input tokens are charged exactly at admission
* output tokens are **reserved** at admission using requested `max_output_tokens`
* on completion:

  * actual output tokens charged
  * unused reserved output tokens released
* on failure before first token:

  * reserved output tokens fully released
* on partial failure after streaming starts:

  * already emitted output tokens remain charged
  * unused reserved output tokens released

### 5.4 Queue model

When no node is immediately eligible:

* request enters tenant FIFO queue
* max wait defaults to `3000 ms`
* max queued requests per tenant defaults to `32`

Queue discipline:

* one FIFO queue per tenant
* cross-tenant selection uses weighted round-robin
* tenant weight default = 1
* within tenant, strict FIFO

Scheduler wake-up triggers:

* new request admitted
* request finished/cancelled
* heartbeat state change
* placement state change
* periodic tick every `100 ms` while queue non-empty

### 5.5 Eligibility filter

A node is eligible only if all conditions are true:

* node state = `active`
* node health in `{healthy, degraded}`
* pool is allowed by routing policy
* model format is supported by node runtime
* node has enough memory headroom
* node concurrency not exceeded
* model placement concurrency not exceeded
* no placement/node circuit breaker suppresses dispatch

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

### 5.7 Scoring formula

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

Controller-side cache-affinity, Phase 4D tie-only scoring, and memory-admission ranking for the bounded current implementation SHALL use the following late tie-break order among otherwise schedulable candidates in the same residency/load/health position:

1. loaded model already present
2. lower active request count
3. healthier node (`healthy` before `degraded`)
4. live prefix-cache fingerprint match, only when both `cache_affinity.enabled=true` and `cache_affinity.live_fingerprint_match_enabled=true`
5. historical cache-affinity match from recent completed placements, when cache affinity is enabled
6. explicit memory-headroom observation, only when `memory_admission.enabled=true` and the candidate's matching `RuntimeMemoryBudget` has `status_code = "ok"` and `headroom_available = true`
7. lexicographically smaller `node_id`

Default Phase 4D runtime behavior remains observe-only (`prefix_cache_scoring.ranking_mode = :observe_only`) and rank-neutral.

When `prefix_cache_scoring.enabled=true`, `cache_affinity.enabled=true`, `cache_affinity.live_fingerprint_match_enabled=true`, and `prefix_cache_scoring.ranking_mode = :tie_only`, the scheduler MAY apply one bounded conditional score step immediately before step 7, only for the leading rank-equivalence group where steps 1–6 are equal and only deterministic `node_id` differs. Candidate scoring in this conditional step is capped at 2 (incumbent + challenger). The challenger MAY be promoted only when challenger score normalizes to `status_code = "ok"` with `resident_fingerprint_match = true` and `score_tier = "resident_fingerprint"`, and the incumbent score is comparable `ok` non-resident (`status_code = "ok"`, `resident_fingerprint_match = false`, and `score_tier` is `"no_match"` or `"recent_fingerprint_only"`). Any non-`ok`, timeout, unsupported, unavailable, `model_not_loaded`, `invalid_request`, missing, malformed, contradictory, or transport-failure score outcome for either candidate SHALL preserve base order fail-open and deterministic `node_id` fallback.

A live prefix-cache fingerprint match is a bounded, approximate warmth hint. It SHALL bias ranking only after health and before historical affinity. The memory-headroom observation is a bounded, positive-only hint. It SHALL bias ranking only after live and historical cache-affinity signals and before deterministic `node_id`; candidates with absent, malformed, unavailable, or non-`ok` memory-budget telemetry remain schedulable and rank-neutral. Neither hint SHALL change node eligibility, request admission, queue ordering, public error contracts, or runtime concurrency.

### 5.8 Scheduling algorithm

```text
schedule(req):
  candidates = filter_eligible_nodes(req)

  if candidates.empty?:
    enqueue_or_reject(req)

  tiered = pick_best_nonempty_tier(candidates)

  ordered = sort_by_score_then_tie_break(tiered)

  for node in ordered:
    if dispatch(req, node) == ok:
      return ok
    else if failure_before_first_token and retryable:
      continue
    else:
      fail req

  enqueue_or_reject(req)
```

### 5.9 Dispatch rules

Dispatch sequence:

1. reserve request in request FSM (`scheduled`)
2. if placement not `loaded`, call `EnsureModelLoaded`
3. re-check node freshness after load
4. call `ExecuteInference`
5. wait for `accepted`
6. transition request to `running`

Retry rule:

* automatic retry at most **once**
* only if failure occurs **before first token emitted**
* retry must choose a different node if one exists
* after first token, no automatic retry

### 5.10 Circuit breakers

Node-level breaker:

* trigger: 3 dispatch failures in 60 seconds
* effect: scheduler suppresses node for 5 minutes

Placement-level breaker:

* trigger: 3 load failures for same `(node, model)` in 10 minutes
* effect: suppress cold/warm load on that node for 15 minutes

Operator MAY clear either breaker through Operator API.

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

Offline-importable model bundle SHALL be a tarball or directory with manifest:

```json
{
  "model_id": "llama-3.1-8b-instruct",
  "version": "mlx-q4-v1",
  "format": "mlx",
  "artifact_layout": "directory",
  "entrypoint": "weights/",
  "sha256": "hex",
  "size_bytes": 1234567890,
  "resident_memory_bytes": 6442450944,
  "kv_cache_bytes_per_token": 16384,
  "prefill_workspace_bytes_per_token": 2048,
  "max_context_tokens": 32768,
  "capabilities": ["chat", "tool_calling", "json_mode"],
  "tokenizer": {
    "kind": "huggingface_tokenizer_json",
    "path": "tokenizer.json"
  },
  "chat_template": {
    "path": "chat_template.jinja",
    "sha256": "hex"
  },
  "runtime_requirements": {
    "adapter": "mlx_lm",
    "min_agent_capability": "mlx"
  }
}
```

`resident_memory_bytes` is static manifest-derived metadata in the current
slice: it is a lower-bound/payload-size estimate derived from bundle artifacts
(for MLX safetensors bundles, prefer `model.safetensors.index.json`
`metadata.total_size`, then fail open to regular `.safetensors` file sizes when
index metadata is unavailable). It is not a runtime memory probe. This metadata
remains observe-only and SHALL NOT gate readiness, request admission, model
admission, scheduler eligibility, hosted-tool eligibility, or
`memory_budget_mode` enforcement.

### 6.5 Model import

Models SHALL be imported via:

* Admin API metadata import
* CLI import from local path
* optional upload to controller artifact store

Import steps:

1. parse manifest
2. verify required fields
3. compute sha256
4. optionally verify detached signature
5. insert catalog record
6. store artifact in controller artifact root
7. mark catalog state `registered`

### 6.6 Model publication

A model becomes tenant-visible only when:

* catalog state transitions `registered -> active`
* at least one tenant is granted access
* routing policy resolution exists or default applies

### 6.7 Model distribution

Distribution modes:

1. **controller-hosted artifacts**

   * node agents fetch bundle over internal mTLS HTTP/gRPC
2. **pre-staged local media**

   * operator imports bundle on each node
3. **shared offline path**

   * optional mounted path identical on all nodes

Air-gapped systems MUST support mode 1 and mode 2.

### 6.8 Load/unload semantics

`EnsureModelLoaded` SHALL be idempotent.

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

The platform SHALL expose four API surfaces:

1. **Public Inference API**

   * OpenAI-compatible
   * HTTPS JSON + SSE
   * bearer API keys

2. **Operator API**

   * runtime operations
   * HTTPS JSON
   * operator/admin auth

3. **Admin API**

   * governance/configuration
   * HTTPS JSON
   * admin/tenant-admin auth

4. **Internal Node/Worker API**

   * controller↔node RPC
   * gRPC over mTLS

---

### 7.2 Public Inference API

#### 7.2.1 Compatibility contract

The Public Inference API SHALL prioritize wire compatibility with OpenAI for:

* `GET /v1/models`
* `POST /v1/chat/completions`
* `POST /v1/responses`

`/v1/models` SHALL return objects shaped like OpenAI model list entries with `id`, `object`, `created`, and `owned_by`. ([OpenAI Developers][5])

#### 7.2.2 Authentication

Header:

```http
Authorization: Bearer <api_key>
```

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
* when `store=false`, full prompt/response payload retention SHALL follow tenant retention policy and default to redacted metadata only

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
* `503` cluster busy / no eligible node
* `504` request timeout

---

### 7.3 Operator API

Base path: `/ops/v1`

#### 7.3.1 Endpoints

```text
GET    /ops/v1/cluster
GET    /ops/v1/nodes
GET    /ops/v1/nodes/:node_id
POST   /ops/v1/nodes/:node_id/cordon
POST   /ops/v1/nodes/:node_id/uncordon
POST   /ops/v1/nodes/:node_id/drain
POST   /ops/v1/nodes/:node_id/maintenance
POST   /ops/v1/nodes/:node_id/resume
GET    /ops/v1/requests/:request_id
POST   /ops/v1/requests/:request_id/cancel
POST   /ops/v1/requests/:request_id/retry
GET    /ops/v1/scheduler/explanations/:request_id
POST   /ops/v1/nodes/:node_id/diagnostics
POST   /ops/v1/support-bundles
```

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
* uses stored canonical request
* creates new request row
* `retry_of_request_id` points to original
* max operator retries per original request default = 3

#### 7.3.5 Scheduler explanation

Response example:

```json
{
  "request_id": "resp_01J...",
  "selected_node_id": "node-2",
  "selection_tier": "loaded",
  "scored_candidates": [
    {
      "node_id": "node-2",
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
      "rejections": []
    },
    {
      "node_id": "node-1",
      "eligible": false,
      "rejections": ["cordoned", "insufficient_memory"]
    }
  ]
}
```

---

### 7.4 Admin API

Base path: `/admin/v1`

#### 7.4.1 Endpoints

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

POST   /admin/v1/nodes/provision
POST   /admin/v1/nodes/:node_id/admit
POST   /admin/v1/nodes/:node_id/decommission

PATCH  /admin/v1/observability
POST   /admin/v1/bootstrap-tokens
```

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
  "key_prefix": "orchard_kp_01J...",
  "secret": "orchard_sk_01J....<secret>",
  "expires_at": "2026-12-31T00:00:00Z"
}
```

#### 7.4.4 Model import example

```json
POST /admin/v1/models/import
{
  "source_type": "local_path",
  "path": "/Volumes/Models/llama-3.1-8b-instruct-mlx-q4-v1.tar",
  "activate": false
}
```

#### 7.4.5 Observability config example

```json
PATCH /admin/v1/observability
{
  "tracing": {
    "enabled": true,
    "otlp_endpoint": "https://otel-collector.local:4318",
    "sample_ratio": 0.1
  },
  "metrics": {
    "bind": "0.0.0.0:9464",
    "basic_auth_enabled": false
  },
  "logging": {
    "level": "info",
    "retention_days": 7
  }
}
```

---

### 7.5 Internal Node/Worker API

Protocol: **gRPC over HTTP/2 + TLS 1.3 + mTLS**

Required ports:

* controller gRPC ingress: `8444`
* node agent gRPC ingress: `9444`

#### 7.5.1 Controller-side service

```proto
service ClusterMembershipService {
  rpc RegisterNode(RegisterNodeRequest) returns (RegisterNodeResponse);
  rpc Heartbeat(HeartbeatRequest) returns (HeartbeatResponse);
  rpc ReportStatus(StatusReportRequest) returns (Ack);
  rpc RenewCertificate(RenewCertificateRequest) returns (RenewCertificateResponse);
}
```

#### 7.5.2 Node-side service

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

message StatusResponse {
  WorkerState worker_state = 1;
  repeated ModelRef loaded_models = 2;
  uint32 active_request_count = 3;
  RuntimeNodeMetadata node_metadata = 4;
  RuntimeHealth runtime_health = 5;
  repeated HostedToolCapability hosted_tool_capabilities = 6;
  repeated HostedToolReadiness hosted_tool_readiness = 7;
  repeated RuntimeMemoryBudget runtime_memory_budgets = 8;
  repeated RuntimePrefixCacheStatus runtime_prefix_cache_statuses = 9;
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
}

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
  }
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
* if a request completes successfully after emitting one or more tool-call deltas, the terminal `Completed.finish_reason` SHALL be `FINISH_REASON_TOOL_CALLS`

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
* positive resident-memory metadata MAY make `status_code = ok` and `headroom_available = true` when the observe-only arithmetic has enough inputs; when `memory_admission.enabled = true`, that exact positive observation MAY be used by `Orchard.Scheduler.MultiNode` only as a non-gating, non-excluding ranking preference below loadedness, active request count, health, live prefix-cache fingerprint match, and historical cache affinity
* neither `RuntimeMemoryBudget.status_code` nor `RuntimeMemoryBudget.resident_memory_bytes` is an enforcement input in this slice; they SHALL NOT alter readiness, request admission rejection, model admission, scheduler eligibility, hosted-tool eligibility, public error contracts, queue ordering, or `memory_budget_mode` enforcement
* absent, empty, stale, malformed, disabled, unavailable, invalid, device-info-failed, compute-failed, non-`ok`, or `headroom_available != true` memory telemetry SHALL be rank-neutral and fail open
* `estimated_headroom_bytes` SHALL NOT be used as a threshold, continuous score, request-rejection input, or operator-tunable memory admission knob in this slice
* scheduler memory eligibility SHALL continue to use the scheduler/model/node inputs defined elsewhere in this spec; Phase 4E promotes only the hard-coded `status_code = ok` plus `headroom_available = true` case to a non-excluding scheduler-ranking preference

Runtime prefix-cache wire semantics:

* `StatusResponse.runtime_prefix_cache_statuses` SHALL report observe-only aggregate prefix-cache snapshots for loaded runtime/model paths through the existing `GetStatus` probe
* `prefix_cache_scoring.ranking_mode` defaults to `:observe_only`; in observe-only mode Orchard MAY issue a bounded `ScorePrefixCache` RPC only for the already-selected candidate, after ranking, and at most once per request
* when `prefix_cache_scoring.ranking_mode = :tie_only`, Orchard MAY additionally score only the challenger in the leading rank-equivalence group (equal on existing ranking elements except final deterministic `node_id`), with total scored candidates capped at 2 per request (incumbent + challenger)
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
* in `:tie_only` mode, score MAY affect ranking only as a bounded conditional step before final deterministic `node_id`, only for the leading rank-equivalence group (all existing ranking elements equal except `node_id`), and only when an authoritative resident challenger (`status_code = "ok"`, `resident_fingerprint_match = true`, `score_tier = "resident_fingerprint"`) is compared against a comparable `ok` non-resident incumbent (`status_code = "ok"`, `resident_fingerprint_match = false`, `score_tier` is `"no_match"` or `"recent_fingerprint_only"`)
* in `:tie_only` mode, deterministic `node_id` ordering remains the fallback whenever promotion conditions are not met; any non-`ok`, timeout, `UNIMPLEMENTED`/`unsupported_version`, missing, malformed, or transport-failure score outcome for either incumbent or challenger SHALL preserve base order fail-open and SHALL never be surfaced as tenant-facing request errors
* controller persistence of selected prefix-cache diagnostics in `requests.scheduler_decision` SHALL be guarded by `orchard_controller.inference.cache_introspection.enabled`, which defaults to `false`; when disabled, prefix-cache fields SHALL be stripped before scheduler-decision persistence
* score-RPC collection SHALL be default-off behind `orchard_controller.inference.prefix_cache_scoring.enabled` (default `false`).
* when both `prefix_cache_scoring.enabled=true` and `cache_introspection.enabled=true`, the controller MAY persist only sanitized flat `selected_prefix_cache_score_*` scalars for the selected candidate; for non-`ok` score status only bounded status/tier/source diagnostics MAY persist.
* when `cache_introspection.enabled=true`, the controller SHALL persist only sanitized flat `selected_prefix_cache_*` scalars for the selected candidate and SHALL NOT persist the raw nested `prefix_cache_status` map; non-`ok` statuses SHALL persist only status code and enabled flag
* this Phase 4B/4C/4D contract is traceable to `orchard-workbench/plans/plan-mlx-phase4-worker-prefix-cache-introspection.md`, `orchard-workbench/plans/plan-mlx-phase4c-bounded-hmac-fingerprint-publication.md`, and `orchard-workbench/plans/plan-mlx-phase4d-score-prefix-cache-rpc.md`

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
* include exactly one terminal `Completed` or `Failed`
* stop emitting additional events after the terminal event
* preserve tool-call argument bytes exactly once tool-call emission has begun; stop-sequence handling SHALL NOT truncate tool-call JSON fragments
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
create type api_key_status as enum ('active', 'revoked', 'expired');
create type actor_type as enum ('user', 'service_account', 'api_key', 'node', 'system');
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

create table models (
  id uuid primary key default gen_random_uuid(),
  model_id text not null,
  version text not null,
  state model_catalog_state not null default 'registered',
  format text not null check (format in ('mlx', 'gguf')),
  capabilities jsonb not null default '{}'::jsonb,
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

create table service_accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenants(id),
  name text not null,
  description text,
  disabled_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table api_keys (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenants(id),
  service_account_id uuid references service_accounts(id),
  name text not null,
  key_prefix text not null unique,
  secret_hash bytea not null,
  status api_key_status not null default 'active',
  expires_at timestamptz,
  last_used_at timestamptz,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (tenant_id is not null and service_account_id is null)
    or
    (tenant_id is null and service_account_id is not null)
  )
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
  canonical_request jsonb not null,
  request_payload jsonb,
  response_payload jsonb,
  response_preview text,
  sampling_params jsonb not null default '{}'::jsonb,
  response_format jsonb not null default '{}'::jsonb,
  scheduler_decision jsonb,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  reserved_output_tokens integer not null default 0,
  first_token_at timestamptz,
  completed_at timestamptz,
  timeout_at timestamptz,
  http_status integer,
  error_code text,
  error_message text,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
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
  occurred_at timestamptz not null default now(),
  actor_type actor_type not null,
  actor_id text not null,
  tenant_id uuid references tenants(id),
  request_id uuid references requests(id),
  action text not null,
  resource_type text not null,
  resource_id text not null,
  outcome text not null,
  remote_addr inet,
  user_agent text,
  details jsonb not null default '{}'::jsonb
);
```

### 8.3 Supplemental governance tables

```sql
create table role_bindings (
  id uuid primary key default gen_random_uuid(),
  principal_type text not null check (principal_type in ('tenant', 'service_account', 'api_key')),
  principal_id uuid not null,
  role text not null check (role in ('admin', 'operator', 'tenant_admin', 'inference_client')),
  tenant_scope_id uuid references tenants(id),
  inserted_at timestamptz not null default now(),
  unique(principal_type, principal_id, role, tenant_scope_id)
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

### 8.4 Required indexes

```sql
create index idx_node_heartbeats_node_observed_at
  on node_heartbeats(node_id, observed_at desc);

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

create index idx_audit_logs_tenant_occurred_at
  on audit_logs(tenant_id, occurred_at desc);
```

### 8.5 Data retention defaults

* `node_heartbeats`: 7 days
* `request_events`: 30 days
* `requests`: 90 days metadata minimum
* `audit_logs`: 365 days minimum

Payload retention follows tenant capture mode.

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

Required metric families:

**HTTP/API**

* `orchard_http_requests_total{endpoint,method,status}`
* `orchard_http_request_duration_seconds_bucket{endpoint,status}`

**Inference**

* `orchard_inference_requests_total{endpoint,tenant,model,status}`
* `orchard_inference_request_duration_seconds_bucket{tenant,model,status}`
* `orchard_input_tokens_total{tenant,model}`
* `orchard_output_tokens_total{tenant,model}`
* `orchard_decode_tokens_per_second_bucket{model,node}`

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

### 10.2 API keys

Key format:

```text
orchard_sk_<prefix>_<secret>
```

Requirements:

* secret entropy: 32 random bytes minimum
* DB stores:

  * `key_prefix`
  * `secret_hash = sha256(secret)`
* comparison MUST be constant-time
* key secret displayed once only at creation
* revocation is immediate

### 10.3 Service accounts

Service accounts are non-interactive principals.
They may be:

* global
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

No implicit cross-tenant access.

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

Internal RPC SHALL use:

* TLS 1.3
* mutual TLS
* controller CA generated at cluster init or imported by admin
* SAN validation against node id / controller id
* certificate renewal before expiry

Node cert lifetime default:

* 90 days

Renewal threshold:

* 30 days before expiry

### 10.7 Public transport

Public APIs SHALL use HTTPS.
Certificates may be:

* operator-provided
* product-generated for local/test use only

### 10.8 Secrets at rest

Secrets SHALL be stored:

* in Postgres only as hashes, never plaintext
* private keys SHOULD be stored in macOS Keychain or protected filesystem paths
* bootstrap tokens stored only as hash

### 10.9 Audit requirements

Audit logs SHALL capture:

* tenant creation/update/suspend
* API key create/revoke
* service account changes
* quota changes
* model import/activate/retire
* routing policy changes
* node admission/decommission
* operator drain/cancel/retry actions
* support bundle generation
* upgrade actions

### 10.10 Data governance

Tenant setting `request_body_capture_mode`:

* `none`
* `metadata`
* `full`

Default = `metadata`

`none`:

* store hashes, usage, errors, no prompt/response text

`metadata`:

* store shape + preview + hashes

`full`:

* store full payloads and final outputs

---

## 11. Packaging and Deployment

The macOS-native packaging model SHALL use:

* **DMG** for interactive installs
* **PKG** for unattended/enterprise installs

Apple recommends notarization for directly distributed macOS software, and signed DMG or signed PKG are the preferred direct-distribution formats outside the App Store. ([Apple Developer][8])

### 11.1 Installed components

Required installed artifacts:

```text
/Applications/Orchard.app                    # tray/menu app
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

### 11.3 DMG contents

DMG SHALL include:

* `Orchard.pkg`
* `Orchard Installer.app` optional bootstrap UI
* release notes
* checksums/signature metadata

### 11.4 PKG behavior

PKG SHALL support:

* unattended `installer -pkg ... -target /`
* MDM deployment
* postinstall creation of launchd plists
* optional managed DB enablement
* optional controller-only or node-only install modes

Apple’s enterprise deployment guidance supports package distribution to managed Macs. ([Apple Support][9])

### 11.5 Managed Database Mode

Managed DB mode SHALL:

* run Postgres in a local container runtime on Apple Silicon
* bind only to loopback
* persist data under application support path
* expose health via `pg_isready`
* start before controller ready-state

Implementation choice:

* use Apple Containerization-based runtime, with the open-source `container` implementation acceptable as the packaged runtime interface

Apple’s Containerization project is a Swift package for Linux containers on macOS using Apple Silicon virtualization, and `container` is its CLI implementation. ([Apple Open Source][10])

### 11.6 External Database Mode

External DB mode SHALL support:

* PostgreSQL 16+
* TLS connections
* verify-full mode by default
* separate DSN for migrations optional
* configurable pool sizes
* no local Postgres helper service

### 11.7 Offline / air-gapped support

Air-gapped install SHALL support:

* offline PKG/DMG transfer
* offline model bundle import
* no required network egress
* manual update packages
* prepackaged container image tar for managed Postgres mode

Offline install flow:

1. transfer signed installer media and model bundles
2. install PKG
3. run `orchardctl cluster init`
4. import model bundles from removable media
5. bootstrap/join nodes via offline-generated token or imported certs

### 11.8 Tray/menu bar app

Tray app SHALL provide:

* local daemon status
* controller/node role display
* node join status
* recent errors
* open logs
* open support bundle wizard
* version/build info

### 11.9 CLI

Required commands:

* `orchardctl cluster init`
* `orchardctl node join`
* `orchardctl nodes list`
* `orchardctl nodes admit`
* `orchardctl models import`
* `orchardctl requests inspect`
* `orchardctl support bundle create`
* `orchardctl upgrade plan`

---

## 12. Failure Handling

### 12.1 Node failure

Detection:

* no heartbeat > 15s -> `unreachable`

Behavior:

* scheduler immediately excludes node
* active requests on node marked `interrupted` if stream already started
* if failure before first token and retryable, controller retries once on another node
* node remains in lifecycle state but health becomes `unreachable`

Recovery:

* on heartbeat resumption, health recalculated
* loaded placements may be reused after state refresh
* controller requests a full `GetStatus` before rescheduling node

### 12.2 Worker crash

Behavior:

* node agent marks affected worker `failed`
* in-flight request fails or retries if no token emitted
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
* if alternate node exists and no token emitted, retry once

Common error codes:

* `artifact_not_found`
* `checksum_mismatch`
* `insufficient_memory`
* `runtime_incompatible`
* `load_timeout`

### 12.4 Request timeout

Controller SHALL assign `timeout_at` at admission.

On timeout:

* if queued: remove and mark `timed_out`
* if running/streaming: send cancel to node
* if node fails to cancel within grace period, force kill worker
* usage charges only for tokens already emitted

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
* no auto-retry occurs after first token emitted
* no pinned placement is auto-evicted
* quota reservations are always released on terminal reconciliation

---

## 13. Upgrade Strategy

### 13.1 Versioning rules

* external REST API path version: `/v1`
* internal gRPC package version: `cluster.v1`
* schema migrations are forward-only
* controller version `N` MUST support node agent versions `N` and `N-1`
* node agent version `N` MUST support bundled worker version `N` only

### 13.2 Migration strategy

All DB migrations SHALL follow **expand / migrate / contract**.

Rules:

* additive columns/tables first
* new code reads both old and new where needed
* background backfill if required
* destructive drops only after all nodes/controllers run compatible version

Migration ownership SHALL be protected by advisory lock.

### 13.3 Controller upgrade

**Single-controller deployment**

1. stop public traffic or accept brief outage
2. backup config + DB
3. install new PKG
4. start controller
5. run migrations
6. wait for readiness

**HA-lite deployment**

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
3. install package
4. restart node agent
5. verify heartbeat + status sync
6. uncordon

This supports rolling worker-plane upgrades without full cluster downtime.

### 13.5 Worker upgrade

Workers are bundled with node agent.
Worker upgrade occurs via node agent package upgrade.
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

### Milestone 0 — Skeleton and packaging foundation

Deliver:

* umbrella repo
* controller release boots
* node agent release boots
* Postgres repo/migrations
* launchd plists
* DMG/PKG packaging skeleton
* `/health/live`, `/health/ready`

Acceptance:

* controller starts on macOS
* node agent starts on macOS
* PKG installs launchd services correctly

### Milestone 1 — Single-node inference MVP

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

### Milestone 2 — Responses API and governance core

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

### Milestone 3 — Node lifecycle and cluster join

Deliver:

* bootstrap token flow
* certificate join flow
* node registration
* heartbeats
* pools
* admission API
* cordon/drain/maintenance/decommission
* node status pages

Acceptance:

* second node joins cluster
* admin admits node
* health transitions behave as specified
* drain prevents new scheduling

### Milestone 4 — Multi-node scheduler and placements

Deliver:

* scheduler candidate filtering
* tiered scoring
* queueing
* model placements
* `EnsureModelLoaded`
* retries before first token
* scheduler explanation endpoint

Acceptance:

* requests land on best loaded node
* cached/cold tier behavior works
* automatic retry before first token works once
* scheduler explanation matches actual decision

### Milestone 5 — Observability and diagnostics

Deliver:

* Prometheus metrics
* OTel tracing
* structured logs
* node diagnostics endpoint
* support bundle creation
* recommended Grafana dashboards JSON

Acceptance:

* p95 latency visible in Grafana
* a request trace spans auth→schedule→execute→stream
* support bundle contains logs, config, node snapshots, request summary

### Milestone 6 — Security hardening and air-gap

Deliver:

* mTLS internal RPC
* cert renewal
* key rotation
* retention modes
* offline model import workflow
* managed Postgres container mode
* PKG unattended install flow

Acceptance:

* node join via bootstrap produces signed cert
* internal gRPC rejects non-mTLS clients
* air-gapped installation completes with no internet access

### Milestone 7 — Upgrade safety and HA-lite controller

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

---

This spec defines the v1 platform contract. The coding agent should implement it in milestone order, preserving wire compatibility and state-machine behavior exactly as written where fields, states, and transitions are explicitly defined.

[1]: https://developers.openai.com/api/docs/guides/migrate-to-responses/ "https://developers.openai.com/api/docs/guides/migrate-to-responses/"
[2]: https://support.apple.com/guide/terminal/script-management-with-launchd-apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac "https://support.apple.com/guide/terminal/script-management-with-launchd-apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac"
[3]: https://github.com/ml-explore/mlx "https://github.com/ml-explore/mlx"
[4]: https://www.postgresql.org/docs/current/explicit-locking.html "https://www.postgresql.org/docs/current/explicit-locking.html"
[5]: https://developers.openai.com/api/reference/resources/models/methods/list/ "List models | OpenAI API Reference"
[6]: https://developers.openai.com/api/docs/guides/streaming-responses/ "https://developers.openai.com/api/docs/guides/streaming-responses/"
[7]: https://opentelemetry.io/docs/languages/erlang/ "https://opentelemetry.io/docs/languages/erlang/"
[8]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution "https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution"
[9]: https://support.apple.com/en-sg/guide/deployment/dep873c25ac4/web "https://support.apple.com/en-sg/guide/deployment/dep873c25ac4/web"
[10]: https://opensource.apple.com/projects/containerization "https://opensource.apple.com/projects/containerization"
