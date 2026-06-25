## ADDED Requirements

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
Orchard SHALL validate first-party BEAM Distribution guardrails before any live BEAM Runtime Endpoint adapter can be enabled.
First-party Orchard Runtime Endpoints MAY use BEAM Distribution as a future live communication and monitoring layer between admitted Elixir services.
Production BEAM Distribution MUST be explicitly configured, identity-bound, network-restricted, and limited to admitted first-party Orchard services.
External Runtime Endpoints MUST NOT join the first-party BEAM mesh.
This changes the base `SPEC.md` section 1.2 language that forbids distributed Erlang across machines and requires all cross-node control traffic to use gRPC over mTLS.

#### Scenario: First-party BEAM endpoint is enabled later
- **WHEN** an admitted first-party Node Agent participates in production runtime communication through a future BEAM adapter
- **THEN** it communicates with the Controller only through explicitly configured first-party BEAM transport
- **THEN** the Controller still records durable Runtime Endpoint Observations in Postgres

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
