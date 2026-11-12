## ADDED Requirements

### Requirement: Operator API Serves Cluster And Node Reads

Orchard SHALL expose `GET /ops/v1/cluster`, `GET /ops/v1/nodes`, and `GET /ops/v1/nodes/:node_id` to an enabled API Client holding a cluster-scoped `operator` or `admin` RoleBinding.
The accepted, inactive `cluster_reader` target in `SPEC.md` §10.4 SHALL additionally admit those routes only through the [reader contract](../../../add-read-only-cluster-role/specs/read-only-cluster-role/spec.md), after its activation prerequisites. A reader-bearing principal without independently sufficient operator/admin authority for the action SHALL use the reader path regardless of other grants; existing sufficient grants remain additive.
Missing, malformed, invalid, expired, or revoked credentials SHALL return `401 invalid_api_key`.
Authenticated principals without either sufficient operator/admin authority or activated reader authority, including tenant-direct API Keys, tenant-scoped RoleBindings, API Clients with no cluster role, and tokens owned by a disabled API Client, SHALL return `403 operator_required`.
Responses SHALL be marked `no-store`.
The original operator/admin admission remains implemented; the accepted reader extension under `SPEC.md` §§7.3 and 10.4 remains pending implementation and verification in `add-read-only-cluster-role`.

#### Scenario: Tenant-direct key is refused

- **WHEN** a caller presents a tenant-direct API Key to `GET /ops/v1/nodes`
- **THEN** Orchard returns `403 operator_required`
- **AND** it returns no Node data

#### Scenario: Revoked token is refused

- **WHEN** a caller presents a revoked cluster-operator API Token to `GET /ops/v1/nodes/:node_id`
- **THEN** Orchard returns `401 invalid_api_key`
- **AND** it returns no Node data

### Requirement: Node Reads Execute In The Active Controller

`GET /ops/v1/nodes` and `GET /ops/v1/nodes/:node_id` read Controller-owned durable state and SHALL execute only in the active Controller, as `SPEC.md` §§2.5, 3.3, and 11.9 require.
They SHALL use the same write-path leadership check as Operator API breaker inspection: a Standby Controller SHALL return `503 controller_standby`, and a Controller whose leadership is configured but unproven SHALL return `503 controller_leadership_unproven`.
`GET /ops/v1/cluster` reports only the serving Controller's own control-plane evidence, like `GET /ops/v1/health`, and SHALL be served by any Controller, reporting its role under the `ControlPlaneStatus` rules.
For the reader path, the narrow `SPEC.md` §10.11.2 exception SHALL retain authoritative Postgres and common current caller/credential/grant fences even on Standby, and SHALL expose only bounded serving-Controller evidence and caller self-authority. Unavailable authority SHALL return `503 authority_unavailable` without cached success, replica or local Repo fallback; the exception does not extend to Node reads or credential-family inspection.

#### Scenario: Standby Controller refuses a Node read

- **WHEN** a cluster operator calls `GET /ops/v1/nodes` on a Standby Controller
- **THEN** Orchard returns `503 controller_standby`
- **AND** it returns no Node data

#### Scenario: Standby Controller answers a cluster read

- **WHEN** a cluster operator calls `GET /ops/v1/cluster` on a Standby Controller
- **THEN** Orchard returns `200` with `controller_role` reported as `standby`
- **AND** it does not report that Controller as leader

### Requirement: Operator API Reads Use Shared Controller-Owned Builders

Each route and its local CLI command SHALL obtain its payload from the same Controller-owned builder, consistent with ADR 0005's shared cluster-management structures.
The following full field/version contracts govern existing operator/admin HTTP and local CLI representations. The accepted reader serialization SHALL instead be the recursively validated subset in [the closed reader projections](../../../add-read-only-cluster-role/design.md#closed-reader-projections), with `projection: "cluster_reader.v1"`, reader-specific root/nested `contract_version` values and the cluster `authority.roles/read_only` summary. Shared builder facts SHALL include the declared metadata, while full wire presenters retain their existing bodies and versions. Removing fields for a reader representation requires those new versions, not a waiver of the version rule below; unversioned nested maps inherit the reader schema. Reader path/projection selection SHALL be revalidated at transmission under shared fences, rebuilding after an authority downgrade or refusing without stale wider data.
`GET /ops/v1/cluster` and `orchardctl cluster status --json` SHALL return `object` `cluster_management.cluster_status` with `contract_version` `orchard.cluster_management.cluster_status.v1`, a `summary`, and a `control_plane` `ControlPlaneStatus` map.
`GET /ops/v1/nodes` and `orchardctl nodes list --json` SHALL return `object` `cluster_management.node_status_list` with the `NodeStatus` `contract_version`, a `data` list of Node status maps, and a `summary`.
`GET /ops/v1/nodes/:node_id` and `orchardctl nodes inspect <node-id> --json` SHALL return the Node object with `object` `node`, a `status` Node status map, `latest_decision`, and `memory_budget` when one is available.
Values SHALL reflect the process and time at which the builder runs, so the local CLI and an HTTP call MAY report different control-plane evidence, freshness, or memory budget for the same durable state.
Changes to these shapes SHALL be additive; a removed, renamed, or retyped field SHALL require a new `contract_version`.
An unknown or malformed Node ID SHALL return `404 node_not_found`, matching `Orchard.Nodes.fetch_node/1` and the Admin API admission routes.

#### Scenario: HTTP and CLI share the Node list contract

- **WHEN** a cluster operator calls `GET /ops/v1/nodes` and an operator runs `orchardctl nodes list --json` against the same durable inventory
- **THEN** both payloads have the same `object`, `contract_version`, field set, and Node status values

#### Scenario: Malformed Node ID

- **WHEN** a cluster operator calls `GET /ops/v1/nodes/not-a-uuid` on the active Controller
- **THEN** Orchard returns `404 node_not_found`

### Requirement: Operator Node Reads Project Admission Provenance

On `GET /ops/v1/nodes/:node_id`, `latest_decision` SHALL contain only `object` `node_admission_decision`, `decision`, and `decided_at`, or be `null` when no decision exists.
It MUST NOT expose the decision reason, actor type, actor ID, audit log ID, observed identity, target reference, or decision metadata.
The local `orchardctl nodes inspect` command runs under the local Controller-runtime admin authority of ADR 0006 and MAY keep the full decision projection; it SHALL obtain it from the same builder by an explicit projection option.

#### Scenario: Operator does not see admission provenance

- **WHEN** a cluster operator calls `GET /ops/v1/nodes/:node_id` for an admitted Node whose decision has a reason and metadata
- **THEN** `latest_decision` contains only `object`, `decision`, and `decided_at`

### Requirement: Operator API Reads Do Not Mutate Durable State

An admitted read on these routes SHALL NOT create or update audit events, Node rows, Node Admission Candidates, Node Admission Decisions, queue-capacity sources, or other domain rows.
This excludes the shared Operator API authentication bookkeeping, which updates API Token `last_used_at` on admission and records authentication-failure audit events on refusal.
The Node memory budget SHALL be read through a Runtime Endpoint snapshot that does not perform Node status observation, so a successful probe SHALL NOT invoke `Orchard.Nodes.observe_status/3`; `orchardctl nodes inspect` SHALL use the same non-observing path.
The reader path SHALL omit memory-budget detail and skip that unused probe, rather than fetch excluded evidence to redact it. Its only durable bookkeeping remains API Token `last_used_at`, including role refusals and Standby, without extending expiry or advancing revocation-relevant revisions; valid-credential denials SHALL NOT invent an audit event.
Authenticated BEAM and mTLS compatibility clients SHALL retain peer verification on this path, rejecting status unless the target and reported Node identity match the certificate-bound peer and its valid enrollment and certificate binding, including the current BEAM grant when applicable.
Neither successful verification nor rejection SHALL persist lifecycle observations or refresh or clear queue-capacity sources.
When the Node inventory query fails after admission, the Node routes SHALL return `503 database_unavailable` in the shared `{"error": {"code", "message"}}` envelope.

#### Scenario: Successful runtime probe during Node inspect

- **WHEN** a cluster operator calls `GET /ops/v1/nodes/:node_id` and a Runtime Endpoint target answers the memory-budget probe successfully
- **THEN** the response includes the memory budget
- **AND** no Node, Node Admission Candidate, queue-capacity source, or audit row is created or updated

#### Scenario: Database unavailable after admission

- **WHEN** the Repo fails while the active Controller builds a Node list for an admitted operator
- **THEN** Orchard returns `503 database_unavailable` in the shared error envelope
