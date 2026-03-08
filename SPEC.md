# Sovereign On-Prem LLM Orchestration Platform — Technical Specification

This document is a normative implementation spec for a sovereign LLM orchestration platform optimized for **1–4 Apple Silicon macOS nodes**. It is intended for a coding agent that will build the system incrementally. “MUST”, “SHALL”, and “MUST NOT” are mandatory requirements. “SHOULD” is a strong recommendation.

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
* hosted tool execution by the platform
* internet-dependent control plane behavior
* dynamic autoscaling
* active/active multi-controller consensus

---

## 2. Component Overview

### 2.1 Controller components

| Component           | Process type         | Responsibility                                               |
| ------------------- | -------------------- | ------------------------------------------------------------ |
| `sov-controller`    | launchd LaunchDaemon | Main control plane daemon                                    |
| `Sov.API`           | OTP app              | HTTP API surface: `/v1`, `/ops/v1`, `/admin/v1`              |
| `Sov.Auth`          | OTP app              | API key auth, service account auth, RBAC                     |
| `Sov.Admission`     | OTP app              | validation, tenant policy, quotas, idempotency               |
| `Sov.Scheduler`     | OTP app              | node selection, queueing, fairness, placement decisions      |
| `Sov.Dispatch`      | OTP app              | gRPC calls to node agents, stream fan-out to clients         |
| `Sov.Catalog`       | OTP app              | model catalog, artifact manifests, routing policy resolution |
| `Sov.Nodes`         | OTP app              | node registry, lifecycle, heartbeat snapshots                |
| `Sov.Requests`      | OTP app              | per-request FSMs and request event logging                   |
| `Sov.Observability` | OTP app              | metrics, traces, logs                                        |
| `Sov.Governance`    | OTP app              | tenants, quotas, keys, audit logs                            |

### 2.2 Node-side components

| Component               | Process type         | Responsibility                                   |
| ----------------------- | -------------------- | ------------------------------------------------ |
| `sov-node-agent`        | launchd LaunchDaemon | Node control endpoint                            |
| `SovNode.Register`      | OTP app              | join, cert renewal, heartbeat                    |
| `SovNode.Models`        | OTP app              | artifact cache, verification, load/unload        |
| `SovNode.Workers`       | OTP app              | worker supervisor, crash recovery                |
| `SovNode.Diagnostics`   | OTP app              | health and support data                          |
| `sov-worker-supervisor` | spawned child        | manages one or more worker runtime processes     |
| `sov-worker-mlx`        | spawned child        | MLX runtime server for one loaded model instance |

### 2.3 End-user and operator components

| Component               | Packaging                    | Responsibility                                             |
| ----------------------- | ---------------------------- | ---------------------------------------------------------- |
| Tray/menu bar app       | `.app` + LaunchAgent         | local status, onboarding, logs, support bundle entry point |
| `sovctl` CLI            | binary                       | admin/operator automation, bootstrap, diagnostics          |
| Managed Postgres helper | LaunchDaemon in managed mode | local DB lifecycle only                                    |

### 2.4 Repository structure

The implementation SHOULD use an umbrella repository with separate Elixir releases:

```text
/apps
  /sov_shared        # protobufs, common structs, config parsing
  /sov_controller    # controller release
  /sov_node_agent    # node agent release
  /sov_cli           # CLI
/native
  /sov_worker_mlx    # python runtime adapter
  /sov_tokenizer     # tokenizer/render helper
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
SovController.Application
├─ Sov.Repo
├─ Sov.CacheSupervisor
│  ├─ Sov.Cache.ApiKeys
│  ├─ Sov.Cache.Models
│  ├─ Sov.Cache.Tenants
│  └─ Sov.Cache.NodeSnapshots
├─ Sov.API.Endpoint
├─ Sov.RPC.ControllerServer
├─ Sov.RPC.NodeClientPool
├─ Sov.RequestSupervisor
├─ Sov.Scheduler.Supervisor
│  ├─ Sov.Scheduler.QueueManager
│  ├─ Sov.Scheduler.Dispatcher
│  └─ Sov.Scheduler.PlacementReconciler
├─ Sov.NodeSupervisor
├─ Sov.AuditSupervisor
├─ Sov.Observability.Supervisor
└─ Sov.LeaderTasks
   ├─ Sov.Leader.LockManager
   ├─ Sov.Leader.RetentionSweeper
   ├─ Sov.Leader.QuotaSweeper
   └─ Sov.Leader.SupportBundleManager
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
    tool_choice: map() | String.t() | nil
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

### 3.5 Prompt rendering and tokenization

The controller SHALL perform **exact prompt rendering and exact token counting before scheduling**.

Implementation requirement:

* bundle a helper executable `sov-tokenizer`
* it MUST support:

  * tokenizer.json
  * SentencePiece tokenizer.model
  * chat template rendering
  * token count for final rendered prompt

The controller SHALL reject requests when:

* `input_tokens + max_output_tokens > model.max_context_tokens`
* request contains unsupported message/item types
* tokenizer assets for the selected model are missing or invalid

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
* hosted tools
* `json_schema`
* `parallel_tool_calls=true`

Streaming behavior:

* SSE
* emit chunks as `chat.completion.chunk`
* final line `[DONE]`
* if `stream_options.include_usage=true`, emit final usage chunk before `[DONE]`

If an error occurs **after** streaming has started:

* emit `data: {"error":{...}}`
* close stream
* do not emit `[DONE]`

#### 7.2.5 `POST /v1/responses`

Supported request fields:

* `model`
* `input` string or text message items
* `instructions`
* `temperature`
* `top_p`
* `max_output_tokens`
* `stop`
* `stream`
* `metadata`
* `tools` (function only)
* `tool_choice`
* `store`

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

Streaming behavior:

* SSE with typed events
* required emitted events:

  * `response.created`
  * `response.output_text.delta`
  * `response.output_text.done`
  * `response.completed` or `response.failed`

The Responses API in OpenAI’s current documentation uses typed semantic streaming events; this platform SHALL mirror that model for the supported subset. ([OpenAI Developers][6])

`store` behavior in this platform:

* accepted for compatibility
* does **not** disable internal accounting/audit metadata
* when `store=false`, full prompt/response payload retention SHALL follow tenant retention policy and default to redacted metadata only

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
  "key_prefix": "sov_kp_01J...",
  "secret": "sov_sk_01J....<secret>",
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
  rpc RunDiagnostics(RunDiagnosticsRequest) returns (RunDiagnosticsResponse);
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

message EnsureModelLoadedRequest {
  string node_id = 1;
  string model_id = 2;
  string version = 3;
  string artifact_sha256 = 4;
  bool preload = 5;
  uint64 deadline_unix_ms = 6;
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
```

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
* include terminal `Completed` or `Failed`
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

* `sov_http_requests_total{endpoint,method,status}`
* `sov_http_request_duration_seconds_bucket{endpoint,status}`

**Inference**

* `sov_inference_requests_total{endpoint,tenant,model,status}`
* `sov_inference_request_duration_seconds_bucket{tenant,model,status}`
* `sov_input_tokens_total{tenant,model}`
* `sov_output_tokens_total{tenant,model}`
* `sov_decode_tokens_per_second_bucket{model,node}`

**Scheduler**

* `sov_scheduler_decisions_total{result,tier}`
* `sov_scheduler_duration_seconds_bucket`
* `sov_scheduler_queue_depth{tenant}`
* `sov_scheduler_rejections_total{reason}`

**Node/runtime**

* `sov_node_heartbeat_lag_seconds{node}`
* `sov_node_available_memory_bytes{node}`
* `sov_node_swap_used_bytes{node}`
* `sov_active_requests{node,model}`
* `sov_model_load_duration_seconds_bucket{node,model}`
* `sov_model_resident{node,model}`
* `sov_worker_crashes_total{node,model}`

**Quotas/governance**

* `sov_quota_rejections_total{tenant,reason}`
* `sov_api_key_auth_failures_total`
* `sov_audit_events_total{action,outcome}`

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
sov_sk_<prefix>_<secret>
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
/Applications/SovereignAI.app                    # tray/menu app
/usr/local/bin/sovctl                           # CLI
/Library/Application Support/SovereignAI/
  config/
  data/
  models/
  bundles/
  logs/
  support/
/Library/LaunchDaemons/com.sovereignai.controller.plist
/Library/LaunchDaemons/com.sovereignai.node-agent.plist
/Library/LaunchDaemons/com.sovereignai.postgres.plist   # managed DB mode only
/Library/LaunchAgents/com.sovereignai.tray.plist
```

### 11.2 launchd services

System daemons:

* `com.sovereignai.controller`
* `com.sovereignai.node-agent`
* `com.sovereignai.postgres` (optional)

User agent:

* `com.sovereignai.tray`

Apple documents launchd as the daemon/agent manager on macOS, and distinguishes user agents from daemons. ([Apple Support][2])

Required launchd properties:

* `RunAtLoad = true`
* `KeepAlive = true`
* stdout/stderr redirected to product log path
* restart throttling enabled
* dedicated non-root service user preferred

### 11.3 DMG contents

DMG SHALL include:

* `SovereignAI.pkg`
* `SovereignAI Installer.app` optional bootstrap UI
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
3. run `sovctl cluster init`
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

* `sovctl cluster init`
* `sovctl node join`
* `sovctl nodes list`
* `sovctl nodes admit`
* `sovctl models import`
* `sovctl requests inspect`
* `sovctl support bundle create`
* `sovctl upgrade plan`

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

`s o v c t l upgrade plan` SHALL validate:

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
* `sovctl upgrade plan`

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
