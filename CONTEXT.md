# Orchard Context

Orchard is a sovereign on-prem LLM orchestration platform for Apple Silicon macOS. This glossary defines Orchard's shared language; `SPEC.md` remains the normative build contract for behavior, interfaces, states, and milestones.

## Language

### Product Truth

**Orchard**:
A sovereign on-prem LLM orchestration platform for one to four Apple Silicon macOS machines.
_Avoid_: Kapitan Orchard, cloud LLM platform

**Normative Build Contract**:
The top-level product and system contract that governs Orchard behavior and resolves conflicts between docs, tests, and implementation.
_Avoid_: Planning note, local handoff

**Durable Product Truth**:
Standalone Orchard guidance that lives in the repo as `SPEC.md`, product docs, decision records, tests, or code.
_Avoid_: Raw prompt export, tool session, local evidence, active goal package

**Decision Record**:
A standalone ADR-style record for a durable product or implementation decision not already fixed by the Normative Build Contract.
_Avoid_: Historical coordination note, raw planning transcript

**Goal Package**:
Transient local execution scaffolding under `goals/<slug>/` whose conclusions count only after promotion into Durable Product Truth.
_Avoid_: Product doc, decision record

**Milestone**:
A staged delivery scope in Orchard's v1 build roadmap.
_Avoid_: Release, sprint

### Topology

**Controller**:
The central control-plane service that owns public APIs, governance, admission, scheduling, dispatch, request state, and stream relay.
_Avoid_: Worker, node agent

**Node Agent**:
The node-local control endpoint that manages node registration, status, model cache, worker supervision, diagnostics, and runtime access.
_Avoid_: Controller agent, worker runtime

**Worker Runtime**:
The local model execution process supervised by the Node Agent.
_Avoid_: Public API server, permanent launchd service

**MLX Worker**:
Orchard's Apple Silicon native Worker Runtime path for MLX and MLX-LM inference.
_Avoid_: Generic remote compute worker

**Postgres**:
Orchard's sole durable persistence and coordination store.
_Avoid_: Redis, Kafka, distributed Erlang state

**All-in-One Deployment**:
A deployment where one Mac runs the Controller, Node Agent, Worker Runtime, and managed Postgres.
_Avoid_: Single binary install

**Controller and Worker Deployment**:
A deployment where one Mac runs the Controller and one to three Macs run Node Agents and Worker Runtimes.
_Avoid_: Cloud cluster, Kubernetes cluster

**HA-lite Control Plane**:
A control-plane mode with at most two Controller instances and exactly one Active Leader.
_Avoid_: Active-active cluster, consensus cluster

**Active Leader**:
The Controller instance that owns scheduler, dispatch, migration, and other leader-only tasks.
_Avoid_: Primary worker

**Standby Controller**:
A non-leader Controller instance that may serve liveness but must not mutate runtime cluster state.
_Avoid_: Secondary active controller

**Advisory Lock**:
A Postgres coordination lock used by Orchard for exclusive leadership and ownership of single-writer tasks.
_Avoid_: Distributed lock service

### APIs and Product Surfaces

**Public Inference API**:
Orchard's OpenAI-compatible client-facing API surface for models and inference requests.
_Avoid_: Operator API, Admin API

**Responses API**:
Orchard's canonical public inference abstraction at `/v1/responses`.
_Avoid_: Chat Completions as canonical

**Chat Completions Facade**:
The compatibility API at `/v1/chat/completions` backed by Orchard's canonical request model.
_Avoid_: Canonical inference abstraction

**Operator API**:
The runtime operations API surface for nodes, requests, diagnostics, scheduler explanations, and support bundles.
_Avoid_: Admin API

**Admin API**:
The governance and configuration API surface for tenants, keys, quotas, models, routing, nodes, and observability settings.
_Avoid_: Operator API

**Internal Node/Worker API**:
The private gRPC API surface between the Controller, Node Agent, and Worker Runtime.
_Avoid_: Public worker API

**Orchard Console**:
The product-facing LiveView console for local and operator UI.
_Avoid_: Kapitan Orchard UI, admin panel

**Orchard CLI**:
The `orchardctl` command-line interface for operator and admin automation.
_Avoid_: Shell scripts as product interface

### Governance

**Tenant**:
A governance boundary for model access, quotas, keys, retention, and usage accounting.
_Avoid_: Workspace, account

**Service Account**:
A non-interactive principal that may own credentials and permissions.
_Avoid_: User account

**API Key**:
A bearer credential scoped to a tenant or service account.
_Avoid_: Token when referring to model tokens

**RBAC Role**:
A named permission set for cluster, operator, tenant-admin, or inference-client access.
_Avoid_: Ad hoc permission flag

**Quota**:
A tenant-scoped usage or concurrency limit applied during admission and reconciled at terminal request state.
_Avoid_: Rate limit only

**Routing Policy**:
A tenant or model policy that constrains pools, residency preference, cold-start behavior, and queue wait.
_Avoid_: Scheduler decision

**Audit Log**:
A durable governance or security event record for significant administrative and operator actions.
_Avoid_: Debug log, trace span

**Payload Capture Mode**:
A tenant setting that controls how much prompt and response payload data Orchard may retain.
_Avoid_: Logging level

### Requests and Inference

**Canonical Request**:
Orchard's normalized internal inference request shape shared across public endpoints.
_Avoid_: Endpoint-specific internal request

**Request**:
A durable inference request record with endpoint, tenant, model, lifecycle state, usage, and terminal outcome metadata.
_Avoid_: Job, task

**Request FSM**:
The lifecycle state machine for an active Request from receipt through terminal outcome.
_Avoid_: Queue state

**Request Event**:
An append-only durable event associated with a Request lifecycle or Request Step observation.
_Avoid_: Log line

**Request Step Event**:
A detailed request-step observation persisted as a Request Event without owning the coarse Request lifecycle state.
_Avoid_: Request step table

**Inference Turn**:
A request-step type representing one model inference turn.
_Avoid_: Message, prompt

**Tool Call**:
A model-proposed function call returned to the client in base v1 behavior.
_Avoid_: Server-executed tool

**Tool Execution**:
A future-facing request-step type for controller-governed hosted tool execution.
_Avoid_: Base v1 tool calling

**Inference Event**:
A streamed internal runtime event such as accepted, text delta, tool-call delta, usage update, completion, failure, or progress.
_Avoid_: Public SSE event

**Token Usage**:
The input, output, and total token counts associated with an inference request or stream update.
_Avoid_: Billing only

**Server-Sent Events**:
The streaming format used for public token and response event delivery.
_Avoid_: WebSocket stream

**Prompt Rendering**:
The process of producing the final model prompt from request input, messages, templates, and tools before scheduling.
_Avoid_: Worker-side prompt assembly

**Exact Tokenization**:
Controller-side token counting against the final rendered prompt before admission and scheduling.
_Avoid_: Approximate token counting

**Safe Tokenization**:
Controller-authoritative tokenization that protects caller-authored text from control-token confusion.
_Avoid_: Legacy rendered-prompt dispatch

**Prompt Token IDs**:
Controller-supplied token IDs that capable workers use directly instead of re-encoding prompt text.
_Avoid_: Manifest capability

**Parity Drift**:
A tokenizer invariant breach when a capable worker rejects controller-supplied Prompt Token IDs for length mismatch.
_Avoid_: Tokenizer warning

**Catalog Drift**:
A tokenizer observability signal that live request-time control-token discovery found bundle-manifest omissions.
_Avoid_: Full manifest diff

### Tools

**Tool Ref**:
A registry reference string of the form `tool://<name>@<version>`.
_Avoid_: Ad hoc tool identifier

**Inline Function Tool**:
A request-provided function definition that may be passed through for model tool calling.
_Avoid_: Hosted tool

**Registry-backed Tool**:
A function tool resolved by the Controller from a Tool Ref before tokenization and dispatch.
_Avoid_: Inline function tool

**Client-executed Passthrough**:
Base v1 tool-calling behavior where Orchard returns tool calls to the caller instead of executing them.
_Avoid_: Hosted execution

**Hosted Tool Capability**:
Static node-advertised support for a server-hostable tool identified by name and version.
_Avoid_: Hosted tool readiness

**Hosted Tool Readiness**:
Dynamic node status for whether an advertised hosted tool is currently ready.
_Avoid_: Hosted tool capability

**Server-hostable Tool**:
A future registry-approved tool mode eligible for controller-governed, node-executed hosted execution.
_Avoid_: Arbitrary remote compute

### Nodes and Models

**Node**:
A managed Apple Silicon macOS machine represented in Orchard's cluster inventory.
_Avoid_: Server when cluster role matters

**Node Lifecycle State**:
The operator-controlled lifecycle state that determines how a Node participates in the cluster.
_Avoid_: Node health

**Node Health**:
The observed health of a Node, independent of its lifecycle state.
_Avoid_: Node lifecycle state

**Heartbeat**:
A periodic Node Agent status report used by the Controller to observe node health, inventory, workers, and placements.
_Avoid_: Readiness probe

**Node Pool**:
A scheduling group where each v1 Node belongs to exactly one pool.
_Avoid_: Tenant, cluster

**Cordon**:
An operator action that prevents new scheduling to a Node while preserving existing work.
_Avoid_: Drain

**Drain**:
An operator action that cordons a Node and waits for active requests to finish or be cancelled by policy.
_Avoid_: Cordon

**Maintenance**:
An unschedulable lifecycle state for upgrades or diagnostics.
_Avoid_: Decommission

**Decommission**:
The lifecycle path for removing a Node, revoking trust, and preventing reuse of the same node identity.
_Avoid_: Maintenance

**Model Catalog**:
The global model metadata and publication state independent of any Node.
_Avoid_: Model placement

**Catalog State**:
A model's global publication state in the Model Catalog.
_Avoid_: Placement state

**Model Placement**:
The per-node residency, cache, and load state for a model artifact.
_Avoid_: Catalog entry

**Placement State**:
A per-node model state describing whether an artifact is absent, cached, loaded, evicted, failed, or in transition.
_Avoid_: Catalog state

**Model Bundle**:
An offline-importable model artifact directory or archive with an Orchard manifest.
_Avoid_: Model catalog record

**Model Manifest**:
Structured metadata describing a Model Bundle's identity, tokenizer, capabilities, memory estimates, and runtime requirements.
_Avoid_: Runtime status

**Artifact Bundle**:
A filesystem model bundle whose contents can be hashed and copied as a unit.
_Avoid_: Model manifest

**Prewarming**:
Policy-driven effort to keep selected Model Placements cached or loaded before demand.
_Avoid_: First request cold load

**Pinning**:
Operator policy that protects selected Model Placements from automatic eviction and influences reconciliation priority.
_Avoid_: Catalog activation

**Eviction**:
Removal of cached or idle loaded model residency under memory or disk pressure.
_Avoid_: Retirement

### Scheduling and Runtime Telemetry

**Admission**:
The ordered Controller process that authenticates, validates, tokenizes, enforces policy, records, and schedules or queues a Request.
_Avoid_: Scheduler

**Scheduler**:
The Controller component that selects eligible nodes, queues requests, and dispatches work according to policy and ranking.
_Avoid_: Admission

**Schedulable Node**:
A Node eligible for new work because lifecycle, health, policy, capability, memory, concurrency, and breaker conditions allow it.
_Avoid_: Healthy node

**Candidate Tier**:
A scheduling group based on model residency, such as loaded, cached, or cold.
_Avoid_: Node pool

**Scheduler Decision**:
The selected scheduling result and sanitized ranking metadata associated with a Request.
_Avoid_: Scheduler explanation

**Scheduler Explanation**:
Operator-facing reasoning for selected and rejected scheduling candidates.
_Avoid_: Tenant-facing error

**Dispatch**:
The Controller-to-Node Agent handoff that ensures a model is loaded and starts inference execution.
_Avoid_: Scheduling

**Circuit Breaker**:
A scheduler suppression rule for repeatedly failing nodes or placements.
_Avoid_: Node health

**Queue**:
A tenant-scoped FIFO wait path used when no Node is immediately eligible.
_Avoid_: Global backlog

**Cache Affinity**:
A scheduler warmth hint based on recent request locality and optional prefix-cache fingerprints.
_Avoid_: Placement residency

**Prefix-cache Fingerprint**:
An opaque controller-derived HMAC value used as a bounded locality hint without exposing prompt text or tokens.
_Avoid_: Raw prompt fingerprint

**Runtime Prefix-cache Status**:
Observe-only runtime telemetry about prefix-cache configuration, counters, and bounded fingerprint presence.
_Avoid_: Readiness gate

**Prefix-cache Score**:
A bounded, fail-open score RPC result used only as explicitly configured scheduler tie-break telemetry.
_Avoid_: Tenant-facing failure reason

**Runtime Memory Budget**:
Observe-only runtime and model memory telemetry that may provide a positive non-excluding ranking preference.
_Avoid_: Memory enforcement input

**Memory Admission**:
The bounded scheduler-ranking feature that prefers positive memory-headroom observations without excluding candidates.
_Avoid_: Memory rejection

### Packaging, Trust, and Operations

**Transport Mode**:
The public API listener mode: reverse proxy, direct HTTPS, or degraded loopback HTTP.
_Avoid_: Legacy TLS flag

**Certificate Source**:
The resolved provenance of direct HTTPS certificate material.
_Avoid_: Transport mode

**mTLS**:
Mutual TLS used for internal Controller and Node Agent RPC trust.
_Avoid_: Public API transport

**Bootstrap Token**:
A time-limited or one-time Node join credential used before certificate trust is established.
_Avoid_: API key

**Node Certificate**:
A Node identity certificate used for internal RPC trust and renewal.
_Avoid_: Public HTTPS certificate

**Trusted Proxy**:
A configured reverse proxy source whose forwarded headers may be trusted in reverse-proxy transport mode.
_Avoid_: Any proxy

**Managed Database Mode**:
A deployment mode where Orchard manages a local loopback Postgres container on macOS.
_Avoid_: Default external database

**External Database Mode**:
A deployment mode where Orchard uses an operator-managed PostgreSQL database.
_Avoid_: Managed database mode

**Support Bundle**:
An operator-generated diagnostic package for logs, config, snapshots, and request summaries.
_Avoid_: Raw local evidence

**DMG Installer**:
The interactive macOS distribution container for Orchard installer materials.
_Avoid_: PKG installer

**PKG Installer**:
The unattended or enterprise macOS package distribution format for Orchard.
_Avoid_: DMG installer
