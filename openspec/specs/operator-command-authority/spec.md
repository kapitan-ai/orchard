# operator-command-authority Specification

## Purpose

Defines where Orchard operator commands execute and how portable clients, Controller-owned durable operations, host-local tooling, and bounded bootstrap or recovery channels keep their authorities separate.

The portable command-family architecture is an accepted target; existing local Controller-runtime authority remains the implementation baseline identified in `SPEC.md` §11.9.
The open `cross-surface-authorization-contract` change accepts the first credential family's detailed target under `SPEC.md` §10.11, but its implementation and COMPLETE gate remain pending.

## Requirements

### Requirement: Controller Owns Durable Operator Operations
An operator operation that authoritatively reads or mutates Controller-owned durable state SHALL execute inside the active Controller through authenticated, authorized, leader-aware, and audited Controller-owned domain operations.
Console and CLI clients SHALL invoke the same domain authority rather than implement separate Repo mutation paths.
This requirement changes the local CLI authority described around `SPEC.md` §§7.3, 7.4, 11.4, and 11.9 while preserving ADR 0006's Controller-runtime authority.

#### Scenario: Remote CLI admits a Node
- **WHEN** an authorized operator invokes Node admission from a portable CLI on another host
- **THEN** the active Controller executes the admission operation under the same policy and audit contract used by the Console

### Requirement: Portable CLI Is A Client
The portable CLI SHALL own argument parsing, client authentication, confirmation presentation, and output formatting.
It MUST NOT require direct Ecto Repo access, Controller application modules, launchd, Darwin native helpers, or local Controller release evaluation for normal operator operations.
The Controller release MUST NOT load the CLI implementation to obtain Controller authority.

#### Scenario: CLI runs on Linux
- **WHEN** an operator runs the portable CLI in the Linux portability acceptance environment
- **THEN** Controller-state commands execute through the authenticated Controller interface
- **AND** the CLI does not require local database configuration or Apple tooling

### Requirement: Host-Local Operations Belong To Host Tooling
Service-manager control, managed process fencing, host environment materialization, local trust-store mutation, terminal custody, and host support collection SHALL execute through platform host tooling under the applicable host-lifecycle and privilege contract.
Mixed commands SHALL separate Controller-owned and host-local operations rather than granting one process both implicit authorities.

#### Scenario: Operator stops a local managed Node Agent
- **WHEN** an authorized operator requests a host-local managed stop
- **THEN** platform host tooling executes the lifecycle protocol
- **AND** the portable CLI does not emulate the host adapter with operating-system conditionals

### Requirement: Narrow Local Bootstrap And Recovery Channel
Any local Controller-owned bootstrap or recovery channel SHALL be limited to operations that cannot yet use ordinary remote administrator credentials.
If provided, the channel SHALL invoke the same Controller-owned domain operations, SHALL be locally authenticated and bounded, and MUST NOT become a general direct-Repo fallback.

#### Scenario: First administrator does not yet exist
- **WHEN** an approved bootstrap operation must create initial Controller authority before remote administrator credentials exist
- **THEN** the local channel invokes the Controller-owned bootstrap domain operation
- **AND** subsequent normal operator commands use the authenticated Controller interface

### Requirement: Controller owns breaker inspection and clear

Breaker inspection and clear operations SHALL execute in the active Controller through the cluster-scoped Operator-or-admin service-account boundary and the shared Controller-owned domain authority.
Node inspection and clear SHALL use `GET /ops/v1/circuit-breakers/nodes/:node_id` and `POST /ops/v1/circuit-breakers/nodes/:node_id/clear`.
Placement inspection and clear SHALL use `GET /ops/v1/circuit-breakers/placements/:node_id/:model_id` and `POST /ops/v1/circuit-breakers/placements/:node_id/:model_id/clear`.
Inspection SHALL return `Cache-Control: no-store` and bounded canonical state and transition evidence.
Clear SHALL require a JSON body with non-empty `reason`, SHALL return `cleared` or `already_cleared` with resulting bounded state, and SHALL persist an effective mutation and audit evidence atomically.
An already inactive breaker MUST NOT increment generation again.
Tenant-direct credentials and public inference credentials MUST fail closed.
This requirement implements `SPEC.md` §5.10, §7.3, and §10 under the portable command authority contract.

#### Scenario: Authorized Operator clears a placement breaker

- **WHEN** a service-account principal with cluster-scoped `operator` or `admin` authority posts a non-empty reason to `/ops/v1/circuit-breakers/placements/:node_id/:model_id/clear`
- **THEN** the active Controller performs the generation-fenced clear
- **AND** the resulting state and audit evidence commit atomically

#### Scenario: Operator inspects a Node without a breaker row

- **WHEN** an authorized principal gets `/ops/v1/circuit-breakers/nodes/:node_id` for an existing Node with no breaker row
- **THEN** Orchard returns the bounded Node breaker object with `Cache-Control: no-store`
- **AND** it represents the breaker as closed with zero contributions and generation zero

#### Scenario: Tenant credential attempts inspection

- **WHEN** a tenant-direct or public inference credential requests breaker inspection or clear
- **THEN** Orchard denies the request without revealing breaker state
