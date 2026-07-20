# runtime-endpoints Specification

## Purpose
Define how Orchard models, observes, and communicates with the execution targets that serve inference work.
A Runtime Endpoint is the transport-independent boundary between the Controller and node-local execution, with the first-party Node Agent as the v1 endpoint, BEAM Distribution as the promoted default split-role source-dev and packaged external-sites transport, and gRPC retained as a compatibility adapter.
These requirements govern the Runtime Endpoint Interface, transport selection and guardrails, observations and placement capacity, and the source-dev operating model.

## Requirements
### Requirement: Runtime Endpoint Scheduling Boundary
Orchard SHALL model the Controller-selected execution target as a Runtime Endpoint.
The first-party v1 Runtime Endpoint SHALL be the Node Agent.
A Runtime Endpoint MUST NOT be assumed to be a managed Orchard Node.
This changes the topology and scheduler language currently described in `SPEC.md` sections 1.2, 1.3, 4, 5, and 7.5.

#### Scenario: First-party Node Agent endpoint is selected
- **WHEN** the Scheduler selects an Orchard-managed Apple Silicon Mac for inference work
- **THEN** the selected execution target is represented as the Node Agent Runtime Endpoint for that Node

#### Scenario: Future external endpoint is not a Node
- **WHEN** a future provider-backed Runtime Endpoint is available to the Scheduler
- **THEN** the endpoint is schedulable through Runtime Endpoint semantics without being represented as a managed Orchard Node

### Requirement: Transport-independent Runtime Endpoint Interface
Orchard SHALL define a transport-independent Runtime Endpoint Interface for model readiness, inference execution, cancellation, status, runtime telemetry, Placement Capacity, and scheduler observations.
The Controller MUST depend on Runtime Endpoint semantics rather than direct gRPC/protobuf message semantics for scheduler and dispatch domain code.
This wraps the current first-party use of `NodeRuntimeService` in `SPEC.md` section 7.5 behind a compatibility adapter while preserving its logical operations.

#### Scenario: Controller requests inference through interface semantics
- **WHEN** the Controller dispatches an inference request to a first-party Node Agent
- **THEN** the dispatch uses Runtime Endpoint Interface operations for readiness, execution, streaming events, and cancellation

#### Scenario: Transport adapter changes without semantic change
- **WHEN** the first-party transport changes from gRPC to BEAM Distribution
- **THEN** model readiness, inference execution, cancellation, status, and runtime telemetry semantics remain unchanged at the Runtime Endpoint Interface

### Requirement: First-party BEAM Transport Guardrails
Orchard SHALL validate first-party BEAM Distribution guardrails before production BEAM Runtime Endpoint transport can be enabled.
First-party Orchard Runtime Endpoints MAY use BEAM Distribution as a default-off live communication and monitoring layer between admitted Elixir services.
Production BEAM Distribution MUST be explicitly configured, identity-bound, network-restricted, and limited to admitted first-party Orchard services.
External Runtime Endpoints MUST NOT join the first-party BEAM mesh.
This changes the base `SPEC.md` section 1.2 language that forbids distributed Erlang across machines and requires all cross-node control traffic to use gRPC over mTLS.

#### Scenario: First-party BEAM endpoint is enabled
- **WHEN** an admitted first-party Node Agent participates in production runtime communication through the BEAM adapter
- **THEN** it communicates with the Controller only through explicitly configured first-party BEAM transport
- **THEN** the Controller still records durable Runtime Endpoint Observations in Postgres

#### Scenario: BEAM target identity is validated
- **WHEN** a configured BEAM Runtime Endpoint target has a node-name address and node identity
- **THEN** the address is validated as a BEAM node name
- **THEN** the node identity is validated as a UUID
- **THEN** scheduler and dispatch trust the identity only when observed endpoint metadata matches the configured identity

#### Scenario: External endpoint remains outside BEAM mesh
- **WHEN** a future provider-backed Runtime Endpoint is configured
- **THEN** it integrates through a Runtime Endpoint adapter
- **THEN** it does not join first-party BEAM Distribution

### Requirement: Postgres Durable Runtime Truth
Postgres SHALL remain Orchard's durable persistence and coordination store for inventory, lifecycle state, Runtime Endpoint Observations, request state, scheduling decisions, and operator-visible history.
BEAM Distribution MUST NOT be treated as durable cluster truth.
This preserves the durable coordination model described in `SPEC.md` sections 1.2, 3.3, and 3.7.

#### Scenario: Live BEAM session exists
- **WHEN** a first-party Node Agent has a live BEAM session with the Controller
- **THEN** the Node Agent is not automatically schedulable
- **THEN** scheduler eligibility still depends on durable policy, lifecycle state, availability, and fresh Runtime Endpoint Observations

#### Scenario: Controller restarts
- **WHEN** the Controller restarts after live BEAM sessions are lost
- **THEN** durable request, node, endpoint, and scheduling state is recovered from Postgres

### Requirement: Runtime Endpoint Observations
The Controller SHALL record Runtime Endpoint Observations as durable snapshots of endpoint status, capability, availability, Placement Capacity, and placement signals.
Runtime Endpoint Observations SHALL be transport-independent.
This replaces the current first-party dependence on `StatusResponse` as the active observation seam in `SPEC.md` sections 4.6.1 and 7.5.

#### Scenario: First-party status is observed
- **WHEN** a Node Agent reports runtime status through the Runtime Endpoint Interface
- **THEN** the Controller records a Runtime Endpoint Observation in Postgres using transport-independent fields

#### Scenario: Transport-specific field is absent
- **WHEN** a first-party BEAM Runtime Endpoint reports status without protobuf fields
- **THEN** the Controller still records equivalent Runtime Endpoint Observation data

#### Scenario: Address-only BEAM observation lacks persisted identity proof
- **WHEN** a BEAM Runtime Endpoint Observation is recorded from a target that cannot resolve back to the same persisted node identity
- **THEN** the Controller does not publish queue capacity from that observation
- **THEN** stale queue capacity sources for the unresolved target remain unavailable for promotion

### Requirement: Bounded Aggregate Runtime Capacity Evidence
Orchard SHALL persist at most one current aggregate runtime capacity evidence row per admitted Node.
The row SHALL preserve the latest trusted authenticated observation time, raw normalized runtime maximum concurrency, raw normalized active request count, and validity state.
A newer authenticated observation SHALL replace older evidence atomically, and an older or unauthenticated observation MUST NOT overwrite it.
Missing or malformed runtime values SHALL remain missing or invalid and MUST NOT be durably normalized to maximum `1`, active count `0`, or a Controller Dispatch Ceiling.
This requirement traces to `SPEC.md` §4.6.2 and §7.5.3.

#### Scenario: Newer trusted observation replaces current evidence
- **WHEN** a trusted authenticated Runtime Endpoint Observation is newer than the current evidence for its admitted Node
- **THEN** Orchard replaces the aggregate capacity values, validity state, and observation time in one write
- **AND** the Node still has exactly one current aggregate evidence row

#### Scenario: Stale observation cannot overwrite evidence
- **WHEN** an authenticated observation is older than the current aggregate evidence
- **THEN** Orchard retains the newer row unchanged

#### Scenario: Malformed runtime limit is preserved as invalid
- **WHEN** a trusted observation has a missing, non-integer, zero, or negative aggregate runtime maximum
- **THEN** Orchard persists invalid or missing evidence rather than maximum `1`
- **AND** counterfactual enforcing evaluation fails closed for runtime-limit uncertainty

#### Scenario: Telemetry never becomes policy
- **WHEN** a trusted observation reports aggregate runtime maximum `8`
- **THEN** Orchard may persist `8` as Node-owned runtime evidence
- **AND** Orchard does not create or change a Controller Dispatch Ceiling from that value

### Requirement: Controller-Owned Capacity Management Classification
Orchard SHALL normalize a Runtime Endpoint target's capacity management class from Controller-owned configuration and admitted inventory before shared capacity evaluation.
A target that resolves to admitted production inventory SHALL be `production_managed` regardless of transport or a conflicting unmanaged declaration.
An unmanaged source-development or compatibility class SHALL require explicit mode-valid Controller configuration and MUST NOT be inferred from Node telemetry, transport, address, or probe failure.
Capacity management classification SHALL NOT by itself authorize dispatch, create an unmanaged exception, or relax production fail-closed behavior required by `SPEC.md` §4.6.2.
This requirement traces to `SPEC.md` §4.6.2 and §7.5.

#### Scenario: Admitted gRPC target remains production managed
- **WHEN** a gRPC compatibility target resolves to an admitted production Node
- **THEN** the normalized class is `production_managed`
- **AND** counterfactual diagnostics apply the production fail-closed contract

#### Scenario: Missing unmanaged declaration is invalid
- **WHEN** a target does not resolve to admitted inventory and has no explicit mode-valid management class
- **THEN** classification is invalid
- **AND** diagnostics expose `runtime_endpoint_management_class_missing`
- **AND** Orchard does not infer an unmanaged class from successful or failed probing

### Requirement: Placement Capacity Observation
Placement Capacity SHALL be a first-class Runtime Endpoint Observation for Model Placements.
Placement Capacity SHALL include the model reference, active request count, and maximum concurrency for the placement.
Unknown, malformed, duplicate, or nonmatching Placement Capacity MUST NOT prove scheduler eligibility for an active loaded placement.
This preserves and generalizes the incoming `gnhf/objective-fully-impl-369718` `runtime_model_placements` behavior added around `SPEC.md` sections 4.6.1, 5.7, and 7.5.

#### Scenario: Active loaded placement has spare capacity
- **WHEN** exactly one matching Placement Capacity observation reports `active_request_count < max_concurrency`
- **THEN** the Scheduler may keep that active loaded placement eligible for the requested work

#### Scenario: Active loaded placement has unknown capacity
- **WHEN** Placement Capacity is absent, malformed, duplicate, or nonmatching for an active loaded placement
- **THEN** the Scheduler does not treat that placement as eligible based on capacity

#### Scenario: Active loaded placement is full
- **WHEN** matching Placement Capacity reports `active_request_count >= max_concurrency`
- **THEN** the Scheduler treats that placement as currently unavailable for new work

### Requirement: Cluster Busy Runtime Capacity Semantics
Orchard SHALL retain the `cluster_busy` outcome name for now.
`cluster_busy` SHALL mean live Runtime Endpoints exist, but no eligible Runtime Endpoint currently has capacity for the requested work.
Queue-enabled `cluster_busy` after a queue grant SHALL be treated as waitable live Placement Capacity exhaustion under the original queue deadline.
Queue-disabled `cluster_busy` SHALL remain an immediate failure.
This preserves the incoming `gnhf/objective-fully-impl-369718` behavior around `SPEC.md` sections 5.4, 7.2.7, and 7.5.

#### Scenario: Queue-enabled capacity exhaustion requeues
- **WHEN** a queue-enabled request receives a queue grant and scheduling returns `cluster_busy`
- **THEN** the Controller returns the request to the same queue lane under the original max queue wait deadline

#### Scenario: Queue wait expires after cluster busy
- **WHEN** no eligible Runtime Endpoint capacity appears before the original queue deadline
- **THEN** the request terminates with `queue_timeout`

#### Scenario: Queue disabled cluster busy
- **WHEN** queue admission is disabled and scheduling returns `cluster_busy`
- **THEN** the request fails immediately with the existing `cluster_busy` public error mapping

### Requirement: Runtime Orchestration Failure Terminalization
After a durable request reaches validation, scheduler or dispatch orchestration failures SHALL terminalize the request instead of leaving it active.
The durable request SHALL fail with `error_code = "orchestration_error"` and `error_message = "Runtime orchestration failed"`.
Public HTTP and SSE error payloads SHALL stay sanitized with `internal_error`.
Runtime Endpoint disconnect cleanup failures SHALL be logged best-effort and MUST NOT overwrite an otherwise successful scheduler probe or dispatch result.

#### Scenario: Scheduler crashes after validation
- **WHEN** a validated request encounters an exception, exit, throw, or invalid return from the scheduler
- **THEN** the request reaches terminal state `failed`
- **THEN** no scheduled request state is required
- **THEN** the public error payload is generic

#### Scenario: Dispatch crashes after scheduling
- **WHEN** a scheduled request encounters an exception, exit, throw, or invalid return from dispatch
- **THEN** the request reaches terminal state `failed`
- **THEN** the request retains scheduled and dispatching lifecycle evidence when those states were reached
- **THEN** the public error payload is generic

#### Scenario: Runtime Endpoint cleanup fails
- **WHEN** a scheduler probe or dispatch attempt has already produced its operation result
- **AND** disconnect cleanup fails
- **THEN** Orchard keeps the operation result
- **THEN** cleanup failure is logged best-effort

### Requirement: Worker Runtime Boundary Preservation
The Worker Runtime Interface SHALL remain separate from the Runtime Endpoint Interface.
The Node Agent SHALL continue to own local Worker Runtime lifecycle, model loading, active request accounting, cancellation, diagnostics, and cleanup.
This preserves `SPEC.md` sections 4.9, 4.10, and 7.5.2a.

#### Scenario: Python MLX worker is used
- **WHEN** a first-party Node Agent executes work through a Python/MLX Worker Runtime
- **THEN** the Worker Runtime remains local to the Node Agent
- **THEN** the Controller communicates with the Node Agent Runtime Endpoint rather than directly supervising the Worker Runtime

### Requirement: gRPC Compatibility Demotion
The existing `proto/cluster/v1` and `NodeRuntimeService` artifacts SHALL be demoted from the default first-party Controller-to-Node Agent path to a possible adapter or compatibility protocol.
They MUST NOT be deleted solely because the first-party path becomes BEAM-first.
This changes the role of the gRPC contract currently described in `SPEC.md` section 7.5.

#### Scenario: First-party path is BEAM-first
- **WHEN** the first-party Runtime Endpoint implementation uses BEAM Distribution
- **THEN** `proto/cluster/v1` is not required for default first-party Controller-to-Node Agent communication

#### Scenario: Future adapter uses gRPC
- **WHEN** a future Runtime Endpoint adapter needs a stable non-BEAM protocol
- **THEN** the existing gRPC/protobuf work may be reused or evolved as an adapter protocol

### Requirement: Source-dev BEAM Primary Rollout
Orchard SHALL treat the first-party BEAM Runtime Endpoint adapter as promoted to the split-role source-dev Controller-to-Node Agent default, following accepted two-Mac smoke evidence for the adapter.
The gRPC compatibility path SHALL remain available for split-role source dev only through the explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out on port `50071`, and it SHALL NOT act as an automatic same-request fallback when BEAM mode is active.

#### Scenario: BEAM adapter is promoted after accepted smoke evidence
- **WHEN** accepted two-Mac smoke evidence exists for the BEAM Runtime Endpoint adapter
- **THEN** the BEAM Runtime Endpoint transport is the promoted split-role source-dev Controller-to-Node Agent default
- **THEN** the gRPC compatibility path remains reachable only through the explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out

#### Scenario: Source-dev smoke gate is evaluated
- **WHEN** the accepted two-Mac source-dev smoke is run
- **THEN** Console Nodes shows local and remote Node Agents reachable
- **THEN** `GET /v1/models` returns `200`
- **THEN** `POST /v1/chat/completions` completes through the Console Playground or an equivalent API request

### Requirement: Packaged BEAM External-sites Runtime Default
Packaged controller releases SHALL default to BEAM Runtime Endpoint transport when `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` is unset.
Packaged controller releases SHALL require `ORCHARD_RUNTIME_ENDPOINT_TARGETS` with BEAM node-name targets in BEAM mode.
Packaged controller releases SHALL reject remote BEAM targets when `ORCHARD_BEAM_NODE_NAME` uses a loopback controller host.
Packaged controller releases SHALL treat `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` as the explicit compatibility fallback and SHALL use `ORCHARD_RUNTIME_CLIENT_TARGETS` only in that fallback mode.
Packaged node-agent releases SHALL start as BEAM-reachable node agents in BEAM mode and SHALL disable BEAM distribution in explicit gRPC fallback mode.
Packaged BEAM cookie provisioning SHALL be operator-managed and SHALL use a root-owned mode `0600` shared cookie file.
Node join, admission, certificate bundle, and generated config bundle flows SHALL remain deferred for this packaged external-sites phase.

#### Scenario: Packaged controller default uses BEAM
- **WHEN** an Orchard controller release starts without `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT`
- **THEN** it treats BEAM as the Runtime Endpoint transport
- **THEN** it requires `ORCHARD_RUNTIME_ENDPOINT_TARGETS` to contain one or more `orchard_node_agent@<worker-ipv4>` BEAM targets
- **THEN** the legacy gRPC runtime client target surface is not configured as the active scheduling path

#### Scenario: Packaged remote targets require non-loopback controller identity
- **WHEN** a packaged controller starts in BEAM mode with a remote `orchard_node_agent@<worker-ipv4>` target
- **AND** `ORCHARD_BEAM_NODE_NAME` still uses `orchard_controller@127.0.0.1`
- **THEN** Orchard rejects startup before treating the remote target as schedulable

#### Scenario: Packaged node agent starts with BEAM identity
- **WHEN** an Orchard node-agent release starts in default packaged mode
- **THEN** it starts with BEAM distribution enabled
- **THEN** its BEAM node name uses the `orchard_node_agent@<worker-ipv4>` service and host form
- **THEN** it reads shared cookie material from `ORCHARD_BEAM_COOKIE_FILE` or the packaged default cookie path

#### Scenario: Packaged gRPC fallback is explicit
- **WHEN** a packaged operator sets `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`
- **THEN** Orchard uses the legacy gRPC compatibility target configuration
- **THEN** packaged BEAM release identity and cookie settings are not required for that fallback run

### Requirement: Source-dev BEAM Split-role Bootstrap
Orchard SHALL support Source-dev BEAM Runtime Endpoint mode first for the split-role `bin/dev-controller` and `bin/dev-node-agent` entrypoints.
When Source-dev BEAM mode is selected, both split-role processes SHALL start as named distributed BEAM nodes before Runtime Endpoint work is attempted.
All-in-one `bin/dev` SHALL remain on the gRPC compatibility default.
All-in-one `bin/dev` SHALL reject explicit Source-dev BEAM mode before starting Mix.
This refines the source-dev BEAM rollout rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: Split-role BEAM mode starts distributed nodes
- **WHEN** a contributor starts `bin/dev-controller` and `bin/dev-node-agent` with Source-dev BEAM Runtime Endpoint mode selected
- **THEN** each process starts with a configured BEAM node name
- **THEN** Runtime Endpoint operations use BEAM Distribution rather than the gRPC Compatibility Adapter

#### Scenario: All-in-one dev default is unchanged
- **WHEN** a contributor starts all-in-one `bin/dev` without selecting Source-dev BEAM mode
- **THEN** Orchard keeps using the current gRPC compatibility runtime transport on source-dev port `50071`

#### Scenario: All-in-one dev rejects BEAM mode
- **WHEN** a contributor starts all-in-one `bin/dev` with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`
- **THEN** Orchard rejects the launch before running Mix
- **THEN** the contributor is directed to use `bin/dev-controller` and `bin/dev-node-agent`

### Requirement: Source-dev BEAM Node Names
Source-dev BEAM node names SHALL use long-name format with IPv4-literal host parts for guarded BEAM Runtime Endpoint targets.
Controller nodes SHALL use role-identifying services that start with `orchard_controller`, such as `orchard_controller@<ipv4>`.
Node Agent nodes SHALL use the exact role-identifying service `orchard_node_agent`, such as `orchard_node_agent@<ipv4>`.
Source-dev BEAM target hostnames SHALL be rejected until hostname resolution and CIDR guardrail behavior are specified in a later change.
Source-dev BEAM IPv6 target hosts SHALL be rejected until IPv6 distribution launch flags and guardrail behavior are specified in a later change.
This refines BEAM Runtime Endpoint target rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: BEAM target uses IPv4-literal host
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TARGETS` contains `orchard_node_agent@100.64.1.10` in Source-dev BEAM mode
- **THEN** Orchard accepts the target as a BEAM node-name address for guardrail validation

#### Scenario: BEAM target uses hostname host
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TARGETS` contains `orchard_node_agent@worker.local` in Source-dev BEAM mode
- **THEN** Orchard rejects the target configuration before treating it as a schedulable Runtime Endpoint

### Requirement: Source-dev BEAM Cookie Material
Source-dev BEAM mode SHALL use explicit shared cookie material from `ORCHARD_BEAM_COOKIE_FILE`.
Same-host source dev SHALL be allowed to create a repo-local `tmp/dev/beam.cookie` file when no explicit cookie file exists.
Two-Mac source dev SHALL require identical cookie material to be provisioned on both Macs before BEAM Runtime Endpoint communication is used.
Cookie files MUST have mode `0600` or stricter, and Orchard MUST NOT print cookie contents in logs, templates, diagnostics, or startup output.
Ambient `$HOME/.erlang.cookie` MUST NOT be required for Source-dev BEAM mode.
This refines the first-party BEAM Distribution rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: Same-host cookie file is generated
- **WHEN** Source-dev BEAM mode starts on a single host with no `ORCHARD_BEAM_COOKIE_FILE` set and no existing repo-local cookie file
- **THEN** Orchard generates `tmp/dev/beam.cookie` with mode `0600`
- **THEN** startup output may show the cookie file path but not the cookie contents

#### Scenario: Cookie file has strict permissions
- **WHEN** Source-dev BEAM mode starts with `ORCHARD_BEAM_COOKIE_FILE` pointing to a readable file whose mode is `0600`
- **THEN** Orchard uses that file as the source-dev BEAM cookie material
- **THEN** startup output may show the cookie file path but not the cookie contents

#### Scenario: Cookie file permissions are weak
- **WHEN** Source-dev BEAM mode starts with `ORCHARD_BEAM_COOKIE_FILE` pointing to a file that is readable by group or world
- **THEN** Orchard rejects the BEAM startup configuration before Runtime Endpoint work is attempted

#### Scenario: Two-Mac cookie material differs
- **WHEN** the Controller and Node Agent are started in Source-dev BEAM mode with different cookie material
- **THEN** the BEAM connection fails visibly
- **THEN** Orchard does not retry the same Runtime Endpoint operation through gRPC automatically

### Requirement: Source-dev BEAM Distribution Networking
Source-dev BEAM mode SHALL define explicit distribution networking settings.
`ORCHARD_BEAM_EPMD_PORT` SHALL select the source-dev EPMD port and SHALL default to `4369` when unset.
`ORCHARD_BEAM_DIST_PORT_MIN` and `ORCHARD_BEAM_DIST_PORT_MAX` SHALL bound the BEAM distribution listener port range.
When unset, the controller distribution listener range SHALL default to `52171..52171` and the node-agent distribution listener range SHALL default to `52172..52172`.
The two-Mac smoke procedure SHALL document reachability requirements for EPMD and the configured distribution listener range.
This refines Runtime Endpoint transport requirements in `SPEC.md` §1.2 and §7.5.

#### Scenario: EPMD and distribution ports are configured
- **WHEN** Source-dev BEAM mode starts with `ORCHARD_BEAM_EPMD_PORT`, `ORCHARD_BEAM_DIST_PORT_MIN`, and `ORCHARD_BEAM_DIST_PORT_MAX` set
- **THEN** Orchard starts the BEAM node with the selected EPMD port and bounded distribution listener range

#### Scenario: Distribution port range is invalid
- **WHEN** Source-dev BEAM mode starts with a distribution port minimum greater than the maximum
- **THEN** Orchard rejects the BEAM startup configuration before Runtime Endpoint work is attempted

### Requirement: Source-dev Runtime Endpoint Env Surface
Source-dev Runtime Endpoint transport selection SHALL use `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT`.
Controller Source-dev BEAM Runtime Endpoint targets SHALL come from `ORCHARD_RUNTIME_ENDPOINT_TARGETS` and SHALL use BEAM node-name addresses.
Source-dev BEAM node bootstrap SHALL use `ORCHARD_BEAM_NODE_NAME`, `ORCHARD_BEAM_COOKIE_FILE`, `ORCHARD_BEAM_DIST_PORT_MIN`, `ORCHARD_BEAM_DIST_PORT_MAX`, and `ORCHARD_BEAM_EPMD_PORT`.
`ORCHARD_RUNTIME_CLIENT_TARGETS` SHALL remain scoped to gRPC Compatibility Adapter `host:port` targets and SHALL NOT be interpreted as BEAM Runtime Endpoint targets.
This refines the transport-independent Runtime Endpoint target rules in `SPEC.md` §1.2, §4.6.1, and §7.5.

#### Scenario: BEAM targets are read from Runtime Endpoint targets
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` and `ORCHARD_RUNTIME_ENDPOINT_TARGETS` contains BEAM node names
- **THEN** Orchard configures the BEAM Runtime Endpoint adapter with those targets
- **THEN** Orchard does not require `ORCHARD_RUNTIME_CLIENT_TARGETS` for BEAM Runtime Endpoint selection

#### Scenario: Legacy gRPC targets remain compatibility-only
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` and `ORCHARD_RUNTIME_CLIENT_TARGETS` is also set
- **THEN** Orchard treats `ORCHARD_RUNTIME_CLIENT_TARGETS` only as an explicit gRPC compatibility target list
- **THEN** Orchard does not merge those `host:port` values into the BEAM Runtime Endpoint target list

### Requirement: Source-dev BEAM No Automatic gRPC Fallback
When Source-dev BEAM Runtime Endpoint mode is selected, BEAM configuration, connection, guardrail, target identity, or Runtime Endpoint RPC failure SHALL fail visibly on the BEAM path.
The same request MUST NOT silently retry through the gRPC Compatibility Adapter.
gRPC compatibility SHALL remain available only when explicitly selected as the runtime transport.
This refines the source-dev transport rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: BEAM connection fails
- **WHEN** Source-dev BEAM mode is selected and the configured Node Agent BEAM node is unreachable
- **THEN** Orchard reports the BEAM Runtime Endpoint failure visibly
- **THEN** Orchard does not execute the same request through gRPC automatically

#### Scenario: gRPC compatibility is explicitly selected
- **WHEN** a contributor selects the gRPC compatibility transport for source dev
- **THEN** Orchard uses the gRPC Compatibility Adapter target configuration
- **THEN** Source-dev BEAM target configuration is not required for that compatibility run

### Requirement: Source-dev BEAM Smoke Evidence Gate
Orchard SHALL gate Runtime Endpoint transport default promotions on durable two-Mac Source-dev BEAM smoke evidence.
The split-role source-dev BEAM default promotion executed after that evidence gate passed and is recorded in `docs/decisions/0001-runtime-endpoints-beam-first.md`.
The packaged external-sites BEAM default promotion SHALL rely on the same accepted smoke evidence requirement and SHALL record package-specific validation in its promotion pull request.
Future Runtime Endpoint transport default promotions beyond the accepted source-dev and packaged external-sites defaults SHALL remain gated on the same accepted smoke evidence requirement.
The evidence SHALL be recorded durably in sanitized form in the accepting change package, decision record, or promotion pull request; standalone investigation or evidence documents SHALL NOT be committed to the repository.
The evidence SHALL include date, commit, sanitized hosts, commands, controller and node-agent BEAM node names, remote Runtime Endpoint RPC evidence, Console Nodes reachability for local and remote Node Agents, `GET /v1/models` returning `200`, and `POST /v1/chat/completions` completing through Console Playground or an equivalent API request.
The evidence SHALL NOT include cookie material, credentials, raw local evidence logs, local tool session identifiers, or machine-specific filesystem paths.
This refines the accepted smoke language in `SPEC.md` §1.2 and §7.5.

#### Scenario: Smoke evidence is complete
- **WHEN** a two-Mac Source-dev BEAM smoke run records all required evidence durably in the accepting change package, decision record, or promotion pull request
- **THEN** Orchard may consider a separate change that promotes a Runtime Endpoint transport default

#### Scenario: Smoke evidence is absent for a proposed promotion
- **WHEN** no durable two-Mac Source-dev BEAM smoke evidence exists for a proposed Runtime Endpoint transport default promotion
- **THEN** that promotion does not proceed and the current default remains unchanged

### Requirement: Source-dev BEAM Scope Boundaries
Source-dev BEAM Operating Model behavior SHALL NOT make BEAM Distribution durable cluster truth.
Source-dev BEAM Operating Model behavior SHALL NOT allow external Runtime Endpoints to join the first-party BEAM mesh.
Source-dev BEAM Operating Model behavior SHALL NOT change the Node Agent to Worker Runtime boundary.
Packaged or release runtime configuration SHALL NOT inherit the repo-local source-dev cookie model.
This preserves the Runtime Endpoint and Worker Runtime boundaries in `SPEC.md` §1.2, §4.6.1, and §7.5.

#### Scenario: BEAM session is live
- **WHEN** a Source-dev BEAM Controller has a live connection to a Source-dev BEAM Node Agent
- **THEN** Postgres remains the durable source for inventory, lifecycle state, Runtime Endpoint Observations, scheduling history, request state, and operator-visible status

#### Scenario: Packaged runtime is configured
- **WHEN** a packaged or release Orchard runtime is configured
- **THEN** it does not use the repo-local `tmp/dev/beam.cookie` source-dev cookie model

### Requirement: Source-dev Split-role BEAM Transport Default
Source-dev split-role launches SHALL default to the BEAM Runtime Endpoint transport.
`bin/dev-controller` and `bin/dev-node-agent` SHALL behave as if `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` when the variable is unset.
The gRPC compatibility transport SHALL remain available only through explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
This changes the source-dev default transport language currently described alongside `SPEC.md` section 7.5 internal communications and the split-role guidance in `docs/local-dev.md`.

#### Scenario: Default split-role launch uses BEAM
- **WHEN** `bin/dev-controller` or `bin/dev-node-agent` starts without `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` set
- **THEN** the process configures the BEAM Runtime Endpoint transport and BEAM distribution settings

#### Scenario: Explicit gRPC opt-out preserved
- **WHEN** `bin/dev-controller` or `bin/dev-node-agent` starts with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`
- **THEN** the process configures the gRPC compatibility transport instead of the BEAM Runtime Endpoint default

### Requirement: BEAM Mode Quiesces the Legacy gRPC Client Surface
When the BEAM Runtime Endpoint transport is selected, the controller SHALL NOT configure a default legacy gRPC runtime client target.
The implicit `127.0.0.1:50071` or packaged `127.0.0.1:50061` runtime client target SHALL be absent from active scheduling in BEAM mode.
Explicitly set `ORCHARD_RUNTIME_CLIENT_TARGETS` values SHALL remain scoped to the gRPC compatibility surface and SHALL NOT become active Runtime Endpoint targets while BEAM Runtime Endpoint targets are configured.
Operators and contributors SHALL select `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` when they intend to use the gRPC compatibility path.

#### Scenario: BEAM mode without explicit gRPC targets
- **WHEN** the controller starts in BEAM mode without `ORCHARD_RUNTIME_CLIENT_TARGETS` set
- **THEN** no legacy gRPC runtime client target is configured or logged as active

#### Scenario: Explicit gRPC compatibility requires transport opt-out
- **WHEN** the controller starts in BEAM mode with `ORCHARD_RUNTIME_CLIENT_TARGETS` explicitly set
- **THEN** BEAM Runtime Endpoint targets remain the active scheduling surface
- **THEN** the explicit gRPC targets are not merged into the active Runtime Endpoint target list

### Requirement: All-in-one Source Dev Remains Single-host gRPC Loopback
All-in-one `bin/dev` SHALL keep its single-host gRPC loopback default and SHALL reject explicit BEAM mode with a clear error.
Split-role scripts SHALL remain the only supported source-dev BEAM entry points.

#### Scenario: All-in-one rejects explicit BEAM mode
- **WHEN** `bin/dev` starts with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`
- **THEN** startup fails with a clear error directing the operator to the split-role scripts
