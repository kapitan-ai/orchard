# Orchard Glossary

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
The first-party node-local Orchard service that owns local runtime execution, model cache, worker supervision, diagnostics, status, and cleanup.
_Avoid_: Controller agent, worker runtime

**Runtime Endpoint**:
A schedulable execution boundary that can receive model runtime work from the Controller through Orchard's runtime semantics.
Orchard's v1 Runtime Endpoint is the first-party Node Agent; future Runtime Endpoints may be external compute or provider integrations.
A Runtime Endpoint is not necessarily a Node.
_Avoid_: Worker Runtime, transport protocol, durable cluster truth, managed Mac

**Worker Runtime**:
The local model execution process supervised by the Node Agent.
_Avoid_: Public API server, permanent launchd service

**MLX Worker**:
Orchard's Apple Silicon native Worker Runtime path for MLX and MLX-LM inference.
_Avoid_: Generic remote compute worker

**Postgres**:
Orchard's sole durable persistence and coordination store.
_Avoid_: Redis, Kafka, distributed Erlang state

**BEAM Distribution**:
The live Orchard communication and monitoring layer between first-party Elixir services.
The default-off BEAM Runtime Endpoint adapter exists for first-party Controller-to-Node Agent communication.
In source-dev, it becomes the primary Runtime Endpoint transport only after accepted two-Mac smoke evidence and explicit promotion.
In packaged production, BEAM Distribution is limited to admitted first-party Orchard services.
_Avoid_: Durable cluster truth, database replacement, public API, external provider integration

**Source-dev BEAM Operating Model**:
The source-development distribution profile for first-party Controller-to-Node Agent BEAM Runtime Endpoint communication.
It uses long BEAM node names with IPv4-literal hosts, explicit shared cookie material, bounded distribution networking, explicit BEAM target configuration, no automatic gRPC fallback, and split-role promotion before all-in-one source dev.
The current implementation exposes this through explicit `bin/dev-controller` and `bin/dev-node-agent` source-dev launches while `bin/dev` remains the gRPC default.
_Avoid_: Production BEAM security model, ambient `.erlang.cookie`, implicit fallback, durable cluster truth

**All-in-One Deployment**:
A deployment topology where one Mac runs the Controller, Node Agent, Worker Runtime, and Managed Database Mode.
_Avoid_: Single binary install, External Database Mode

**Controller and Worker Deployment**:
A deployment topology where one Mac runs the Controller and one to three Macs run Node Agents and Worker Runtimes; database ownership may be managed on the controller host or external.
_Avoid_: Database mode, cloud cluster, Kubernetes cluster

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

**Leader-only Write Path**:
A mutating operation that may execute only on the Active Leader in HA-lite mode and must fail closed on a Standby Controller.
Examples include node admission rejection, rejection clearance, admission, decommissioning, and the related cluster-scoped audit events.
_Avoid_: best-effort write, local-controller write

### APIs and Product Surfaces

**Public Inference API**:
Orchard's OpenAI-compatible client-facing HTTP/SSE API surface for models and inference requests.
_Avoid_: Operator API, Admin API, Internal Node/Worker API

**Responses API**:
Orchard's canonical public inference abstraction at `/v1/responses`.
_Avoid_: Chat Completions as canonical

**Chat Completions Facade**:
The compatibility API at `/v1/chat/completions` backed by Orchard's canonical request model.
_Avoid_: Canonical inference abstraction

**Operator API**:
The runtime-operations HTTP API surface for nodes, requests, diagnostics, scheduler explanations, and support bundles.
_Avoid_: Admin API, Public Inference API, tenant/key mutation unless also admin

**Admin API**:
The governance and configuration HTTP API surface for tenants, keys, quotas, models, routing, nodes, and observability settings.
_Avoid_: Operator API, runtime support action

**Runtime Endpoint Interface**:
The transport-independent Controller-facing execution semantics for scheduling, model readiness, inference execution, cancellation, status, prefix-cache scoring, and runtime telemetry.
Placement Capacity is part of this interface's observation vocabulary.
_Avoid_: Worker Runtime Interface, Node Lifecycle Interface, transport protocol

**gRPC Compatibility Adapter**:
The current adapter that maps Runtime Endpoint Interface semantics to `proto/cluster/v1` and `NodeRuntimeService`.
It preserves today's gRPC/protobuf implementation while keeping the durable Controller domain contract transport-independent.
_Avoid_: Runtime Endpoint Interface, Worker Runtime Interface, first-party BEAM mesh

**Worker Runtime Interface**:
The Node Agent-local execution process contract for loading models, generating output, reporting local worker status, and handling cancellation.
_Avoid_: Runtime Endpoint Interface, Public Inference API, provider API

**Node Lifecycle Interface**:
The first-party Orchard node management semantics for node identity, join, health observation, maintenance, drain, and decommissioning.
_Avoid_: Runtime Endpoint Interface, Worker Runtime Interface, scheduler ranking

**Orchard Console**:
The product-facing LiveView console for local and operator UI.
_Avoid_: Kapitan Orchard UI, admin panel

**Orchard CLI**:
The `orchardctl` command-line interface for operator and admin automation.
_Avoid_: Shell scripts as product interface

### Governance

**Operator**:
A human or local administrative actor who configures, governs, or operates Orchard through Console, CLI, Operator API, or Admin API surfaces.
An Operator is not a Service Account, API Client, API Key, or Tenant.
_Avoid_: Service Account, API Client, API Key, Tenant

**Tenant**:
A governance boundary for model access, quotas, keys, retention, and usage accounting.
Product-facing label: Organization.
_Avoid_: Workspace, account, Service Account, API Key

**Team**:
A product-facing grouping label stored as API Client metadata for filtering, reporting, and ownership context inside an Organization.
_Avoid_: Tenant, Quota boundary, Routing Policy, RBAC Role

**Service Account**:
A non-interactive principal that may own API Tokens and tenant-scoped RBAC Roles.
Product-facing label: API Client.
_Avoid_: User account, Tenant, API Key, Team

**API Key**:
A bearer credential scoped directly to a Tenant or Service Account.
Product-facing label: API Token.
_Avoid_: principal, RBAC Role, Bootstrap Token, Node Certificate, token when referring to model tokens

**One-time Secret Output**:
The one-time display or export of newly generated API Token secrets at creation.
_Avoid_: persisted secret, audit payload, support bundle content

**Owner Contact**:
Descriptive human or team contact metadata for an API Client.
_Avoid_: User account, Service Account, Principal, RBAC Role

**External Reference**:
An operator-provided stable identifier used to match an imported API Client across repeated provisioning runs.
_Avoid_: database id, API Token, Owner Contact

**Tenant-direct API Key**:
An API Key scoped directly to a Tenant without a Service Account owner.
_Avoid_: Service-account-owned API Key, Service Account, Owner Contact

**Service-account-owned API Key**:
An API Key whose effective principal is the Service Account that owns it.
_Avoid_: Tenant-direct API Key, User account, Owner Contact

**Key Rotation**:
An explicit credential lifecycle operation that creates a replacement API Token and revokes previous active API Tokens with the same API Client and token name.
_Avoid_: duplicate import, silent token creation, Service Account disablement

**API Client Disablement**:
A Service Account lifecycle state that blocks all owned API Tokens without deleting the API Client or mutating each token's revoked state.
_Avoid_: API Token revocation, deletion, Tenant suspension

**Provisioning Batch**:
A durable non-secret record of a bulk API Client or API Token provisioning operation.
It records status, counts, input hash, timestamps, and sanitized error summaries, never plaintext API Token secrets.
_Avoid_: raw CSV archive, One-time Secret Output, Audit Log

**Dry Run**:
A validation-only provisioning pass that reports intended changes and errors without creating API Clients, API Tokens, or One-time Secret Output.
Bulk API Client Dry Run validates one Organization slug per CSV file.
_Avoid_: partial import, preview that mutates state

**Apply**:
A provisioning pass that commits all validated changes and emits One-time Secret Output only if the batch succeeds.
Bulk API Client Apply validates the output path before mutation and treats the input file as an all-or-nothing batch for one Organization.
If One-time Secret Output delivery fails after the batch commits, Orchard marks the Provisioning Batch `output_failed` and returns API Token prefixes for revocation or rotation without persisting plaintext secrets.
_Avoid_: Dry Run, partial import, best-effort import

**RBAC Role**:
A named permission set assignable to principals for cluster, operator, tenant-admin, or inference-client access.
Product-facing label: Access Level.
_Avoid_: credential, API Key, ad hoc permission flag

**Cluster-scoped Admin Role**:
An RBAC Role assignment that grants a Service Account full cluster access through Admin API surfaces without a Tenant scope.
Tenant-direct API Keys do not imply this role.
_Avoid_: tenant admin, inference client, local dev admin

**Inference Client**:
An Access Level that permits a principal to call public inference endpoints for its Organization.
_Avoid_: admin, operator, tenant-admin, API Token

**Quota**:
A tenant-scoped usage or concurrency limit applied during Admission and reconciled at terminal Request state.
_Avoid_: Routing Policy, Scheduler Decision, rate limit only

**Routing Policy**:
A tenant or model policy input that constrains eligible pools, active request limits, residency preference, cold-start behavior, queue wait, and priority before scheduling.
_Avoid_: Quota, Scheduler Decision

**Audit Log**:
A durable governance or security event record for significant administrative and operator actions.
_Avoid_: Support Bundle, debug log, structured log, trace span

**Payload Capture Mode**:
A tenant setting that controls how much prompt and response payload data Orchard may retain.
_Avoid_: Audit Log, Support Bundle, logging level

### Requests and Inference

**Canonical Request**:
Orchard's normalized internal inference request shape shared across public endpoints.
_Avoid_: Endpoint-specific internal request

**Request**:
A coarse durable inference-request aggregate with endpoint, tenant, model, lifecycle state, usage, and terminal outcome metadata.
_Avoid_: Job, task, request-step observation, public response status

**Request FSM**:
The lifecycle state machine for an active Request from receipt through terminal outcome.
Scheduler or dispatch orchestration crashes after validation terminalize the Request as failed with `orchestration_error`.
_Avoid_: Queue state

**Request Event**:
An append-only durable event associated with a Request lifecycle or Request Step observation.
_Avoid_: Log line

**Request Step Event**:
A detailed `request_step.*` observation persisted as a Request Event without owning or mutating the coarse Request lifecycle state.
_Avoid_: Request state transition, Request step table

**Responses Terminal Projection**:
The public `/v1/responses` status mapping from internal terminal or error conditions into API-visible terminal status such as `failed` or `incomplete`.
_Avoid_: Request lifecycle state, Tool Execution outcome

**Inference Turn**:
A request-step type representing one model inference turn.
_Avoid_: Message, prompt

**Tool Call**:
A model-proposed function invocation returned to the client in current base v1 behavior.
_Avoid_: Tool Execution, server-side tool run

**Tool Execution**:
A future-facing request-step type for an Orchard-hosted, controller-governed run attempt for an approved server-hostable registry tool.
_Avoid_: Tool Call, execution snapshot metadata, base v1 tool calling

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
Base v1 tool-calling behavior where Orchard returns tool calls to the caller instead of executing them, including for registry-backed tools with server-hostable metadata.
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

**Runtime Endpoint Admission Candidate**:
An unreconciled Runtime Endpoint identity observed from status metadata and eligible for admin review before it becomes a managed Node.
It is not a Node Lifecycle State and is never schedulable.
_Avoid_: provisioned Node, registered Node, active Node, trusted Node

**Node Admission**:
The admin-controlled reconciliation step that accepts a trusted registered Node into cluster participation.
_Avoid_: Request Admission, Runtime Endpoint Observation, automatic discovery

**Pending Admission**:
A derived review category for a Runtime Endpoint Admission Candidate, provisioned placeholder, or registered Node that has not been explicitly admitted.
It is not a Node Lifecycle State and never makes the target schedulable.
_Avoid_: pending lifecycle state, active Node, automatic join

**Rejected Admission**:
A Node Admission outcome that keeps a candidate or lifecycle-managed Node out of scheduling while preserving review evidence and decision history.
It is not Decommission and does not delete observed inventory.
_Avoid_: Decommission, removed Node, failed heartbeat

**Node Admission Decision**:
Durable metadata recording a Node Admission outcome such as rejection or rejection clearance, with actor, timestamp, reason, observed identity or node reference, target reference when applicable, and audit event reference.
_Avoid_: Node Lifecycle State, Decommission, debug note

**Node Lifecycle State**:
The operator-controlled lifecycle state that determines how a Node is allowed to participate in the cluster.
_Avoid_: Runtime Endpoint Availability, Node Health, heartbeat freshness

**Node Health**:
The observed condition of a Node, independent of its operator-controlled lifecycle state.
_Avoid_: Node Lifecycle State, operator action

**Cluster Management Status**:
A shared operator-facing status contract that separates lifecycle, admission, freshness, transport, runtime readiness, compatibility, scheduling, warnings, and HA-lite read-only signals.
It is a cross-surface status vocabulary, not a replacement for the Node Lifecycle State machine.
_Avoid_: Node Lifecycle State, Node Health, Console-only status label

**Runtime Endpoint Availability**:
The scheduler-facing availability of a Runtime Endpoint for new work, independent of whether the endpoint is backed by an Orchard-managed Node, external compute, or a provider integration.
_Avoid_: Node Lifecycle State, durable cluster truth, provider billing status

**Runtime Endpoint Observation**:
A durable Controller-recorded snapshot of Runtime Endpoint status, capability, availability, placement, and capacity signals.
_Avoid_: live BEAM session, durable cluster truth by itself, provider billing event

**Heartbeat**:
A periodic durable observation used by the Controller to record first-party Node Agent health, inventory, workers, placements, and Runtime Endpoint Availability.
_Avoid_: Node Lifecycle State, readiness probe, live BEAM session

**Node Pool**:
A scheduling group where each v1 Node belongs to exactly one pool.
_Avoid_: Tenant, cluster

**Cordon**:
An operator action that prevents new scheduling to a Node while preserving existing work.
_Avoid_: Drain, Maintenance

**Drain**:
An operator action that cordons a Node and waits for active requests to finish or be cancelled by policy.
_Avoid_: Cordon only, Decommission

**Maintenance**:
An unschedulable Node Lifecycle State for upgrades or diagnostics.
_Avoid_: Decommission, Node Health

**Decommission**:
The lifecycle path for removing a Node, revoking trust, and preventing reuse of the same node identity.
_Avoid_: Maintenance, Drain

**Model Catalog**:
The global model metadata and publication state independent of any Node.
_Avoid_: Model placement

**Catalog State**:
A model's global publication state in the Model Catalog, independent of node-local loadedness.
_Avoid_: Placement State, loadedness

**Model Placement**:
The per-Runtime Endpoint residency, cache, availability, or load state for a model.
_Avoid_: Catalog entry

**Placement State**:
A per-Runtime Endpoint model state describing whether a model is unavailable, cached, loaded, provider-available, failed, or in transition.
_Avoid_: Catalog State, tenant-visible model activation

**Placement Capacity**:
A first-class Runtime Endpoint Observation describing current active request count and maximum concurrency for a Model Placement.
_Avoid_: Quota, durable capacity guarantee, transport field name

**Model Bundle**:
An offline-importable model artifact directory or archive supplied to Orchard with a Model Manifest.
_Avoid_: Model Catalog record, Artifact Bundle after import

**Model Manifest**:
Structured metadata inside a Model Bundle describing identity, tokenizer, capabilities, memory estimates, and runtime requirements.
_Avoid_: Runtime status, hashed artifact contents

**Artifact Bundle**:
A filesystem copy and hash unit for model contents after Orchard validates and imports a Model Bundle.
_Avoid_: Model Manifest, Model Catalog record

**Prewarming**:
Policy-driven effort to keep selected Model Placements cached or loaded before demand.
_Avoid_: loadedness guarantee, first request cold load

**Pinning**:
Operator policy that protects selected Model Placements from automatic eviction and influences reconciliation priority.
_Avoid_: Catalog activation, immediate loadedness guarantee

**Eviction**:
Removal of cached or idle loaded model residency under memory, disk, or policy pressure.
_Avoid_: Retirement, Catalog State change

### Scheduling and Runtime Telemetry

**Admission**:
The ordered Controller gate that authenticates, validates, tokenizes, enforces policy, records a Request, and routes it toward immediate scheduling or Queue.
_Avoid_: Scheduler ranking, Dispatch

**Scheduler**:
The Controller component that evaluates eligible work, applies queue and ranking policy, and produces a Scheduler Decision.
_Avoid_: Admission, Dispatch

**Schedulable Node**:
A Node whose first-party Runtime Endpoint is eligible for new work because lifecycle, health, policy, capability, memory, concurrency, and breaker conditions allow it.
_Avoid_: Healthy node, every Runtime Endpoint

**Schedulable Runtime Endpoint**:
A Runtime Endpoint eligible for new work because policy, capability, health, capacity, and breaker conditions allow it.
_Avoid_: Node inventory, hardware host

**Candidate Tier**:
A scheduling group based on model residency, such as loaded, cached, or cold.
_Avoid_: Node pool

**Queue Wait Reason**:
A stable machine-readable classification of why queued work is still waiting, as live node capacity, requested model path capacity, placement capacity, or tenant active capacity.
It is distinct from a Scheduler Reason Code, which explains a rejected or skipped candidate.
_Avoid_: Scheduler Reason Code, tenant-facing error message, free-text wait note

**Scheduler Decision**:
The selected Runtime Endpoint and sanitized ranking metadata persisted with a Request.
_Avoid_: Quota, Routing Policy, Scheduler Explanation, tenant-facing error reason

**Scheduler Explanation**:
Operator-facing reasoning for a request's scheduling decision across selected, scored, skipped, and rejected candidates.
_Avoid_: persisted Scheduler Decision metadata, tenant-facing error contract

**Scheduler Reason Code**:
A stable machine-readable identifier explaining why a scheduler candidate was rejected or skipped.
It is the programmatic contract; human-readable scheduler messages are explanatory and may change.
_Avoid_: free-text reason, tenant-facing error message

**Skipped Scheduler Candidate**:
A scheduler candidate omitted from scoring or rejection for a stable non-error reason such as lower-priority tier selection or candidate-budget limits.
It is distinct from a rejected candidate that was evaluated and failed eligibility.
_Avoid_: rejected candidate, failed dispatch, hidden error

**Dispatch**:
The Controller-to-Runtime Endpoint handoff after scheduling that ensures a model is loaded and starts inference execution.
Runtime Endpoint disconnect cleanup is best-effort and does not define the dispatch outcome.
_Avoid_: Scheduler Decision

**Circuit Breaker**:
A scheduler suppression rule for repeatedly failing nodes or placements.
_Avoid_: Node health

**Queue**:
A controller-owned wait path used after Admission when work cannot be immediately granted because live Runtime Endpoint, node, or placement capacity is unavailable, placement or aggregate runtime concurrency is exhausted, or tenant active concurrency is exhausted.
Each Tenant keeps FIFO order, and cross-tenant selection uses weighted round-robin that can skip capped tenants while preserving their FIFO order.
Fresh Runtime Endpoint Observations can wake queued work by adding source-scoped loaded-placement or cold/no-placement capacity.
Stale, unavailable, ineligible, or transport-failed observations clear endpoint-owned capacity sources so queued work is not promoted against failed targets.
_Avoid_: Global backlog, Request lifecycle state

**Cluster Busy**:
A scheduler outcome meaning joined live Runtime Endpoint candidates exist, but none can currently accept the request because aggregate endpoint or placement capacity is exhausted, or because placement capacity is unknown for already-active candidates.
With queue admission enabled, this can return the request to the same Queue deadline; otherwise it is a tenant-facing `503` capacity failure.
_Avoid_: Transport failure, model not found, queue full

**Model Busy**:
A runtime or single-node scheduler outcome meaning the requested model path cannot accept the request because live node or placement request capacity is exhausted.
It maps to a tenant-facing `503` capacity failure and is separate from tenant quota or queue-full admission failures.
_Avoid_: Cluster Busy, quota exceeded, model not found

**Cache Affinity**:
A scheduler warmth hint based on recent request locality and optional prefix-cache fingerprints.
_Avoid_: Placement residency

**Prefix-cache Fingerprint**:
An opaque controller-derived HMAC value used as a bounded locality hint without exposing prompt text or tokens.
_Avoid_: Raw prompt fingerprint

**Runtime Prefix-cache Status**:
Runtime telemetry about prefix-cache configuration, counters, and bounded HMAC fingerprint presence; counters are observe-only, while fingerprint presence may be used only as a configured non-gating scheduler tie-break hint.
_Avoid_: Readiness gate, admission gate, scheduler eligibility gate, tenant-facing signal, raw prompt or token data

**Runtime Model Placement**:
Compatibility-protocol status for one loaded Model Placement, including `active_request_count` and `max_concurrency`.
The scheduler uses it only to prove same-model placement capacity and to rank by requested-placement load.
Queue admission also uses valid loaded-placement observations to wake queued same-model work, and treats non-loaded, invalid, duplicate, or exhausted placement observations as unavailable capacity.
_Avoid_: Catalog State, durable placement record, model manifest metadata

**Runtime Node Capacity**:
Runtime Endpoint Observation data for aggregate runtime capacity on one endpoint-backed node.
The current gRPC Compatibility Adapter maps this from `StatusResponse.active_request_count` and `StatusResponse.max_concurrency`.
The BEAM Node Agent facade maps the same node-agent status semantics into BEAM Runtime Endpoint Observations.
The scheduler uses it to exclude endpoint-backed nodes that have exhausted aggregate request slots before considering per-placement capacity.
Queue admission uses eligible endpoint observations to bound cold/no-placement wakeups and to keep active source reservations from being double-counted across queued lanes.
Transport-failed or newly ineligible endpoints clear endpoint-owned aggregate, cold, and placement sources instead of retaining stale capacity.
BEAM observations publish queue capacity only when the target resolves back to the same persisted node identity.
_Avoid_: Tenant quota, durable Node inventory capacity, model-specific capacity

**Prefix-cache Score**:
A bounded, fail-open score RPC result used only as explicitly configured scheduler tie-break telemetry.
_Avoid_: Readiness gate, admission gate, scheduler eligibility gate, tenant-facing failure reason, all-candidate scoring

**Runtime Memory Budget**:
Observe-only runtime and model memory telemetry that, when enabled and positive, may provide a non-excluding scheduler-ranking preference.
_Avoid_: Memory enforcement input, request-admission gate, scheduler eligibility gate, tenant-facing rejection reason, tunable headroom threshold

**Memory Admission**:
Despite the name, a bounded scheduler-ranking feature that can prefer positive memory-headroom observations without excluding candidates.
_Avoid_: Request Admission, memory rejection, scheduler eligibility filter, memory-budget enforcement

**Action Preview**:
A side-effect-free evaluation of an Operator or Admin action before execution.
It reports blockers, warnings, consequence codes, and confirmation requirements.
_Avoid_: Dry Run for provisioning, action execution, audit event

**Blocker**:
A non-bypassable condition that prevents an action from executing.
_Avoid_: Warning, Confirmation Requirement

**Warning**:
An advisory condition that does not by itself prevent action execution.
_Avoid_: Blocker, failure reason

**Consequence Code**:
A stable machine-readable code describing an expected effect of an action.
_Avoid_: free-text warning, Blocker

**Confirmation Requirement**:
A required explicit acknowledgement or typed value before executing a risky but otherwise allowed action.
_Avoid_: Blocker, permission grant

### Packaging, Trust, and Operations

**Transport Mode**:
The public API listener mode: reverse proxy, direct HTTPS, or degraded loopback HTTP.
_Avoid_: Certificate Source, internal mTLS

**Certificate Source**:
The resolved provenance of direct-HTTPS certificate material.
_Avoid_: Transport Mode, Node Certificate

**mTLS**:
Mutual TLS used for internal Controller and Node Agent RPC trust.
_Avoid_: Public API transport, Trusted Proxy

**Bootstrap Token**:
A time-limited or one-time Node join credential used before certificate trust is established.
_Avoid_: API Key, Node Certificate

**Node Certificate**:
A Node identity certificate used for internal RPC trust and renewal.
_Avoid_: Bootstrap Token, API Key, Public HTTPS certificate

**Trusted Proxy**:
A configured reverse proxy source whose forwarded headers may be trusted in reverse-proxy transport mode.
_Avoid_: internal mTLS trust, any proxy

**Managed Database Mode**:
A database ownership mode where Orchard manages a local loopback Postgres container on macOS.
_Avoid_: Deployment topology, External Database Mode

**External Database Mode**:
A database ownership mode where Orchard uses an operator-managed PostgreSQL database.
_Avoid_: Managed Database Mode, All-in-One Deployment

**Support Bundle**:
An operator-generated diagnostic package for logs, config, snapshots, and request summaries.
_Avoid_: Audit Log, Payload Capture Mode, raw local evidence

**Support Bundle v2**:
The required diagnostic bundle format for cluster-management evidence, including sanitized admission candidates, Node Admission Decisions, scheduler explanations, support scope, omitted sections, and redaction manifest.
v1 compatibility must not weaken v2 contents or redaction rules.
_Avoid_: Support Bundle v1, raw local evidence, prompt export

**License Enforcement Mode**:
The resolved licensing mode, `off`, `warn`, or `hard`, that controls licensing checks at startup and packaged useful-work admission and whether non-valid license state is surfaced for operator remediation.
_Avoid_: license validity, Console-only visibility flag, Payload Capture Mode

**DMG Installer**:
The interactive macOS distribution container for Orchard installer materials.
_Avoid_: PKG Installer, launchd service

**PKG Installer**:
The unattended or enterprise macOS package distribution format that installs Orchard payloads and launchd plists.
_Avoid_: DMG Installer, LaunchDaemon runtime service

**LaunchDaemon**:
A launchd-managed system daemon for Orchard system services such as the Controller, Node Agent, and, when Managed Database Mode is enabled, Postgres.
_Avoid_: installer package, Worker Runtime, Tray/Menu Bar App

**LaunchAgent**:
A launchd-managed user agent that starts the Tray/Menu Bar App in a user context.
_Avoid_: LaunchDaemon, system service

**Tray/Menu Bar App**:
The local macOS app for status, onboarding, logs, and support-bundle entry.
_Avoid_: Orchard Console, LaunchDaemon
