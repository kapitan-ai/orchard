## ADDED Requirements

### Requirement: An explicit public selector chooses final-only projection

Orchard SHALL accept the explicit final-only selector defined in `SPEC.md` sections 3.4 and 7.2.1: the JSON boolean `enabled` inside Responses `reasoning` and inside a Chat Completions top-level `reasoning` object that contains exactly `enabled`. Selector presence MUST select `final_only` and `explicit_public`, with `enabled = false` selecting `disabled` and `enabled = true` selecting `enabled`. Selector absence MUST preserve the omitted and effort-only meanings defined by the `request-local-reasoning-effort` change, so no request valid without the selector changes meaning. Chat effort MUST remain the top-level `reasoning_effort`, and Responses effort MUST remain `reasoning.effort`.

#### Scenario: Every reasoning control is omitted

- **WHEN** Chat Completions or Responses omits every reasoning control
- **THEN** Orchard preserves the exact `model_default + legacy_blended` path
- **AND** it does not synthesize a control, effort tier, or negotiated contract

#### Scenario: Effort is supplied without the selector

- **WHEN** Chat Completions supplies only `reasoning_effort`, or Responses supplies `reasoning` containing only `effort`
- **THEN** Orchard keeps the rendered `explicit_public + enabled + legacy_blended` behavior, outcome, and hash identity of the `request-local-reasoning-effort` change
- **AND** it does not select final-only projection

#### Scenario: Explicit final-only selector is valid

- **WHEN** either endpoint receives the selector with `enabled = true` and either no effort or a well-formed effort that the exact tuple qualifies as a negotiated tier
- **THEN** Orchard normalizes the Request to `enabled + final_only + explicit_public` with that tier or canonical `nil`
- **AND** the selector with `enabled = false` and no effort normalizes only to `disabled + final_only + explicit_public` with canonical `nil`

### Requirement: Final-only effort uses registered identifiers within the negotiated vocabulary

Under the selector, Orchard MUST validate effort with the same field, bounded identifier syntax, and malformed-value rejection as rendered effort, and MUST treat explicit `null` as malformed. Orchard MUST support only tiers in the closed negotiated vocabulary `low | medium | high` that an exact negotiated renderer mapping qualifies for the selected tuple. A rendered registration, alias, native mapping, or discovery entry MUST NOT by itself authorize an identifier under the selector.

#### Scenario: Registered rendered identifier outside the negotiated vocabulary

- **WHEN** the selector has `enabled = true` and effort is a well-formed identifier such as `xhigh` that is registered for rendered effort but is outside `low | medium | high`
- **THEN** Orchard returns `400 invalid_request_error` with code `unsupported_reasoning_control` and the endpoint's effort field as `param`
- **AND** it does not fall back to rendered effort, another tier, or legacy blended output

#### Scenario: Effort contradicts disabled generation

- **WHEN** a well-formed effort is supplied with `reasoning.enabled = false`
- **THEN** Orchard returns `400 invalid_request_error` with code `unsupported_reasoning_control` and the endpoint's effort field as `param`
- **AND** it creates neither a Request nor attempt evidence

### Requirement: Public reasoning validation follows one fixed order

Orchard MUST apply the public-input and exact capability rows of `SPEC.md` §7.2.7 before Request persistence, scheduling, or dispatch, using the envelope in §7.2.6. The first applicable failure in §7.2.7's order MUST determine the error and `param` when failures coexist. The `param` paths MUST be `reasoning`, `reasoning.enabled`, `reasoning.<member>` for an unrecognized member, Chat Completions `reasoning_effort`, and Responses `reasoning.effort`. Every request without a Chat Completions top-level `reasoning` or a Responses `reasoning.enabled` MUST keep its current outcome.

#### Scenario: Reasoning value is not an object

- **WHEN** a present `reasoning` is `null` or not an object
- **THEN** Orchard returns `400 invalid_request_error` with code `invalid_value` and `param = reasoning`

#### Scenario: Reasoning object carries an unrecognized member

- **WHEN** `reasoning` carries a member other than `effort` or `enabled` on Responses, or other than `enabled` on Chat Completions
- **THEN** Orchard returns the endpoint's existing `400 invalid_request_error` with code `unsupported_parameter` and that member's `reasoning.<member>` path
- **AND** this failure wins before selector and effort validation, and Orchard neither ignores nor passes the member through to a provider, template, or canonical field

#### Scenario: Selector has an invalid value

- **WHEN** a recognized-member-only `reasoning` object carries `enabled` that is not a JSON boolean
- **THEN** Orchard returns `400 invalid_request_error` with code `invalid_value` and `param = reasoning.enabled`

#### Scenario: Exact control cannot be honored

- **WHEN** after model resolution the accepted selector or selected tier has no exact compatible artifact, template, and renderer contract
- **THEN** Orchard returns `400 invalid_request_error` with code `unsupported_reasoning_control`
- **AND** `param` is `reasoning.enabled` for the selector or the endpoint's effort field for the tier

### Requirement: Public final-only selector preserves hashing and replay boundaries

Orchard SHALL preserve the request-hash and replay behavior in `SPEC.md` sections 3.4, 3.9, and 10.10. Omitted and effort-only requests MUST retain their current bytes and hash domain, while an accepted selector MUST participate in the normalized public-body hash.

#### Scenario: Omitted or effort-only request retains its identity

- **WHEN** an otherwise unchanged public request carries no selector
- **THEN** its request bytes, serialization, `body_hash`, and idempotency behavior remain unchanged
- **AND** no synthesized reasoning default participates in the hash

#### Scenario: Selector participates in idempotency

- **WHEN** a valid public request includes the selector
- **THEN** the normalized public control, including `enabled`, participates in `body_hash`
- **AND** replay continues to return only a retained historical public response without reinterpreting its reasoning projection

### Requirement: Selector acceptance does not activate deferred reasoning surfaces

Orchard MUST preserve `SPEC.md` sections 7.2.1, 7.2.4, 7.2.5, 7.5.3a, and 13.1 while the implementation and deployment prerequisites remain incomplete. Acceptance SHALL NOT expose structured reasoning, reasoning-token usage, final-only discovery, a production capability registration, or a silent mixed-version downgrade.

#### Scenario: Implementation or deployment prerequisite is incomplete

- **WHEN** the selector contract is accepted but any required #326-#329 implementation or applicable PR #421 deployment attestation remains incomplete
- **THEN** both endpoints keep rejecting the selector as an unsupported field exactly as they do today
- **AND** Orchard does not treat contract acceptance, a merged reader, green CI, static fixtures, or successful rendered-input steering as activation evidence

#### Scenario: Exact loaded proof is unavailable

- **WHEN** §7.5.3a's exhaustion rule is met or the authoritative loaded-worker acceptance proof fails before invocation
- **THEN** Orchard preserves the closed `503 server_error` and `runtime_incompatible` mapping without silent downgrade to rendered or legacy output
- **AND** a post-invocation conformance failure instead preserves the content-free `500 api_error` and `internal_error` mapping

#### Scenario: Final-only response is published

- **WHEN** an explicit selector succeeds synchronously or by streaming
- **THEN** Chat Completions and Responses use only their existing final-text and selected tool-output shapes
- **AND** Orchard emits no structured reasoning item, reasoning event, or public reasoning-token subset
