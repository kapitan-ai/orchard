## ADDED Requirements

### Requirement: Public health exposes status only

The Controller SHALL expose unauthenticated liveness and readiness with exact
status-only JSON bodies and SHALL NOT expose diagnostic detail publicly.

#### Scenario: Public liveness

- **WHEN** a caller requests `GET /health/live`
- **THEN** the response is HTTP `200`
- **AND** its JSON body is exactly `{"status":"ok"}`

#### Scenario: Public readiness passes

- **WHEN** the active readiness predicate passes
- **THEN** `GET /health/ready` returns HTTP `200`
- **AND** its JSON body is exactly `{"status":"ok"}`

#### Scenario: Public readiness fails

- **WHEN** the active readiness predicate fails
- **THEN** `GET /health/ready` returns HTTP `503`
- **AND** its JSON body is exactly `{"status":"error"}`
- **AND** no check, reason, remediation, version, build, transport, Console, or
  runtime detail is present

#### Scenario: Public readiness evaluation is unavailable

- **WHEN** the staged readiness call raises, exits, throws, times out, or returns
  an invalid value
- **THEN** its supervised work is terminated and readiness fails closed
- **AND** `GET /health/ready` returns HTTP `503`
- **AND** its JSON body is exactly `{"status":"error"}`
- **AND** no diagnostic, exception, or machine-local detail is present

### Requirement: Pilot readiness is explicitly staged

The pilot SHALL preserve the existing readiness predicate unchanged and identify it
as `orchard.readiness.legacy_m0.v1`. This predicate SHALL NOT be described as the
complete `SPEC.md` §3.1 aggregate.

#### Scenario: Operator detail identifies the predicate

- **WHEN** an authorized caller requests Operator health
- **THEN** `readiness_contract.version` is
  `orchard.readiness.legacy_m0.v1`
- **AND** `readiness_contract.check_order` lists `postgres_reachable`,
  `migrations_current`, `public_api_https_enabled`, and
  `controller_boot_completed` in that order

#### Scenario: Console identifies its internal predicate

- **WHEN** the Console Overview renders readiness detail
- **THEN** its description identifies the internal predicate as
  `orchard.readiness.legacy_m0.v1`
- **AND** it states that public health responses are status-only
- **AND** it does not describe the predicate as the complete `SPEC.md` §3.1
  aggregate

#### Scenario: Missing complete-aggregate authority

- **WHEN** a required cache-loaded or conditional leadership authority is absent
- **THEN** no constant, flag, readiness-only cache, unrelated cache, successful
  database query, or process-presence shim is added
- **AND** the legacy predicate remains labeled incomplete

### Requirement: Detailed health is Operator-only

The Controller SHALL expose diagnostic health only at `GET /ops/v1/health` through
the existing cluster-scoped Operator-or-admin authorization boundary. The route
SHALL set `Cache-Control: no-store` before authentication so every response is
non-cacheable.

#### Scenario: Credential is missing or invalid

- **WHEN** the request lacks a valid API Client bearer token
- **THEN** the response is HTTP `401` with code `invalid_api_key`
- **AND** it includes `Cache-Control: no-store`
- **AND** no health probe runs

#### Scenario: Principal lacks cluster Operator access

- **WHEN** a valid principal lacks cluster-scoped Operator or admin access
- **THEN** the response is HTTP `403` with code `operator_required`
- **AND** it includes `Cache-Control: no-store`
- **AND** no health probe runs

#### Scenario: Authorized health passes

- **WHEN** a cluster-scoped Operator or admin requests health and the staged
  predicate passes
- **THEN** the response is HTTP `200`
- **AND** it includes the readiness contract, ordered checks, and sanitized
  observational details
- **AND** it includes `Cache-Control: no-store`

#### Scenario: Authorized health fails

- **WHEN** a cluster-scoped Operator or admin requests health and the staged
  predicate fails
- **THEN** the response is HTTP `503`
- **AND** it includes the first causal failure reason and bounded remediation
- **AND** it includes `Cache-Control: no-store`

### Requirement: Public diagnostic removal has no compatibility shim

The implementation SHALL NOT restore rich unauthenticated health through another
route, query parameter, content type, cache, or compatibility representation.

#### Scenario: Legacy public consumer requests detail

- **WHEN** an unauthenticated consumer requests either public health endpoint
- **THEN** it receives only the exact status-only representation
- **AND** public diagnostic details are not restored

### Requirement: Credential-free status accepts bounded feature loss

`orchardctl status` SHALL continue to use public readiness without credentials,
SHALL accept only the exact HTTP/body pairs defined by public readiness, and SHALL
NOT present remote Controller version or build identity from that response.

#### Scenario: Status probes a ready Controller

- **WHEN** public readiness returns `{"status":"ok"}`
- **THEN** the CLI reports ready status
- **AND** any displayed version is the local CLI or installed package version
- **AND** no Operator credential or unauthenticated version route is introduced

#### Scenario: Status rejects an invalid public health pair

- **WHEN** the response has a mismatched HTTP status and body, an extra key, or an
  HTTP status outside `200` and `503`
- **THEN** the CLI reports an invalid health response
- **AND** it does not render any supplied diagnostic field

#### Scenario: Status reports degraded without public diagnostics

- **WHEN** public readiness returns HTTP `503` with exactly `{"status":"error"}`
- **THEN** the CLI reports degraded status with a state-free Console URL
- **AND** it directs the operator to authenticated `GET /ops/v1/health` for
  diagnostics
- **AND** it does not add an authenticated CLI probe
