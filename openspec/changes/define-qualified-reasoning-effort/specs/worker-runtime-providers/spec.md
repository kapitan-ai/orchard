## ADDED Requirements

### Requirement: Worker providers preserve selected-effort conformance boundaries

Every supported Worker Runtime provider SHALL satisfy the provider-neutral selected-effort conformance rules in `SPEC.md` section 7.5.3a through shared fixtures. A provider MUST validate the complete selected tuple before invocation and MUST NOT infer a provider mapping from a model name, template keyword, or independent tier list. A provider SHALL advertise a non-`nil` tier only for an exact tuple that has a qualified renderer mapping and passes provider-neutral protocol conformance. That advertisement asserts no per-artifact semantic tier property, and a provider MUST NOT consult a repository-owned qualification record or publish a semantic tier assertion of its own.

#### Scenario: Provider receives a static-mapping fixture only

- **WHEN** static evidence proves that an exact renderer can accept one provider-specific mapping value
- **THEN** the provider still requires complete runtime tuple advertisement and loaded-worker acceptance before execution
- **AND** the static fixture alone does not authorize dispatch or a support claim

#### Scenario: An advertised tier produces no reasoning content

- **WHEN** an advertised and dispatched tier completes without valid non-empty reasoning content
- **THEN** the Request terminalizes as a generation-policy conformance failure with `500 api_error` and `internal_error`
- **AND** the provider neither relaxes the enabled-conformance rule for that tier nor treats advertisement as a semantic guarantee
