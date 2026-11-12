## MODIFIED Requirements

### Requirement: Controller Owns Durable Operator Operations
An operator operation that authoritatively reads or mutates Controller-owned durable state SHALL execute inside the active Controller through authenticated, authorized, leader-aware, and audited Controller-owned domain operations.
Console and CLI clients SHALL invoke the same domain authority rather than implement separate Repo mutation paths.
This requirement changes the local CLI authority described around `SPEC.md` §§7.3, 7.4, 11.4, and 11.9 while preserving ADR 0006's Controller-runtime authority.

The accepted, inactive reader contract SHALL explicitly permit only bounded health/cluster serving-Controller observation and caller self-authority on Standby, as a narrow exception reconciled with `SPEC.md` §§2.5 and 10.11.2. It SHALL retain authoritative Postgres and shared current-authority fences, without cached authorization or local Repo fallback. All other reader target operations SHALL remain active-only; no read SHALL invent a successful mutation audit or acquire leadership.

#### Scenario: Remote CLI admits a Node
- **WHEN** an authorized operator invokes Node admission from a portable CLI on another host
- **THEN** the active Controller executes the admission operation under the same policy and audit contract used by the Console

#### Scenario: Reader observes its serving Standby
- **WHEN** a reader requests health or cluster on Standby and passes current-authority admission against authoritative Postgres
- **THEN** it receives only that Controller's bounded evidence and the cluster response's caller-authority summary
- **AND** other reader target operations remain refused on Standby

### Requirement: Controller owns breaker inspection and clear

Breaker inspection and clear operations SHALL execute in the active Controller through the cluster-scoped service-account boundary and the shared Controller-owned domain authority. Inspection SHALL additionally admit `cluster_reader` under the accepted, activation-gated `SPEC.md` §§7.3 and 10.4 reader contract; clear SHALL continue to require independently sufficient cluster `operator` or `admin` authority and MUST refuse requests on the reader path, including preview requests. A reader-bearing principal without independently sufficient existing cluster operator/admin authority for the action SHALL take that path regardless of other grants, including inference grants.
Node inspection and clear SHALL use `GET /ops/v1/circuit-breakers/nodes/:node_id` and `POST /ops/v1/circuit-breakers/nodes/:node_id/clear`.
Placement inspection and clear SHALL use `GET /ops/v1/circuit-breakers/placements/:node_id/:model_id` and `POST /ops/v1/circuit-breakers/placements/:node_id/:model_id/clear`.
Inspection SHALL return `Cache-Control: no-store` and bounded canonical state and transition evidence. Reader inspection SHALL use a non-locking committed-state read without the dispatch target `pg_advisory_xact_lock` or target row write locks; caller-authority fences remain required and the result SHALL NOT reserve dispatch eligibility.
Clear SHALL require a JSON body with non-empty `reason`, SHALL return `cleared` or `already_cleared` with resulting bounded state, and SHALL persist an effective mutation and audit evidence atomically.
An already inactive breaker MUST NOT increment generation again.
Tenant-direct credentials and inference-only credentials lacking independent management authority MUST fail closed.
This requirement implements `SPEC.md` §5.10, §7.3, and §10 under the portable command authority contract. It SHALL NOT declare a CLI family COMPLETE or authorize host-local fallback for a portable client.

#### Scenario: Authorized Operator clears a placement breaker

- **WHEN** a service-account principal with cluster-scoped `operator` or `admin` authority posts a non-empty reason to `/ops/v1/circuit-breakers/placements/:node_id/:model_id/clear`
- **THEN** the active Controller performs the generation-fenced clear
- **AND** the resulting state and audit evidence commit atomically

#### Scenario: Operator inspects a Node without a breaker row

- **WHEN** an authorized principal gets `/ops/v1/circuit-breakers/nodes/:node_id` for an existing Node with no breaker row
- **THEN** Orchard returns the bounded Node breaker object with `Cache-Control: no-store`
- **AND** it represents the breaker as closed with zero contributions and generation zero

#### Scenario: Tenant credential attempts inspection

- **WHEN** a tenant-direct or inference-only credential lacking independent management authority requests breaker inspection or clear
- **THEN** Orchard denies the request without revealing breaker state

#### Scenario: Reader inspects but cannot clear

- **WHEN** an API Client on the reader path, with or without inference grants, inspects an existing Node or placement breaker on the active Controller
- **THEN** it receives bounded state without creating a breaker or audit row
- **AND** posting to either clear route returns `403 operator_required` without changing the breaker, even with `dry_run: true`
