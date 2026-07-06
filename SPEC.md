# Orchard v2 - Technical Specification

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

3. **Active/Standby control plane**

   * 2 controller instances maximum
   * exactly 1 active leader at a time
   * remains within the overall 1–4 Mac deployment limit
   * active/standby coordination via Postgres advisory lock
   * requires external VIP, reverse proxy, or operator-managed endpoint failover

### 1.2 Core design rules

* No Kubernetes.
* No active/active controller mode in v1.
* All durable state SHALL live in Postgres.
* Controller runtime execution SHALL use the Runtime Endpoint Interface.
* Runtime Endpoint semantics are transport-independent.
* The gRPC/protobuf `NodeRuntimeService` remains the compatibility transport and a candidate protocol for future non-BEAM adapters.
* First-party Orchard Controller and Node Agent source-dev services SHALL use BEAM Distribution as the default live Controller-to-Node Agent Runtime Endpoint transport when the endpoint is an admitted first-party Orchard service.
* Source-dev split-role `bin/dev-controller` and `bin/dev-node-agent` SHALL default to BEAM Runtime Endpoint transport when `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` is unset.
* Source-dev gRPC compatibility remains available on port `50071` through explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
* Accepted two-Mac smoke evidence SHALL remain recorded before and after BEAM Runtime Endpoint transport is promoted as the source-dev default.
* When BEAM Runtime Endpoint transport is selected, Orchard MUST NOT retry the same request through gRPC compatibility as an automatic fallback.
* Console live runtime diagnostics SHALL use the configured Runtime Endpoint target list; explicit BEAM Runtime Endpoint targets SHALL take precedence over legacy gRPC runtime client targets.
* Production BEAM Distribution MUST be explicitly enabled, identity-bound, network-restricted, and fail closed when required admission configuration is missing.
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
                     | durable DB  |   | - current gRPC compatibility|
                     +------------ +   | - default-off BEAM          |
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
| Orchard Console         | controller LiveView          | local/operator UI for runtime status, node inventory and admission review, action previews, requests, Organizations, API Tokens, and API Clients |
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

The controller SHALL be a Phoenix/Plug HTTP service plus Runtime Endpoint clients and the configured internal service ingress for node lifecycle and compatibility transports.

**Required listeners**

* Public/admin/operator API listener according to the configured public transport mode (§10.7):
  * `direct_https`: controller terminates HTTPS, default `:8443`.
  * `reverse_proxy`: controller provides a local/private HTTP backend for an operator-managed TLS-terminating proxy.
  * `plain_http_localhost`: controller provides loopback HTTP only for local development or break-glass recovery.
* `:8444` gRPC/mTLS for node registration/heartbeat/event ingress while the compatibility transport remains enabled
* `:9464` Prometheus metrics endpoint

**Required readiness conditions**

* Postgres reachable
* migrations current
* model/tenant/key caches loaded
* if Active/Standby mode enabled: instance is leader for write paths

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
    max_active_requests: pos_integer() | nil,
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

Tokenizer contract v3 adds controller-authoritative prompt token IDs for safe-tokenization-capable workers. When controller safe tokenization produces `prompt_token_ids`, capable workers must use those IDs directly rather than re-encoding rendered prompt text. Manifest compatibility trust remains governed by §6.4 and the runtime manifest-trust configuration; worker capability is advertised by the worker, not by the manifest.

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
  * conditions: inventory captured, trust established, pool assigned, required policy inputs supplied

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

* heartbeat interval: **2000 ms**
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

### 4.6.1 Runtime Endpoint capability and readiness observation

Hosted-tool observation SHALL remain distinct from heartbeat inventory in the current implementation slice.

Rules:

* the durable implementation seam for runtime status SHALL be a Runtime Endpoint Observation produced through the Runtime Endpoint Interface
* the current gRPC Compatibility Adapter SHALL derive Runtime Endpoint Observations from `NodeRuntimeService.GetStatus` returning `StatusResponse`
* heartbeat payloads MAY carry equivalent hosted-tool data in a later slice, but controller-owned hosted-tool observation SHALL currently be derived from Runtime Endpoint status-probe ingestion
* this contract defines future hosted routing inputs only; it SHALL NOT by itself enable controller-owned hosted `/v1/responses` execution or any other hosted execution behavior
* Runtime Endpoint Observations are observational until reconciled to a trusted Node
* unregistered observations MAY update Runtime Endpoint Admission Candidate metadata only
* unregistered observations SHALL NOT update Node lifecycle state
* unregistered observations SHALL NOT refresh queue capacity sources
* gRPC and BEAM Runtime Endpoint Observations SHALL affect scheduling only after the target identity resolves to a persisted trusted Node

Hosted-tool observation vocabulary:

* **static capability** identifies a node-advertised hosted tool by registry-compatible `name` and `version`, plus the local `adapter_kind`
* **dynamic readiness** reports whether that same advertised hosted tool is currently ready on the node, with `ready`, `readiness_code`, and `readiness_message`
* the controller SHALL derive canonical hosted-tool identity as `tool://<name>@<version>`
* hosted-tool identity SHALL align with controller registry semantics; Orchard SHALL NOT introduce a second hosted-tool naming scheme

Compatibility and defaulting rules:

* absent hosted-tool capability/readiness fields on a Runtime Endpoint Observation SHALL mean the endpoint advertises no hosted tools
* absent hosted-tool capability/readiness fields SHALL NOT be treated as a status-probe error
* readiness without matching advertised capability for the same `tool://<name>@<version>` SHALL NOT make the node eligible for hosted routing
* `supports_prompt_token_ids` indicates that the endpoint's loaded worker can accept controller-supplied prompt token IDs on the runtime execution request. Absence or `false` is treated as legacy capability, not as a probe failure. When `tokenizer_safe_mode_prefer_capable=true` and `tokenizer_safe_mode` is not `:off`, this live status-probe field MAY inform opt-in scheduler preference only; it is not dispatch authority.
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
* `max_concurrency` on the current gRPC compatibility `StatusResponse` SHALL report the aggregate runtime request capacity enforced by the node agent; omitted or zero values SHALL be treated conservatively as endpoint node capacity `1` by schedulers
* absent or empty Placement Capacity on a Runtime Endpoint Observation, including absent or empty `runtime_model_placements` on the current gRPC compatibility `StatusResponse`, SHALL mean no explicit per-placement capacity observation is available
* absent or empty Placement Capacity SHALL NOT be treated as a status-probe error
* Placement Capacity entries SHALL report controller-observed capacity for loaded Model Placements using model reference, active request count, and max concurrency; `max_concurrency <= 0`, malformed entries, duplicate matching entries, or non-matching entries SHALL be treated as unknown capacity
* valid per-placement capacity SHALL NOT prove endpoint eligibility when known aggregate node-level `active_request_count >= max_concurrency`
* unknown Placement Capacity SHALL NOT prove scheduler eligibility for an already-active endpoint; `Orchard.Scheduler.MultiNode` MAY keep a matching loaded-model active candidate eligible only when exactly one valid matching Placement Capacity entry reports `active_request_count < max_concurrency`

Effective readiness rules for future hosted routing:

* a node candidate is effectively ready for a hosted tool only when the controller registry contains an active tool with matching `name` and `version`
* the registry tool `execution_mode` SHALL be `:server_hostable`
* the node SHALL advertise matching static hosted-tool capability for the same `tool://<name>@<version>`
* the node lifecycle state SHALL be `active`
* node health SHALL be `healthy` or `degraded`
* the Runtime Endpoint Observation SHALL be fresh under Orchard's existing freshness thresholds
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
* expose the current gRPC Runtime Endpoint compatibility service
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
* on failure before first token:

  * reserved output tokens fully released
* on partial failure after streaming starts:

  * already emitted output tokens remain charged
  * unused reserved output tokens released

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

Queue lane capacity SHALL be the configured base lane capacity plus live capacity sources.
Valid loaded-placement observations MAY add source-scoped capacity for the matching model/version lane.
Eligible cold/no-placement node observations MAY add conservative source-scoped capacity for queued model/version lanes, bounded by aggregate node concurrency and by one unreserved cold slot per lane per node observation.
Live capacity source refreshes SHALL be allowed to wake queued requests without a new admission event.
Stale, unavailable, non-loaded, invalid, exhausted, ineligible, or transport-failed node and placement observations SHALL NOT inflate queue admission capacity and SHALL clear any stale capacity source owned by that node or target.
BEAM Runtime Endpoint observations MAY refresh queue capacity only when the target resolves back to the same persisted node identity; address-only or mismatched BEAM observations SHALL NOT publish queue capacity.
Runtime Endpoint Admission Candidates SHALL NOT publish queue lane capacity.
Queue lane capacity SHALL come only from trusted active Nodes or Runtime Endpoints resolved to trusted active Nodes.

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

Runtime Endpoint Admission Candidates are never eligible nodes.
Unresolved, untrusted, rejected, provisioned, registered, or admitted-but-not-active candidates and Nodes SHALL be excluded before candidate tiering and scoring.

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

Endpoint node concurrency is not exceeded only when the live Runtime Endpoint Observation reports aggregate `active_request_count < max_concurrency`.
If aggregate `max_concurrency` is omitted or zero, schedulers SHALL interpret endpoint node capacity as `1`.
Model placement concurrency is evaluated independently through valid matching Placement Capacity.
Both endpoint-level aggregate capacity and requested-placement capacity must remain available for a loaded candidate to be eligible.
Scheduler decisions MAY include `queue_lane_capacity` when live loaded-placement capacity or eligible cold Runtime Endpoint capacity leaves room for the requested lane.
Loaded candidate contribution SHALL be constrained by both requested-placement capacity and aggregate endpoint capacity.
Cold candidate contribution SHALL count only candidates with remaining aggregate endpoint capacity.
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

Controller-side cache-affinity, safe-tokenization capable-worker preference, Phase 4D tie-only scoring, and memory-admission ranking for the bounded current implementation SHALL use the following late tie-break order among otherwise schedulable candidates in the same residency/load/health position:

1. loaded model already present
2. lower active request count for the requested placement when valid matching Placement Capacity is available, otherwise lower endpoint aggregate `active_request_count`
3. healthier node (`healthy` before `degraded`)
4. live prefix-cache fingerprint match, only when both `cache_affinity.enabled=true` and `cache_affinity.live_fingerprint_match_enabled=true`
5. historical cache-affinity match from recent completed placements, when cache affinity is enabled
6. safe-tokenization capable-worker preference, only when `tokenizer_safe_mode_prefer_capable=true`, `tokenizer_safe_mode` is not `:off`, and the live status probe reports `supports_prompt_token_ids=true`
7. explicit memory-headroom observation, only when `memory_admission.enabled=true` and the candidate's matching `RuntimeMemoryBudget` has `status_code = "ok"` and `headroom_available = true`
8. lexicographically smaller `node_id`

Default Phase 4D runtime behavior remains observe-only (`prefix_cache_scoring.ranking_mode = :observe_only`) and rank-neutral.

When `prefix_cache_scoring.enabled=true`, `cache_affinity.enabled=true`, `cache_affinity.live_fingerprint_match_enabled=true`, and `prefix_cache_scoring.ranking_mode = :tie_only`, the scheduler MAY apply one bounded conditional score step immediately before step 8, only for the leading rank-equivalence group where steps 1–7 are equal and only deterministic `node_id` differs. Candidate scoring in this conditional step is capped at 2 (incumbent + challenger). The challenger MAY be promoted only when challenger score normalizes to `status_code = "ok"` with `resident_fingerprint_match = true` and `score_tier = "resident_fingerprint"`, and the incumbent score is comparable `ok` non-resident (`status_code = "ok"`, `resident_fingerprint_match = false`, and `score_tier` is `"no_match"` or `"recent_fingerprint_only"`). Any non-`ok`, timeout, unsupported, unavailable, `model_not_loaded`, `invalid_request`, missing, malformed, contradictory, or transport-failure score outcome for either candidate SHALL preserve base order fail-open and deterministic `node_id` fallback.

A live prefix-cache fingerprint match is a bounded, approximate warmth hint. It SHALL bias ranking only after health and before historical affinity. Safe-tokenization capable-worker preference is default-off and SHALL bias ranking only after live and historical cache-affinity signals and before memory-headroom admission. The memory-headroom observation is a bounded, positive-only hint. It SHALL bias ranking only after live cache-affinity, historical cache-affinity, and any enabled safe-tokenization capable-worker preference, and before deterministic `node_id`; candidates with absent, malformed, unavailable, or non-`ok` memory-budget telemetry remain schedulable and rank-neutral. Neither hint SHALL change node eligibility, request admission, queue ordering, public error contracts, or runtime concurrency.

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

Runtime Endpoint disconnect and channel cleanup failures are cleanup-only failures.
They SHALL be logged best-effort and MUST NOT overwrite an otherwise successful scheduler probe or dispatch result.

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
  memory sample SHALL NOT fail a generation on its own. Pressure is sampled per
  backend decode event only; prefill is not interruptible, so a request already
  in prefill is not aborted mid-prefill. Admission-time memory gating is deferred
  follow-up work (issue #68).

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
   * HTTPS JSON + SSE for public/client traffic in `reverse_proxy` and `direct_https` transport modes
   * loopback HTTP only in degraded `plain_http_localhost` mode for local development or break-glass recovery
   * bearer API keys

2. **Operator API**

   * runtime operations
   * HTTPS JSON for public/operator traffic in `reverse_proxy` and `direct_https` transport modes
   * loopback HTTP only in degraded `plain_http_localhost` mode for local development or break-glass recovery
   * operator/admin auth

3. **Admin API**

   * governance/configuration
   * HTTPS JSON for public/admin traffic in `reverse_proxy` and `direct_https` transport modes
   * loopback HTTP only in degraded `plain_http_localhost` mode for local development or break-glass recovery
   * admin/tenant-admin auth

4. **Runtime Endpoint and Worker Interfaces**

   * controller↔Runtime Endpoint Interface for model readiness, inference execution, cancellation, status, runtime telemetry, and Placement Capacity
   * current first implementation uses the gRPC Compatibility Adapter over mTLS
   * Worker Runtime Interface remains local to the Node Agent

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

The internal runtime `TokenDelta` capability (§7.5.3 internal token-streaming wire semantics) SHALL NOT expose `logprobs` or `top_logprobs` on the public `/v1` API in v1; the restriction above remains in force regardless of that internal capability.

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
* `503` cluster busy / model busy / no eligible node
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

Operator API requests SHALL authenticate with a service-account-owned API Token whose owning API Client is enabled and holds a cluster-scoped `operator` or `admin` RoleBinding.
Tenant-direct API Keys, tenant-scoped Access Levels, and public inference credentials SHALL NOT authorize Operator API access and SHALL fail closed.
Missing or invalid credentials SHALL return `401 invalid_api_key`; authenticated non-operator principals SHALL return `403 operator_required`.

Eligibility-changing or destructive Operator and Admin node actions SHALL provide an Action Preview before execution.
Action Previews SHALL be side-effect-free and SHALL NOT create domain rows, audit events, or Node Admission Decisions unless a future preview-audit contract explicitly says otherwise.
The preview response SHALL separate `blockers`, `warnings`, `consequence_codes`, and `confirmation_requirements`.
Blocker, warning, consequence, and confirmation requirement codes SHALL be stable machine-readable identifiers shared by Admin API, Operator API, CLI, Console, support bundles, and tests.
Blockers are non-bypassable safety, permission, leadership, write-path, lifecycle, or data-integrity constraints.
Warnings are advisory and MAY require confirmation.
Consequence codes describe expected effects accepted only through explicit parameters or confirmation requirements.
Confirmation requirements are explicit acknowledgements or typed values and MUST NOT bypass blockers.
Action execution SHALL revalidate permissions, leadership and write-path availability, lifecycle state, health, active request count when relevant, and blockers at mutation time.

`POST /ops/v1/support-bundles` SHALL produce the `orchard.support_bundle.v2` format for cluster-management evidence.
Support Bundle v2 SHALL include bundle format, generated time, Orchard version, scope, included sections, omitted sections, redaction manifest, max log bytes, and relevant SPEC references.
Supported scopes SHALL include `cluster`, `node`, `request`, `scheduler_decision`, `runtime_endpoint`, `control_plane`.
v1 compatibility MAY remain only if it is documented separately and does not satisfy or weaken v2 manifest or redaction requirements.

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
      "reason_codes": []
    }
  ],
  "rejected_candidates": [
    {
      "node_id": "node-1",
      "reason_codes": ["node_not_active", "insufficient_memory"]
    }
  ],
  "skipped_candidates": [
    {
      "node_id": "node-3",
      "reason_codes": ["lower_tier_not_considered"]
    }
  ]
}
```

Scheduler explanations SHALL expose stable reason codes for selected, rejected, and skipped candidates.
Reason codes SHALL be shared by Operator API, CLI, Console, support bundles, and tests.
Human-readable explanation text MAY be included, but it SHALL be supplemental to machine-readable reason codes.
Rejected candidates SHALL include at least one stable rejection reason code.
Skipped candidates SHALL be represented in `skipped_candidates` outside the rejected-candidate list and SHALL include at least one stable skip reason code.
The initial scheduler rejection vocabulary SHALL include `inventory_missing`, `node_not_admitted`, `node_not_active`, `node_not_registered`, `node_health_unreachable`, `node_health_unhealthy`, `node_observation_stale`, `transport_unreachable`, `runtime_not_ready`, `runtime_identity_mismatch`, `version_incompatible`, `pool_not_allowed`, `model_format_unsupported`, `model_not_available_on_node`, `insufficient_memory`, `node_concurrency_exhausted`, `placement_concurrency_exhausted`, `placement_suppressed`, `node_circuit_breaker_open`, `model_load_suppressed`, `policy_required`, `pool_required`, `queue_lane_capacity_unavailable`, `trust_not_established`, and `unknown_capacity`.
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
  "token_prefix": "orchard_kp_01J...",
  "secret": "orchard_sk_01J....<secret>",
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
The `organization` field SHALL identify one Organization slug per input file.
Plaintext API Token secrets SHALL NOT be accepted in input.
Dry Run SHALL validate Organizations, API Client identity, duplicate API Token names, optional expiry values, metadata JSON, and output destination readiness without mutating state or generating secrets.
Apply SHALL validate the output path before mutation and commit all provisioning changes as one batch.
Apply SHALL write One-time Secret Output only after the batch succeeds.
One-time Secret Output SHALL be a CSV with `organization`, `api_client`, `external_ref`, `key_name`, `api_token_id`, `api_token_prefix`, `api_token`, and `expires_at` columns.
If One-time Secret Output delivery fails after a committed Apply, Orchard SHALL mark the Provisioning Batch as `output_failed`, write a redacted audit event, and return recovery guidance that names API Token prefixes for revocation or rotation.
The output-failed recovery path SHALL NOT persist plaintext API Token secrets.
Repeated provisioning SHALL match API Clients by Organization plus External Reference when present, otherwise by Organization plus API Client name.
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

### 7.5 Runtime Endpoint and Internal Worker Interfaces

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
  // Aggregate runtime request capacity for the node.
  // Controllers must treat absent or zero values as node capacity 1.
  uint32 max_concurrency = 12;
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
* if a request completes successfully after emitting one or more tool-call deltas, the terminal `Completed.finish_reason` SHALL be `FINISH_REASON_TOOL_CALLS`

Internal token-streaming wire semantics:

* `ExecuteInferenceRequest.return_token_ids` and `ExecuteInferenceRequest.return_logprobs` are opt-in internal runtime capabilities; both default to false (omitted) and gate emission of `TokenDelta`
* `TokenDelta` SHALL be emitted only when the request opts in; when neither flag is set no `TokenDelta` is emitted and behavior is unchanged
* `TokenDelta.token_ids` carries raw sampled token IDs; `TokenDelta.logprobs`, when requested and available, aligns index-wise with `token_ids`
* raw sampled `TokenDelta.token_ids` MAY NOT align 1:1 with detokenized `OutputTextDelta` text deltas
* `TokenDelta` SHALL NOT be emitted after the terminal `Completed`/`Failed` event
* token-ID and logprob emission is fail-open: an unavailable or failed logprob source SHALL degrade to omitted `logprobs` and SHALL NOT fail the generation
* this is an internal runtime wire capability only; it is NOT exposed through the public `/v1` API, and the §7.2.4 public-API restriction on `logprobs`/`top_logprobs` remains in force in v1

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
* `prefix_cache_scoring.ranking_mode` defaults to `:observe_only`; in observe-only mode Orchard MAY issue a bounded `ScorePrefixCache` RPC only for the already-selected candidate, after ranking, and at most once per request
* when `prefix_cache_scoring.ranking_mode = :tie_only`, Orchard MAY additionally score only the challenger in the leading rank-equivalence group (equal on current ranking elements except final deterministic `node_id`, including any enabled safe-tokenization capable-worker preference), with total scored candidates capped at 2 per request (incumbent + challenger)
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
* `StatusResponse.max_concurrency` SHALL report the aggregate runtime request capacity that the node agent will enforce across loaded models
* omitted or zero `StatusResponse.max_concurrency` SHALL mean aggregate capacity is unknown or legacy; schedulers SHALL treat it conservatively as node capacity `1`
* Runtime Endpoint Observations SHALL report active request count and max concurrency for each loaded runtime/model path as Placement Capacity
* the current gRPC Compatibility Adapter maps Placement Capacity to and from `StatusResponse.runtime_model_placements` through the existing `GetStatus` probe
* omitted or empty Placement Capacity SHALL mean no explicit per-placement capacity observation is available
* omitted or empty Placement Capacity SHALL NOT be treated as an endpoint status error, readiness failure, admission failure, model-admission failure, or scheduler-eligibility failure for otherwise idle candidates
* a matching placement capacity observation is valid only when exactly one entry matches the requested `model_ref`, `active_request_count >= 0`, and `max_concurrency > 0`
* duplicate matching entries, malformed matching entries, non-matching entries, or `max_concurrency <= 0` SHALL make placement capacity unknown for that request
* a valid matching placement observation SHALL NOT override exhausted node-level aggregate capacity
* unknown placement capacity SHALL NOT prove eligibility for an already-active loaded-model candidate; an already-active loaded-model candidate MAY remain eligible only when exactly one valid matching entry reports `active_request_count < max_concurrency`
* when multiple eligible candidates remain, the scheduler SHALL rank by the requested placement's active request count before health when a valid matching placement observation is available; otherwise it SHALL use the endpoint aggregate `active_request_count`
* controller queue capacity MAY be refreshed from Runtime Endpoint Observations; loaded placement observations contribute only to their matching model/version lane, while cold/no-placement endpoint observations contribute conservative source-scoped capacity for queued lanes without exceeding aggregate endpoint capacity
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
  name text not null,
  token_prefix text not null unique,
  secret_hash bytea not null,
  expires_at timestamptz,
  last_used_at timestamptz,
  revoked_at timestamptz,
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
  updated_at timestamptz not null default now(),
  check (principal_type <> 'service_account' or service_account_id is not null)
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
  api_key_id uuid references api_keys(id) on delete set null,
  actor_type actor_type not null,
  actor_id text,
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
Node admission candidate review, node admission rejection, rejection clearance, admission after rejection, node decommission, Active/Standby status-affecting writes, and cluster-scoped support bundle generation SHALL use cluster-scoped audit events unless a future accepted contract makes them tenant-owned.
Audit log `actor_type` SHALL identify the provenance class of the action.
`operator` represents operator and admin product surfaces such as Orchard Console, Orchard CLI, Operator API, and Admin API actions.
`actor_id` MAY be null for `system` actions and for local operator actions before Orchard has an authenticated first-class operator identity.
Audit log `payload` MAY include `surface` to preserve the originating product surface, for example `console` or `cli`, when that context is useful for governance review.

### 8.3 Supplemental governance tables

```sql
create table role_bindings (
  id uuid primary key default gen_random_uuid(),
  principal_type text not null check (principal_type in ('tenant', 'service_account', 'api_key')),
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

  * `token_prefix`
  * `secret_hash = sha256(secret)`
* comparison MUST be constant-time
* key secret displayed once only at creation
* revocation is immediate
* plaintext secrets MUST NOT be stored in Postgres, audit logs, provisioning batches, support bundles, or durable local evidence artifacts

Tenant-direct API Keys SHALL remain supported for manual, bootstrap, and compatibility paths.
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

Certificate-backed node lifecycle RPC and current gRPC compatibility transports SHALL use:

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
* private keys SHOULD be stored in macOS Keychain or protected filesystem paths
* bootstrap tokens stored only as hash

### 10.9 Audit requirements

Audit logs SHALL capture:

* tenant creation/update/suspend
* API key create/revoke
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
* operator drain/cancel/retry actions
* support bundle generation
* upgrade actions

Audit payloads SHALL exclude plaintext API Token secrets.
Provisioning Batch records SHALL include non-secret counts, status, input hash, timestamps, and sanitized error summaries only.
Observed target references and admission-candidate metadata in audit payloads SHALL be sanitized and MUST NOT include secrets.

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

PKG `postinstall` SHALL NOT generate, procure, or trust production TLS certificate material by default. On a controller/all-role install with no TLS material, `postinstall` SHALL continue launchd plist installation and print supported post-install actions: configure `ORCHARD_TRANSPORT_MODE=direct_https` with operator-provided certificate/key material, run the explicit `orchardctl tls init --no-trust` local-CA helper for local/dev-lab bootstrap, or configure `ORCHARD_TRANSPORT_MODE=plain_http_localhost` for local/emergency HTTP behavior. During the one-release legacy compatibility window, `ORCHARD_TLS_CERTFILE`/`ORCHARD_TLS_KEYFILE` and `ORCHARD_TLS_DISABLED=true` MAY be accepted as shims for those modes. `postinstall` SHALL NOT mutate system trust stores.

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
* `orchardctl support bundle create`
* `orchardctl upgrade plan`

Node-admission CLI commands SHALL provide stable human and JSON output for list, inspect, pending-review, admit, and reject workflows.
`orchardctl nodes admit` and `orchardctl nodes reject` SHALL support side-effect-free `--dry-run` Action Preview output and explicit execution gates, including `--yes` for execution and `--reason` for rejection.
For source-dev and packaged local use, node-admission CLI commands are local operator/admin commands that execute in the controller runtime context rather than proving Admin API bearer-token authorization.
They SHALL still enforce the same leader-only write-path, admission, confirmation, cluster-scoped audit, and shared-presenter semantics as the Admin API.

Node lifecycle CLI commands SHALL provide side-effect-free `--dry-run` Action Preview output in stable human and JSON forms.
Lifecycle execution SHALL enforce the preview's confirmation requirements, including `--yes`, consequence acknowledgement for drain and decommission, and a typed node id for decommission.
Node lifecycle CLI commands use the same local controller-runtime authority boundary as node-admission CLI commands and SHALL enforce the same leader-only write-path, mutation-time revalidation, cluster-scoped audit, and shared-presenter semantics.
Manual `draining -> maintenance` execution SHALL remain blocked with a `drain_completion_unverified` blocker until drain completion can be verified.

`orchardctl requests inspect` SHALL render a request's persisted scheduler explanation through the shared scheduler explanation reason-code contract in stable human and JSON forms.
Broader request execution diagnostics beyond persisted scheduler explanations remain future work.

`orchardctl support bundle create` SHALL be able to emit `orchard.support_bundle.v2` for cluster-management support bundles.
Console-triggered support bundles and CLI-created support bundles SHALL use the same v2 archive format for the same scope.
Request and scheduler-decision scoped bundles SHALL include sanitized metadata only and MUST NOT include prompt bodies, response bodies, raw token sequences, raw prefix-cache fingerprints, tenant secret material, raw local evidence logs, local tool session identifiers, or machine-specific prompt exports.

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

### Milestone 0 - Skeleton and packaging foundation

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
* retries before first token
* scheduler explanation endpoint

Acceptance:

* requests land on best loaded node
* cached/cold tier behavior works
* automatic retry before first token works once
* scheduler explanation matches actual decision

### Milestone 5 - Observability and diagnostics

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
* Support Bundle v2 contains scoped logs, config, node snapshots, request summaries, scheduler explanations, sanitized Node Admission evidence, omitted-section metadata, and a redaction manifest

### Milestone 6 - Security hardening and air-gap

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
