## ADDED Requirements

### Requirement: Worker providers preserve selected-effort conformance boundaries

Every supported Worker Runtime provider SHALL satisfy the provider-neutral selected-effort conformance rules in `SPEC.md` section 7.5.3a through shared fixtures. A provider MUST validate the complete selected tuple before invocation and MUST NOT infer a provider mapping from a model name, template keyword, or independent tier list.

#### Scenario: Provider receives a static-mapping fixture only

- **WHEN** static evidence proves that an exact renderer can accept one provider-specific mapping value
- **THEN** the provider still requires complete runtime tuple advertisement and loaded-worker acceptance before execution
- **AND** the static fixture alone does not authorize dispatch or a support claim
