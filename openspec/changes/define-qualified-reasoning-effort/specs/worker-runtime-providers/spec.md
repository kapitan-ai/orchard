## ADDED Requirements

### Requirement: Worker providers preserve selected-effort conformance boundaries

Every supported Worker Runtime provider SHALL satisfy the provider-neutral selected-effort conformance rules in `SPEC.md` section 7.5.3a through shared fixtures. A provider MUST validate the complete selected tuple before invocation and MUST NOT infer a provider mapping from a model name, template keyword, or independent tier list. A provider SHALL advertise a non-`nil` tier for an exact tuple only when those fixtures show the tuple satisfies the enabled-conformance rule, and MUST NOT consult a repository-owned qualification record to make that decision.

#### Scenario: Provider receives a static-mapping fixture only

- **WHEN** static evidence proves that an exact renderer can accept one provider-specific mapping value
- **THEN** the provider still requires complete runtime tuple advertisement and loaded-worker acceptance before execution
- **AND** the static fixture alone does not authorize dispatch or a support claim

#### Scenario: A tuple fails the enabled-conformance fixture

- **WHEN** provider conformance fixtures show that an exact tuple's tier can complete without valid non-empty reasoning content
- **THEN** the provider does not advertise that tier for that tuple
- **AND** the resulting request fails the existing pre-dispatch capability boundary rather than reaching model invocation
