## ADDED Requirements

### Requirement: Qualified reasoning effort follows the apex contract

For the negotiated protocol, Orchard SHALL implement the closed `reasoning_effort = nil | low | medium | high` axis according to `SPEC.md` sections 3.4 and 7.2.1. Rendered input steering SHALL instead follow the exact registered model-specific identifiers and discovery contract defined by the request-local-reasoning-effort change; this does not expand negotiated protocol enums. A non-`nil` effort MUST require enabled generation and an exact renderer mapping; rendered input steering permits legacy blended output independently of separately negotiated final-only projection. Chat reasoning_effort and Responses reasoning.effort follow the request-local reasoning-effort change; negotiated output controls retain their activation requirements.

#### Scenario: Omitted public reasoning control

- **WHEN** Chat Completions or Responses omits reasoning control and effort
- **THEN** Orchard preserves `model_default + legacy_blended` with no selected effort
- **AND** it does not add a synthesized tier to the existing request bytes, hash domain, or serializer behavior

#### Scenario: Contradictory effort control

- **WHEN** an explicit control supplies an effort tier with `generation_policy = model_default` or `disabled`
- **THEN** Orchard rejects the request before its first Request write, scheduling, dispatch, or model invocation
- **AND** it does not downgrade the request or substitute a renderer value

### Requirement: Exact renderer mappings remain provider-neutral at the canonical boundary

The Controller SHALL resolve a selected canonical tier only through a closed mapping bound to the exact model artifact digest, chat-template digest, render-contract name, and render-contract version required by `SPEC.md` sections 3.4 and 3.5. The returned render metadata MUST prove that the applied effort is exactly the selected tier before dispatch. Public callers MUST NOT provide template keywords or arbitrary unregistered provider-specific values. Registered rendered identifiers may appear in canonical rendered input without authorizing negotiated protocol values.

#### Scenario: A qualified mapping uses a provider-specific value

- **WHEN** a negotiated exact renderer mapping qualifies canonical `high` through a provider-specific value
- **THEN** Orchard keeps `high` as the canonical policy value
- **AND** it does not promote the provider-specific value into negotiated canonical vocabulary or another artifact's mapping
- **AND** separately registered rendered input may expose that identifier only through its own exact model/template contract

#### Scenario: Render metadata reports a different applied effort

- **WHEN** returned render metadata reports an applied effort that is absent or differs from the selected canonical tier
- **THEN** Orchard fails the Request before dispatch with the existing `503 server_error` and `runtime_incompatible` mapping rather than a caller error
- **AND** it does not accept the rendered prompt, infer a mapping, or reselect a tier
