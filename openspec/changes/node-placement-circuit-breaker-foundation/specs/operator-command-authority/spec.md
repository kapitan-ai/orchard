## ADDED Requirements

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
