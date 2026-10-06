## ADDED Requirements

### Requirement: Rendered effort identity remains frozen across attempts

Automatic attempts SHALL reuse the prepared rendered prompt, canonical tier and complete rendered-input identity without resolving another effort or template. Operator retry SHALL reject retained rendered effort until its explicit revalidation contract is accepted, following SPEC §§3.4 and 3.5.

#### Scenario: A prepared rendered effort request retries automatically

- **WHEN** an otherwise eligible automatic retry uses a request prepared with rendered effort
- **THEN** it retains the exact prepared input and complete effective identity
- **AND** it does not rerender, substitute or omit the selected effort

#### Scenario: An operator retries retained rendered effort

- **WHEN** operator retry encounters a retained rendered effort contract
- **THEN** it rejects the unsupported retry before creating a descendant Request
