## ADDED Requirements

### Requirement: Public reasoning controls normalize identically across endpoints

Orchard SHALL accept the provider-neutral `reasoning` object defined in `SPEC.md` sections 3.4 and 7.2.1 with identical semantics on Chat Completions and Responses. Presence MUST select `final_only`; `enabled` MUST select `disabled | enabled`; and omitted or `null` effort MUST select canonical `nil` without a default tier.

#### Scenario: Public reasoning control is omitted

- **WHEN** Chat Completions or Responses omits `reasoning`
- **THEN** Orchard preserves the exact `model_default + legacy_blended` path
- **AND** it does not synthesize a control, effort tier, or negotiated contract

#### Scenario: Explicit final-only control is valid

- **WHEN** either endpoint receives a `reasoning` object with no unrecognized member, `enabled = true`, and an omitted, `null`, or canonical effort
- **THEN** Orchard normalizes the Request to `enabled + final_only + explicit_public` with the selected effort or canonical `nil`
- **AND** the same recognized-member-only object with `enabled = false` and an omitted or `null` effort similarly normalizes only to `disabled + final_only + explicit_public` with canonical `nil`

### Requirement: Public reasoning validation distinguishes invalid and unsupported controls

Orchard MUST apply the public-input and exact artifact, template, and renderer capability-validation rows of `SPEC.md` §7.2.7 before Request persistence, scheduling, or dispatch, using the envelope in §7.2.6. Invalid accepted-field types, invalid effort values, and unrecognized `reasoning` members MUST use `invalid_value`; contradictory or artifact-, template-, or renderer-incompatible controls MUST use `unsupported_reasoning_control`. Public input validation MUST use §7.2.7's fixed precedence, and the first applicable failure MUST determine the error and `param` when failures coexist.

#### Scenario: Reasoning value is not an object

- **WHEN** `reasoning` is `null` or not an object
- **THEN** Orchard returns `400 invalid_request_error` with code `invalid_value` and `param = reasoning`

#### Scenario: Required enabled member is invalid

- **WHEN** `reasoning` is an object whose `enabled` member is absent or not boolean
- **THEN** Orchard returns `400 invalid_request_error` with code `invalid_value` and `param = reasoning.enabled`
- **AND** this failure wins even when the object also carries an unrecognized member or invalid `effort`

#### Scenario: Reasoning object carries an unrecognized member

- **WHEN** `reasoning` is an object with boolean `enabled` and carries any member other than `enabled` and `effort`
- **THEN** Orchard returns `400 invalid_request_error` with code `invalid_value` and `param = reasoning`
- **AND** this failure wins before `effort` validation and Orchard neither ignores nor passes the member through to a provider, template, or canonical field

#### Scenario: Effort has an invalid value

- **WHEN** `reasoning` is an object with boolean `enabled`, no unrecognized member, and a non-`null` effort outside `low | medium | high`
- **THEN** Orchard returns `400 invalid_request_error` with code `invalid_value` and `param = reasoning.effort`

#### Scenario: Effort contradicts disabled generation

- **WHEN** a recognized non-`null` effort is supplied with `reasoning.enabled = false` and the `reasoning` object carries no unrecognized member
- **THEN** Orchard returns `400 invalid_request_error` with code `unsupported_reasoning_control` and `param = reasoning.effort`
- **AND** it creates neither a Request nor attempt evidence

#### Scenario: Exact control cannot be honored

- **WHEN** the accepted base control or selected tier has no exact compatible artifact, template, and renderer contract
- **THEN** Orchard returns `400 invalid_request_error` with code `unsupported_reasoning_control`
- **AND** `param` is `reasoning` for the base control or `reasoning.effort` for the tier

### Requirement: Public reasoning input preserves hashing and replay boundaries

Orchard SHALL preserve the request-hash and replay behavior in `SPEC.md` sections 3.4, 3.9, and 10.10. Omission MUST retain the exact pre-control bytes and hash domain, while an accepted explicit object MUST participate in the normalized public-body hash.

#### Scenario: Omitted request retains legacy identity

- **WHEN** an otherwise unchanged public request omits `reasoning`
- **THEN** its request bytes, serialization, `body_hash`, and idempotency behavior remain unchanged
- **AND** no synthesized reasoning default participates in the hash

#### Scenario: Explicit control participates in idempotency

- **WHEN** a valid public request includes `reasoning`
- **THEN** the normalized public object participates in `body_hash`
- **AND** replay continues to return only a retained historical public response without reinterpreting its reasoning projection

### Requirement: Public contract acceptance does not activate deferred reasoning surfaces

Orchard MUST preserve `SPEC.md` sections 7.2.1, 7.2.4, 7.2.5, 7.5.3a, and 13.1 while the implementation and deployment prerequisites remain incomplete. Acceptance SHALL NOT expose structured reasoning, reasoning-token usage, a production capability registration, or a silent mixed-version downgrade.

#### Scenario: Implementation or deployment prerequisite is incomplete

- **WHEN** the public field contract is accepted but any required #326-#329 implementation or applicable PR #421 deployment attestation remains incomplete
- **THEN** Orchard keeps the public field disabled
- **AND** it does not treat contract acceptance, a merged reader, green CI, or static fixtures as activation evidence

#### Scenario: Exact loaded proof is unavailable

- **WHEN** §7.5.3a's exhaustion rule is met or the authoritative loaded-worker acceptance proof fails before invocation
- **THEN** Orchard preserves the closed `503 server_error` and `runtime_incompatible` mapping without silent downgrade
- **AND** a post-invocation conformance failure instead preserves the content-free `500 api_error` and `internal_error` mapping

#### Scenario: Final-only response is published

- **WHEN** an explicit control succeeds synchronously or by streaming
- **THEN** Chat Completions and Responses use only their existing final-text and selected tool-output shapes
- **AND** Orchard emits no structured reasoning item, reasoning event, or public reasoning-token subset
