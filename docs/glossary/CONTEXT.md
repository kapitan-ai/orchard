# Orchard Glossary

Orchard is a sovereign on-prem LLM orchestration platform with a portable Orchard control-plane core and a currently supported Apple Silicon macOS platform profile.
This glossary defines Orchard's shared language; `SPEC.md` remains the normative build contract for behavior, interfaces, states, and milestones.

## Language

### Product Truth

**Orchard**:
A sovereign on-prem LLM orchestration platform whose current supported platform profile is Apple Silicon macOS and whose accepted next platform target permits a Linux Controller Host with Apple Silicon macOS Nodes.
_Avoid_: Kapitan Orchard, cloud LLM platform

**Portable Orchard Control-Plane Core**:
The platform-neutral Shared, Controller, Node Agent, and portable CLI behavior together with the provider-neutral contracts on which they depend.
_Avoid_: Portable core, portable control plane, portable control-plane core, Linux-only core, Linux Orchard, macOS Orchard

**Platform Profile**:
A named binding of Orchard host roles to a specified operating system, architecture, and platform acceptance evidence.
Defining or accepting a Platform Profile does not declare it supported; support requires the applicable acceptance evidence and gates to pass.
An accepted target profile is not supported until its explicit milestone acceptance gates pass.
_Avoid_: Distribution Profile, Runtime-Provider Profile, Acceptance Profile, unqualified profile, support claim without acceptance

**Distribution Profile**:
A named binding of a Platform Profile and install roles to deployment artifacts, host lifecycle, paths, credential storage, update and rollback behavior, retained state, and release evidence.
_Avoid_: Platform Profile, Runtime-Provider Profile, deployment artifact

**Runtime-Provider Profile**:
A named binding of a Node role to a Worker Runtime provider, compatible acceleration and device resources, provider-neutral conformance, and real-runtime acceptance.
It qualifies the Node role rather than making the portable Node Agent provider-specific.
_Avoid_: Platform Profile, Distribution Profile, Runtime Provider alone, provider-specific Node Agent

**Acceptance Profile**:
A named topology and evidence contract that proves participating Platform, Distribution, and Runtime-Provider Profiles operate together.
_Avoid_: Platform Profile, deployment topology alone, support claim without acceptance

**Host-Lifecycle Adapter**:
A platform-specific boundary that preserves Orchard lifecycle outcomes without making host mechanics part of portable policy.
_Avoid_: Platform Profile, Runtime Provider, deployment artifact

**Deployment Artifact**:
A produced distribution input or output delivered or assembled under a Distribution Profile.
_Avoid_: Platform Profile, Distribution Profile, source tree

**Linux Controller Profile**:
The accepted headless Linux Platform Profile for a Controller Host using operator-provided external Postgres and no implicit Apple or accelerator dependency.
_Avoid_: Linux Orchard, Linux Node Profile, supported profile before Milestone 8 acceptance

**macOS Native Distribution Profile**:
The macOS Distribution Profile whose approved interactive artifact is `Orchard.app` inside a DMG and whose lifecycle preserves platform-native trust and retained operator state.
_Avoid_: macOS Platform Profile, DMG artifact alone, native PKG

**macOS MLX Node Runtime Profile**:
The Runtime-Provider Profile qualifying an Apple Silicon macOS Node role that pairs the portable Node Agent with Metal, MLX-LM, the tokenizer stack, and the MLX Worker Runtime under real-runtime qualification.
_Avoid_: macOS Platform Profile, MLX artifact format, generic Node profile, provider-specific Node Agent

**Mixed-Platform Acceptance Profile**:
The Acceptance Profile that proves a portable Controller, including a Linux Controller, can operate admitted macOS Nodes under the macOS MLX Node Runtime Profile.
_Avoid_: Mixed-platform Platform Profile, deployment topology alone, Linux support claim without acceptance

**Initial Source-Availability Transition**:
The first period in which Orchard source is readable in this repository before any supported public binary is published.
It neither promises a supported public binary nor changes Orchard's licensing terms.
_Avoid_: Curated OSS, open source release, public binary availability, licensing change

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

**Controller Host**:
The machine that runs a Controller release.
A Controller Host is not a schedulable Node unless a separately enrolled and admitted Node Agent also runs there.
_Avoid_: Node, Active Leader, Controller process

**Node Agent**:
The first-party node-local Orchard service that owns local runtime execution, model cache, worker supervision, diagnostics, status, and cleanup.
_Avoid_: Controller agent, worker runtime

**Node Identity Root**:
The owner-only filesystem root that holds a Node's private key, Node Certificate, enrolled trust state, and stored BEAM Peer Grants.
Lifecycle and trust operations treat this root as identity-bearing state and must not assume that concurrent Node Agent processes can safely share it.
_Avoid_: BEAM Authorization Root, model cache, generic support directory

**Runtime Endpoint**:
A schedulable execution boundary that can receive model runtime work from the Controller through Orchard's runtime semantics.
Orchard's v1 Runtime Endpoint is the first-party Node Agent; future Runtime Endpoints may be external compute or provider integrations.
A Runtime Endpoint is not necessarily a Node.
_Avoid_: Worker Runtime, transport protocol, durable cluster truth, managed Mac

**Worker Runtime**:
The local model execution process supervised by the Node Agent.
_Avoid_: Public API server, permanent launchd service

**Runtime Provider**:
A Node-local implementation that satisfies the provider-neutral Worker Runtime Interface for a runtime family such as MLX-LM.
_Avoid_: model artifact format, acceleration implementation, device resource

**Acceleration Implementation**:
A hardware or software execution backend used by a Runtime Provider, such as Apple Metal through MLX.
_Avoid_: Runtime Provider, device resource, model format

**Device Resource**:
A normalized schedulable compute device exposed by a Host Capability Provider.
_Avoid_: Runtime Provider, operating-system name, memory domain

**Memory Domain**:
A normalized memory pool associated with one or more Device Resources, including unified or discrete memory arrangements.
_Avoid_: raw host memory metric, device resource, runtime concurrency

**Host Capability Provider**:
A platform-specific adapter that reports normalized operating-system, architecture, device, acceleration, memory-domain, lifecycle, and secret-store capabilities without defining runtime execution semantics.
_Avoid_: Runtime Provider, Worker Runtime, scheduler policy

**MLX Worker**:
Orchard's Apple Silicon native Worker Runtime path for MLX and MLX-LM inference.
_Avoid_: Generic remote compute worker

**Postgres**:
Orchard's sole durable persistence and coordination store.
_Avoid_: Redis, Kafka, distributed Erlang state

**BEAM Distribution**:
The live Orchard communication and monitoring layer between first-party Elixir services.
The BEAM Runtime Endpoint adapter is the split-role source-dev default for first-party Controller-to-Node Agent communication.
In split-role source-dev, it is the primary Runtime Endpoint transport, promoted on 2026-07-05 after accepted two-Mac smoke evidence.
In packaged production, BEAM Distribution is limited to admitted first-party Orchard services and uses Node Certificates plus scoped BEAM Peer Grants.
_Avoid_: Durable cluster truth, database replacement, public API, external provider integration

**Source-dev BEAM Operating Model**:
The source-development operating model for first-party Controller-to-Node Agent BEAM Runtime Endpoint communication.
It uses long BEAM node names with IPv4-literal hosts, explicit shared cookie material, bounded distribution networking, explicit BEAM target configuration, and no automatic gRPC fallback.
The current implementation exposes this as the default through `bin/dev-controller` and `bin/dev-node-agent` source-dev launches while `bin/dev` remains the gRPC default.
_Avoid_: Production BEAM security model, ambient `.erlang.cookie`, implicit fallback, durable cluster truth

**Production BEAM Operating Model**:
The enrolled first-party Controller-to-Node Agent operating model that combines Node Certificates, trusted inventory, and scoped BEAM Peer Grants.
_Avoid_: Source-dev shared-cookie model, certificate-only BEAM authorization, static target list

**BEAM Peer Grant**:
A bounded transport authorization for one exact Controller instance and one admitted Node to form an OTP distribution connection.
It is not Node identity and is invalid without the corresponding Node and Controller Certificates.
_Avoid_: Node Certificate, Node Enrollment Bundle, shared cluster cookie, RBAC Role

**BEAM Authorization Root**:
A Controller-local secret from which that Controller derives its BEAM Peer Grant secrets.
_Avoid_: Node-signing CA, shared cluster cookie, Node private key, database secret

**High-trust BEAM Boundary**:
The trust boundary entered when first-party Orchard services complete distributed Erlang authorization.
It is not a per-function capability sandbox.
_Avoid_: Runtime Endpoint Interface, protocol-isolated adapter, least-privilege RPC boundary

**All-in-One Deployment**:
A deployment topology where one Mac runs the Controller, Node Agent, and Worker Runtime.
Its Database Mode is orthogonal to the topology identity.
_Avoid_: Single binary install, Database Mode

**Controller and Worker Deployment**:
A deployment topology where one Mac runs the Controller and one to three Macs run Node Agents and Worker Runtimes.
Its Database Mode is orthogonal to the topology identity.
_Avoid_: Database mode, cloud cluster, Kubernetes cluster

**Active/Standby Control Plane**:
A control-plane mode with at most two Controller instances and exactly one Active Leader.
_Avoid_: Active-active cluster, consensus cluster

**Active Leader**:
The Controller instance that owns scheduler, dispatch, migration, and other leader-only tasks.
_Avoid_: Primary worker

**Standby Controller**:
A non-leader Controller instance that may serve liveness but must not mutate runtime cluster state.
_Avoid_: Secondary active controller

**Controller Instance**:
A Controller identified by its own durable membership identity, certificate identity, canonical BEAM node name, and BEAM Authorization Root custody reference.
Controller-instance identity is durable cluster truth and never implies current leadership.
_Avoid_: The controller, controller row, leader, Active Leader

**Controller Membership Heartbeat**:
The periodic write in which one Controller instance atomically refreshes its own last-seen timestamp and its complete Controller Capability Evidence tuple.
It reports membership, not leadership, and a failed heartbeat leaves the previous evidence stale rather than partially updated.
_Avoid_: Node Heartbeat, leader election, liveness probe, keepalive

**Controller Capability Evidence**:
The published tuple of a Controller instance's running Orchard version, supported dispatch-capacity contract version, indivisible all-consumers-ready declaration, and capability observation timestamp.
It is the evidence an enforcement cutover reads to decide whether every non-retired Controller can honor the contract.
_Avoid_: Node capability, feature flag, runtime telemetry, readiness probe

**Advisory Lock**:
A Postgres coordination lock used by Orchard for exclusive leadership and ownership of single-writer tasks.
_Avoid_: Distributed lock service

**Leader-only Write Path**:
A mutating operation that may execute only on the Active Leader in Active/Standby mode and must fail closed on a Standby Controller, and also on a configured leader that cannot prove it currently holds the advisory lock.
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
It is the current explicit first-party Controller-to-Node Runtime Endpoint compatibility and operator opt-out mode.
It does not name the separate Peer Grant/control or Worker Runtime gRPC boundaries, and any future reuse by a non-BEAM adapter requires its own accepted contract.
_Avoid_: Runtime Endpoint Interface, Worker Runtime Interface, Peer Grant control path, first-party BEAM mesh

**Worker Runtime Interface**:
The provider-neutral, versioned Node Agent-local execution process contract for readiness, model loading and unloading, inference streaming, cancellation, health, diagnostics, and normalized failures.
_Avoid_: Runtime Endpoint Interface, Public Inference API, provider API

**Node Lifecycle Interface**:
The first-party Orchard node management semantics for node identity, join, health observation, maintenance, drain, and decommissioning.
_Avoid_: Runtime Endpoint Interface, Worker Runtime Interface, scheduler ranking

**Orchard Console**:
The product-facing LiveView console for local and operator UI.
_Avoid_: Kapitan Orchard UI, admin panel

**Developer Portal**:
The Organization-scoped browser surface where an invited Portal User mints, lists, and revokes their own tenant-direct API Keys.
_Avoid_: Orchard Console, Admin API, public signup

**Orchard CLI**:
The `orchardctl` command-line interface for operator and admin automation.
_Avoid_: Shell scripts as product interface

### Governance

**Operator**:
A human or local administrative actor who configures, governs, or operates Orchard through Console, CLI, Operator API, or Admin API surfaces.
An Operator is not a Service Account, API Client, API Key, Tenant, or Portal User.
_Avoid_: Service Account, API Client, API Key, Tenant, Portal User

**Tenant**:
A governance boundary for model access, quotas, keys, retention, and usage accounting.
Product-facing label: Organization.
_Avoid_: Workspace, account, Service Account, API Key

**Team**:
A product-facing grouping label stored as API Client metadata for filtering, reporting, and ownership context inside an Organization.
_Avoid_: Tenant, Quota boundary, Routing Policy, RBAC Role

**Service Account**:
A non-interactive principal that may own API Tokens and tenant-scoped or cluster-scoped RBAC Roles.
Product-facing label: API Client.
_Avoid_: User account, Tenant, API Key, Team, Portal User

**Portal User**:
An interactive, Organization-scoped identity that may sign in only to the Developer Portal and own portal-minted tenant-direct API Keys.
A Portal User is not a Public Inference principal, Operator, Service Account, or Owner Contact.
_Avoid_: User account, Portal Developer, Tenant Admin, Owner Contact, Service Account

**Portal Invite**:
A single-use expiring token the operator issues and reissues with Copy invite from Console while the Portal User is invited.
Creating the Portal User issues no token and shows no invite URL.
Each Copy invite replaces any previous unused token.
Orchard stores only the hash.
_Avoid_: Persisted plaintext invite URL, magic link email, SMTP invite, Owner Contact

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
It may record a Portal User as minting-gate owner without changing the Public Inference principal.
_Avoid_: Service-account-owned API Key, Service Account, Owner Contact, Portal User as principal

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
A tenant setting that controls how much prompt and response payload data Orchard may retain, resolved into an effective mode that each Request snapshots for its whole lifetime.
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

**Inference Attempt**:
One bounded execution try within an Inference Turn, identified by its attempt number and execution target while remaining part of the same logical Request.
_Avoid_: Request, queue re-entry, Operator Retry

**Output Commitment**:
The irreversible point at which the Controller observes the first externally meaningful inference output for a Request: a non-empty text or structured-output delta, or any tool-call delta carrying its stable tool-call identity.
Accepted, progress, usage, empty text, and other control events do not create Output Commitment.
This boundary is normative in `SPEC.md` and applies identically to streaming and non-streaming requests.
_Avoid_: first network byte, Runtime Endpoint acceptance, first token only

**Automatic Attempt Retry**:
The single Controller-initiated second Inference Attempt allowed before Output Commitment for an explicitly retryable first-attempt failure, under the original Request identity and budgets, and only on a different eligible Node.
Its two-attempt bound, fail-closed gates, hard prior-Node exclusion, and original-deadline rule are normative in `SPEC.md` §§5.8-5.9.
_Avoid_: queue re-entry, Operator Retry, cohort retry, same-Node redispatch

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
A managed machine represented in Orchard's cluster inventory and running an enrolled first-party Node Agent.
The supported v1 Node runs under the Apple Silicon macOS platform profile and the macOS MLX Node runtime profile; Linux Node support is deferred and requires separately accepted platform and runtime-provider profiles.
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
A shared operator-facing status contract that separates lifecycle, admission, freshness, transport, runtime readiness, compatibility, scheduling, warnings, and control-plane read-only signals.
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

**Active-Node Liveness Monitor**:
The traffic-independent mechanism that tracks whether each active Node is still alive, so the Controller can distinguish a degraded cluster from a silently half-dead one, and an idle Node loss is detected without a request paying for discovery.
_Avoid_: inline request-path probe, readiness probe, Controller Membership Heartbeat

**Node Pool**:
A scheduling group where each v1 Node belongs to exactly one pool.
_Avoid_: Tenant, cluster

**Cordon**:
An operator action that prevents new scheduling to a Node while preserving existing work.
_Avoid_: Drain, Maintenance

**Drain**:
An operator action that cordons a Node and waits for active requests to finish or be cancelled by policy.
_Avoid_: Cordon only, Decommission

**Cancel Drain**:
An operator action that stops waiting for a drain to quiesce while the Node remains cordoned and unschedulable.
_Avoid_: Uncordon, Drain completion

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
The Node-owned active request count and concurrency bound for one Model Placement, reported through Runtime Endpoint Observations.
It may reduce placement eligibility but never increases aggregate authority beyond the Effective Dispatch Limit.
_Avoid_: Controller Dispatch Ceiling, aggregate Node capacity, Dispatch Headroom, durable capacity guarantee, queue lane capacity

**Model Bundle**:
An offline-importable model artifact directory or archive supplied to Orchard with a Model Manifest.
_Avoid_: Model Catalog record, Artifact Bundle after import

**Model Manifest**:
Structured metadata inside a Model Bundle describing identity, tokenizer, capabilities, memory estimates, and runtime requirements.
_Avoid_: Runtime status, hashed artifact contents

**Artifact Bundle**:
A filesystem copy and hash unit for model contents after Orchard validates and imports a Model Bundle.
_Avoid_: Model Manifest, Model Catalog record

**Qualification Tuple**:
The exact model checkpoint, quantization, tokenizer or renderer, Worker Runtime, Orchard revision, Artifact Bundle digest, hardware, operating system, configuration, topology, and tested capability envelope to which qualification evidence applies.
_Avoid_: model name alone, Catalog entry, loaded placement

**Model Qualification**:
Reviewed evidence for one Qualification Tuple and its tested capability envelope, independent of Catalog state, Tenant publication, and runtime availability.
_Avoid_: import success, loadedness, plausible response, support claim

**Support Claim**:
A published, capability-scoped summary of approved Model Qualification evidence, operating limits, and exclusions.
A Support Claim does not change Catalog state, Tenant publication, Model Placement state, or runtime behavior.
_Avoid_: unqualified supported-model statement, Catalog activation, pilot default

**Hold for Review**:
A Model Qualification outcome used when trustworthy evidence cannot support either approval or rejection because a named model defect, Orchard defect, environment deviation, or evidence gap blocks the decision.
_Avoid_: pass, support claim, silent failure

**Tested Capability Envelope**:
The exact interfaces, modes, input and output limits, sample counts, concurrency, serving mode, topology, configuration, and acceptance rules exercised by qualification evidence.
_Avoid_: manifest capability list, theoretical context window, untested support

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

**Runtime Concurrency Enforcement Limit**:
The Node-owned dynamic upper bound on concurrent runtime work that the Node will accept and enforce at a given time.
_Avoid_: advertised capacity, Controller concurrency limit, durable Node capacity, Controller Dispatch Ceiling, Placement Capacity

**Controller Dispatch Ceiling**:
The mandatory steady-state durable, operator-approved upper bound on concurrent work the Controller may allocate to an admitted production Node.
The bounded pre-F11 `shadow_legacy` policy has no ceiling, authorizes none of the new semantics, and is not a missing policy record.
_Avoid_: Admitted Capacity, runtime-managed capacity, nullable ceiling, inferred telemetry limit, Placement Capacity

**Effective Dispatch Limit**:
The aggregate limit the Controller may use after combining current Node runtime enforcement, durable Controller policy, and production eligibility.
_Avoid_: Admitted Capacity, runtime max concurrency, Controller Dispatch Ceiling, Dispatch Headroom, Placement Capacity, queue lane capacity

**Controller-accounted Allocation**:
The count of work the current Active Controller treats as occupying a Node's aggregate dispatch allocation.
_Avoid_: runtime active request count, worker occupancy, durable dispatch permit, queue grant, Placement Capacity

**Dispatch Headroom**:
The count of additional allocations the Controller may make within the Effective Dispatch Limit.
_Avoid_: Admitted Capacity, spare runtime slots, queue capacity, Placement Capacity, dispatch permit balance

**Temporary Legacy Claim**:
A Controller-local pre-cutover claim for one serialized temporary dispatch slot while legacy capacity behavior remains active.
It is not Controller-accounted Allocation, Dispatch Headroom, or a durable dispatch permit.
_Avoid_: queue slot, reservation, Controller-accounted Allocation, Dispatch Headroom, durable dispatch permit

**Dispatch Capacity Policy State**:
The per-Node durable state, `shadow_legacy`, `approved_explicit`, or `enforcing`, that records whether a Controller Dispatch Ceiling is absent for bounded migration, approved but not live authority, or enforcing.
_Avoid_: Dispatch Capacity Enforcement Phase, feature flag, migration phase, Node Lifecycle State

**Dispatch Capacity Enforcement Phase**:
The single durable cluster-wide phase, `pre_cutover` or `enforcing`, that decides whether Controller Dispatch Ceilings are recorded policy or live allocation authority.
While the phase is `pre_cutover`, an approved ceiling including `0` is not yet allocation authority.
_Avoid_: feature flag, per-Node toggle, Dispatch Capacity Policy State, migration flag

**Capacity Management Class**:
The Controller-owned classification of a target as `production_managed` through admitted inventory, or as explicitly unmanaged for source development or compatibility.
Absent, malformed, or conflicting classification fails closed for production dispatch rather than normalizing to legacy behavior.
_Avoid_: transport mode, node role, environment, deployment mode

**Capacity Authority Decision**:
The single outcome of the shared capacity evaluation, `legacy_pre_cutover`, `f11_enforcing`, `unmanaged_source_development`, `unmanaged_compatibility`, or `fail_closed`, that names which capacity contract bounds a target and supplies its decision-specific available slots.
A production-managed target dispatches only under `legacy_pre_cutover` or `f11_enforcing`, an unmanaged target only under its matching unmanaged decision, and `fail_closed` never authorizes dispatch.
_Avoid_: Capacity Management Class, Dispatch Capacity Enforcement Phase, Dispatch Capacity Policy State, Scheduler Reason Code

**Counterfactual Capacity Diagnostics**:
The read-only report of what the shared capacity evaluation would decide if F11 enforcement were live, exposed while the durable phase is still `pre_cutover`.
It is observability, never authorization, and it is distinct from the authorization the named capacity consumers actually perform.
_Avoid_: dry-run enforcement, shadow enforcement, simulated dispatch, capacity forecast

**Controller Allocation Authority**:
The single serialized Controller-local owner of a Node's live dispatch claims, its claim revalidation, and its Node Acceptance Gate, which every named capacity consumer authorizes through instead of deriving capacity itself.
It is Controller-local and process-lifetime scoped: it holds no durable dispatch permit and provides no leadership fencing.
_Avoid_: durable dispatch permit, leader epoch, queue lane, scheduler, Controller Dispatch Ceiling

**Node Acceptance Gate**:
The Controller-local per-Node serialization point that per-Node capacity policy mutation and final dispatch revalidation both hold, so either Node acceptance or the policy change happens first without an authority gap.
It is held from the final shared evaluation through Node acceptance or pre-acceptance failure, and it is not distributed leadership fencing.
_Avoid_: advisory lock, leader epoch, durable dispatch permit, queue lane, cluster transition barrier

**Unresolved Execution Quarantine**:
The Controller-local per-Node block applied when a dispatch cannot establish whether its runtime execution ended, after which every capacity evaluation for that Node is treated as unreachable instead of as free capacity.
It does not expire and is never lifted by an operator override; today it clears only when the Controller restarts, and audited release after verified reconciliation is a later slice.
_Avoid_: Cordon, Drain, Node Circuit Breaker, Maintenance, Node Health

**Capacity Consumer Readiness**:
The Controller capability declaration that this running build wires all five named capacity consumers to the shared evaluation as one indivisible contract-versioned capability.
It is proved against an exact consumer manifest, an exact contract version, and a shared deterministic conformance fixture, and it gates enforcement cutover rather than describing the current phase.
_Avoid_: Dispatch Capacity Enforcement Phase, Dispatch Capacity Policy State, feature flag, health check

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
A scheduler outcome meaning joined live Runtime Endpoint candidates were evaluated, but none can currently accept the request.
That includes aggregate endpoint or placement capacity exhaustion, unknown placement capacity for already-active candidates, and coherent all-rejected outcomes whose rejected candidates carry stable reason codes (for example missing artifact, identity mismatch, or authorization denial).
With queue admission enabled, capacity exhaustion can return the request to the same Queue deadline; otherwise it is a tenant-facing `503` capacity failure.
_Avoid_: Transport failure, model not found, queue full

**Model Busy**:
A no-target fallback scheduling outcome meaning the requested model path cannot accept the request.
It is reserved for the SingleNode fallback path and proven requested-model capacity exhaustion there.
Configured-target saturation and multi-candidate rejection report Cluster Busy uniformly, with scheduler explanations carrying the specific reason codes.
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
Node-owned Runtime Endpoint Observation data describing aggregate runtime occupancy and enforcement limits for one endpoint-backed Node.
It is an input to Controller capacity evaluation, not durable Controller policy or Controller allocation accounting.
_Avoid_: Tenant quota, Controller Dispatch Ceiling, Effective Dispatch Limit, Controller-accounted Allocation, model-specific capacity

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

**Product Version**:
The canonical semantic version that identifies an Orchard development line, release candidate, or final release.
_Avoid_: build number, Git SHA, component package version

**Build Provenance**:
The evidence that distinguishes one Orchard build by its source, channel, build sequence, components, verification, and artifact identities.
_Avoid_: Product Version, release notes

**Release Line**:
An explicitly approved Orchard compatibility family identified by a product-version major and minor pair.
_Avoid_: Milestone, numerically inferred previous version

**Previous Supported Release Line**:
The one explicitly named earlier Release Line that the current Controller release must support for Node Agent compatibility.
_Avoid_: automatic minor-version subtraction, every historical release

**Release Candidate**:
A pre-final Orchard Product Version whose ordered `rc` identifier names its maturity relative to the corresponding final version.
_Avoid_: Candidate, development build, GitHub draft

**Candidate**:
One immutable signed version tag, source commit, and Release Channel that is eligible for governed Orchard artifact construction.
_Avoid_: untagged build, mutable channel promotion, GitHub draft

**Verified Candidate**:
A Candidate whose final artifact identities and required evidence are sealed in an immutable Candidate Manifest.
_Avoid_: published release, successful build attempt

**Release Channel**:
The complete contract for a release audience, eligible version form, required artifacts, verification level, publication surfaces, and completion condition.
_Avoid_: build metadata only, deployment environment

**Candidate Manifest**:
The immutable machine-readable identity and verification record for one Verified Candidate.
_Avoid_: mutable release status, checksum sidecar, State Attestation

**State Attestation**:
Append-only evidence of a release approval, attempt, surface observation, or state transition for one Candidate Manifest.
_Avoid_: Candidate Manifest, mutable current-state field

**Promotion**:
The movement of exact Verified Candidate bytes to a required release surface without rebuilding, resigning, or repackaging them.
_Avoid_: rebuild, artifact replacement

**Partially Published Release**:
A release for which at least one required publication surface is live while another required surface remains incomplete.
_Avoid_: Published Release, Draft, failed build

**Delivered Distribution**:
A channel distribution that has reached every required restricted-delivery surface without representing a Published Release.
_Avoid_: Published Release, partial delivery, build completion

**Published Release**:
A release whose exact approved bytes have reached every publication surface required by its Release Channel.
_Avoid_: valid tag, Verified Candidate, one-surface publication

**Solo-owner Custodianship**:
The current operating model in which the Repository Owner holds all release, signing, publication, allocation, and trust-administration roles while preserving separate actions and evidence.
_Avoid_: two-person control, unrestricted manual release

**Single-owner Exception**:
A Candidate-bound authorization that permits Solo-owner Custodianship for one exact trial, pilot, or release distribution under mandatory compensating controls.
_Avoid_: permanent waiver, reusable approval, two-person control

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

**Node Enrollment Bundle**:
A per-Node, versioned, short-lived bootstrap artifact containing Controller and cluster identity, a Controller trust pin, and one one-time Bootstrap Token.
It is sensitive One-time Secret Output but is not durable Node identity, Node Admission, or runtime transport authority.
_Avoid_: BEAM cookie bundle, admission bundle, worker credential bundle, Node Certificate, cluster-admin credential

**Node Certificate**:
A Node's durable cryptographic identity anchor used for certificate-authenticated internal trust and renewal.
It is necessary but not sufficient for production BEAM authorization.
_Avoid_: Bootstrap Token, API Key, BEAM Peer Grant, Public HTTPS certificate

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

**DMG Installer**:
The approved interactive deployment artifact for the macOS Native Distribution Profile whose primary artifact is a verified `Orchard.app` that owns the root-authorized service lifecycle.
Native PKG is not a supported current Orchard distribution channel.
_Avoid_: native package installer, launchd service, Distribution Profile

**LaunchDaemon**:
A launchd-managed system daemon for Orchard system services such as the Controller, Node Agent, and, when Managed Database Mode is enabled, Postgres.
_Avoid_: installer package, Worker Runtime, Tray/Menu Bar App

**LaunchAgent**:
A launchd-managed user agent that starts the Tray/Menu Bar App in a user context.
_Avoid_: LaunchDaemon, system service

**Tray/Menu Bar App**:
The local macOS app for status, onboarding, logs, and support-bundle entry.
_Avoid_: Orchard Console, LaunchDaemon

**Install Role**:
The app lifecycle selection that determines whether one Mac installs and manages the `all`, `controller`, or `node-agent` service set.
_Avoid_: RBAC Role, Access Level, Node Lifecycle State

**BEAM Peer Grant Store Lock**:
The operation-scoped lock used by `Orchard.Node.BeamPeerGrantStore` to serialize one BEAM Peer Grant install or load operation, including atomic publication when installing in the owner-only Node Identity Root.
It ends with that store operation and does not establish process-lifetime ownership or a managed replacement protocol.
_Avoid_: Node Identity Root ownership, Postgres leadership lock

**Node Enrollment**:
The identity bootstrap process that uses a Node Enrollment Bundle to move one provisioned Node to registered state through Controller validation and Node Certificate issuance.
_Avoid_: Node Admission, Runtime Endpoint discovery, Worker Runtime enrollment
