## ADDED Requirements

### Requirement: Health implementation remains blocked on authoritative readiness sources

Controller health wiring MUST NOT begin until separate accepted control-plane changes expose authoritative model, tenant, and API-key cache hydration status and the existing production write-path leadership surface is accepted as a bounded readiness source or its demonstrated gaps are resolved.

#### Scenario: A cache authority is absent

- **WHEN** any required serving-path cache and its loaded-state interface do not exist
- **THEN** Controller health implementation remains blocked
- **AND** the missing authority is assigned to a separate control-plane change

#### Scenario: Existing leadership surface has not been assessed

- **WHEN** the production backing, bounded-read behavior, or readiness semantics of `Orchard.ControlPlane` have not been explicitly assessed
- **THEN** Controller health implementation remains blocked
- **AND** no new authority is commissioned until that assessment identifies a concrete gap

#### Scenario: Existing leadership surface has a demonstrated gap

- **WHEN** the assessment identifies a missing production provider, missing timeout bound, or semantic mismatch with write authorization
- **THEN** the exact gap is assigned to a separate control-plane change
- **AND** the health implementation remains a consumer rather than the owner of that authority

### Requirement: Readiness shims are prohibited

The Controller health implementation MUST consume authoritative readiness sources and MUST NOT invent substitutes for unimplemented `SPEC.md` section 3.1 conditions.
A validated deployment mode MAY determine whether the conditional leadership condition applies, but a configured role MUST NOT be accepted as proof that this Controller currently holds write-path leadership.

#### Scenario: Constant or configuration flag is proposed

- **WHEN** a constant or configuration flag is proposed as evidence that a required cache is loaded
- **THEN** the proposal is rejected

#### Scenario: Unrelated or readiness-only cache is proposed

- **WHEN** an unrelated cache or a process unused by the production serving path is proposed as a required cache authority
- **THEN** the proposal is rejected

#### Scenario: Database query is proposed as cache evidence

- **WHEN** a successful direct Postgres query is proposed as proof that a required cache is loaded
- **THEN** the proposal is rejected

#### Scenario: Configured role is proposed as leadership evidence

- **WHEN** a configured role, membership record, or process-presence check is proposed as proof of current write-path leadership
- **THEN** the proposal is rejected

#### Scenario: Deployment mode determines whether the leadership condition applies

- **WHEN** a deployment-mode source is proposed only to decide whether the conditional `SPEC.md` section 3.1 leadership condition applies
- **THEN** the proposal is permitted
- **AND** it does not authorize that source to report `pass` for write-path leadership in Active/Standby mode
- **AND** the accepted assessment records how a mode value is validated rather than assumed correct

### Requirement: Future public health responses are exact and minimal

After the blocking authorities are accepted, the health implementation SHALL provide unauthenticated public health responses that disclose only stable status.

#### Scenario: Future liveness response

- **WHEN** the Controller HTTP process serves `GET /health/live`
- **THEN** it returns HTTP `200`
- **AND** the JSON body is exactly `{"status":"ok"}`
- **AND** it does not evaluate dependency or observational health

#### Scenario: Future public readiness passes

- **WHEN** the complete `SPEC.md` section 3.1 readiness evaluation passes
- **THEN** `GET /health/ready` returns HTTP `200`
- **AND** the JSON body is exactly `{"status":"ok"}`

#### Scenario: Future public readiness fails

- **WHEN** any applicable `SPEC.md` section 3.1 readiness condition fails or cannot be evaluated safely
- **THEN** `GET /health/ready` returns HTTP `503`
- **AND** the JSON body is exactly `{"status":"error"}`
- **AND** the response exposes no diagnostic detail

### Requirement: Future public and Operator health share the complete readiness aggregate

After the blocking authorities are accepted, the public readiness endpoint and authenticated Operator health endpoint SHALL consume one complete aggregate evaluation of every readiness condition required by `SPEC.md` section 3.1.
A reduced milestone-specific readiness subset MUST NOT be used.
A condition that `SPEC.md` section 3.1 does not require MUST NOT gate the aggregate, so public API transport posture and the constant Controller boot flag both cease to be readiness gates when the aggregate is adopted.

#### Scenario: Future required condition fails

- **WHEN** any required or applicable readiness source reports failure
- **THEN** public readiness and Operator health report the same aggregate failure

#### Scenario: Future transport posture is observational only

- **WHEN** the Controller serves the public API in a `SPEC.md` section 10.7 `plain_http_localhost` or `reverse_proxy` transport mode and every `SPEC.md` section 3.1 condition passes
- **THEN** public readiness returns HTTP `200`
- **AND** transport posture appears only as an Operator observation
- **AND** transport posture does not fail the aggregate

#### Scenario: Future constant boot flag is not a gate

- **WHEN** a hard-coded or otherwise constant Controller boot flag is proposed as a member of the readiness aggregate
- **THEN** it does not gate the aggregate
- **AND** it survives only as an Operator observation or is removed from the check set by the same atomic migration

#### Scenario: Future readiness source is invalid or unavailable

- **WHEN** a readiness source raises, exits, times out, or returns an invalid value
- **THEN** the aggregate fails closed
- **AND** the public endpoint returns its stable HTTP `503` representation rather than an internal error response

### Requirement: Removing the transport readiness gate depends on fail-closed transport validation

The public API transport readiness gate MUST NOT be removed until `SPEC.md` section 10.7 configuration, wrapper, and boot validation are confirmed to fail closed for every invalid or unresolvable public transport mode, through any configuration source rather than the `ORCHARD_TRANSPORT_MODE` environment variable alone.
Health MUST NOT become the fallback validator for a Controller configuration that should not have started.

#### Scenario: Invalid transport mode fails closed before boot completes

- **WHEN** an invalid, unrecognized, or unresolvable public transport mode is configured through any source
- **THEN** the Controller fails closed at wrapper preflight or boot per `SPEC.md` section 10.7
- **AND** no running Controller resolves an unresolved public transport mode

#### Scenario: Transport validation gap is demonstrated

- **WHEN** an invalid or unresolvable public transport mode can reach a running Controller instead of failing closed
- **THEN** the existing transport readiness gate is retained until that validation gap is resolved
- **AND** the exact gap is assigned to a separate transport change rather than to the health implementation

#### Scenario: Transport observation reports posture honestly

- **WHEN** authorized Operator health detail renders public transport posture
- **THEN** it reports the resolved `SPEC.md` section 10.7 mode and its degraded classification
- **AND** an unresolved mode is not presented as a compliant transport posture

### Requirement: Future leadership status preserves read availability

After the existing leadership surface is accepted as sufficient or a demonstrated gap is resolved, the health implementation SHALL derive conditional write-path leadership from that production authority without blocking authorized read-only routes.

#### Scenario: Future single-controller mode

- **WHEN** the accepted authority reports single-controller mode
- **THEN** `write_path_leadership` reports `not_applicable`
- **AND** it does not fail the aggregate

#### Scenario: Future standby remains live and readable

- **WHEN** the accepted authority reports this Controller as standby and health is requested
- **THEN** public readiness returns HTTP `503`
- **AND** authenticated Operator health returns HTTP `503` with reason `controller_standby`
- **AND** public liveness remains HTTP `200`
- **AND** authorized read-only routes remain callable

#### Scenario: Future leadership is unproven

- **WHEN** the accepted authority cannot prove current local write-path leadership in Active/Standby mode
- **THEN** `write_path_leadership` reports `fail`
- **AND** the failure reason is `controller_leadership_unproven`

### Requirement: Future Operator health detail uses the existing protected boundary

After the blocking authorities are accepted, `GET /ops/v1/health` SHALL use the existing Operator API authentication contract from `SPEC.md` section 7.3 and ADR 0007.
Authentication and authorization SHALL complete before readiness or observational probes run.
Authorized responses SHALL set `Cache-Control: no-store`.

#### Scenario: Credential is missing or invalid

- **WHEN** a request does not present a valid API Client bearer credential
- **THEN** it returns HTTP `401`
- **AND** the stable error code is `invalid_api_key`
- **AND** no health probe runs

#### Scenario: Principal is not an Operator

- **WHEN** an authenticated principal lacks a cluster-scoped `operator` or `admin` RoleBinding
- **THEN** it returns HTTP `403`
- **AND** the stable error code is `operator_required`
- **AND** no health probe runs

#### Scenario: Authorized detail passes

- **WHEN** a cluster-scoped Operator or admin requests health detail and the shared aggregate passes
- **THEN** the endpoint returns HTTP `200`
- **AND** the response object is `operator_health`
- **AND** the contract version is `orchard.operator_health.v1`
- **AND** every `SPEC.md` section 3.1 check appears exactly once in stable causal order

#### Scenario: Authorized detail fails

- **WHEN** a cluster-scoped Operator or admin requests health detail and the shared aggregate fails
- **THEN** the endpoint returns HTTP `503`
- **AND** it includes the first stable failure reason and bounded remediation
- **AND** its aggregate status matches public readiness for the same evaluation

#### Scenario: Detail contains observational metadata

- **WHEN** authorized health detail includes build, transport, Console, runtime, licensing, or control-plane observations
- **THEN** those observations do not alter the aggregate readiness result unless `SPEC.md` explicitly makes them readiness conditions

#### Scenario: Detail is sanitized

- **WHEN** authorized health detail is serialized
- **THEN** it contains no bearer credential, plaintext secret, DSN, raw exception, tenant identifier, user identifier, prompt, response content, or machine-local path

### Requirement: Future in-repository consumers preserve the health boundary

When the health behavior is implemented, in-repository public health consumers SHALL treat `/health/ready` as a status-only endpoint and SHALL NOT require Operator credentials.
Console diagnostics SHALL use the shared readiness evaluator or authenticated Operator contract without reimplementing readiness policy.
Remote Controller version and build identity cease to be available without credentials, and that loss SHALL NOT be replaced by a new unauthenticated route or by placing a credential in a public probe.

#### Scenario: orchardctl status probes public readiness

- **WHEN** `orchardctl status` probes a Controller without an Operator credential
- **THEN** it derives Controller reachability and readiness from the exact public health response
- **AND** it does not expect build, runtime, licensing, reason, remediation, or check detail from `/health/ready`

#### Scenario: Credential-free status reports no remote Controller identity

- **WHEN** `orchardctl status` renders a version banner without an Operator credential
- **THEN** it may present only the local CLI or installed package version
- **AND** it does not present that local value as the remote Controller version or build reference
- **AND** the migration adds no unauthenticated version route and no credential to the public probe path

#### Scenario: Remote Controller identity is requested

- **WHEN** an Operator needs remote Controller version or build identity
- **THEN** it is obtained from the authenticated Operator health detail

#### Scenario: Console renders readiness

- **WHEN** the Console renders Controller readiness
- **THEN** it presents every check from the shared complete evaluation
- **AND** it supports `pass`, `fail`, and the single-controller `not_applicable` leadership state

#### Scenario: Existing public probes continue without credentials

- **WHEN** packaging, launchd, local development, or an external black-box probe checks public health
- **THEN** it can use the stable unauthenticated status and exact body
- **AND** no Operator credential is placed in the probe configuration
