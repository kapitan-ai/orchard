## MODIFIED Requirements

### Requirement: Detailed health is Operator-only

The Controller SHALL expose full diagnostic health only at `GET /ops/v1/health` through the existing cluster-scoped Operator-or-admin authorization boundary. The same route SHALL additionally admit an enabled API Client's valid cluster `cluster_reader` grant only to the non-observing, closed reader representation in [the reader contract](../read-only-cluster-role/spec.md), including mixed reader-plus-inference clients without sufficient Operator/admin authority. The route SHALL set `Cache-Control: no-store` before authentication so every response is non-cacheable.

The reader body SHALL carry top-level `projection: "cluster_reader.v1"` and `contract_version: "orchard.cluster_reader.health.v1"`; it SHALL omit `runtime.diagnostics`, runtime messages, remediation and all other excluded content. Full Operator/admin health SHALL retain its existing readiness/status, diagnostics and response fields. The proposed amendments to `SPEC.md` §§3.1 and 4.6.1 and ADR 0016 SHALL distinguish these representations; neither public health nor the staged readiness predicate changes.

#### Scenario: Credential is missing or invalid

- **WHEN** the request lacks a valid API Client bearer token
- **THEN** the response is HTTP `401` with code `invalid_api_key`
- **AND** it includes `Cache-Control: no-store`
- **AND** no health probe runs

#### Scenario: Principal lacks cluster Operator access

- **WHEN** a valid principal lacks both sufficient cluster Operator/admin authority and a valid API Client cluster-reader grant
- **THEN** the response is HTTP `403` with code `operator_required`
- **AND** it includes `Cache-Control: no-store`
- **AND** no health probe runs

#### Scenario: Authorized health passes

- **WHEN** a cluster-scoped Operator or admin requests health and the staged predicate passes
- **THEN** the response is HTTP `200`
- **AND** it includes the readiness contract, ordered checks and sanitized observational details
- **AND** it includes `Cache-Control: no-store`

#### Scenario: Authorized health fails

- **WHEN** a cluster-scoped Operator or admin requests health and the staged predicate fails
- **THEN** the response is HTTP `503`
- **AND** it includes the first causal failure reason and bounded remediation
- **AND** it includes `Cache-Control: no-store`

#### Scenario: Reader health is bounded and non-observing

- **WHEN** a valid reader-path request passes current-authority admission on Active or Standby under the narrow serving-Controller exception
- **THEN** health uses non-observing runtime evidence and retains readiness-derived HTTP 200/503 outcomes with only the versioned reader fields
- **AND** no diagnostics, remediation, Node observation, capacity refresh or audit mutation is produced
- **AND** unavailable authoritative Postgres/fences returns `503 authority_unavailable` without cached success
