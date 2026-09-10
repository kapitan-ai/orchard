## ADDED Requirements

### Requirement: Retry pins selected reasoning effort

Automatic and operator retry implementations SHALL preserve a selected canonical reasoning-effort tier together with the exact negotiated identity required by `SPEC.md` sections 7.3.4 and 7.5.3a. Retry MUST NOT rerender, remap, omit, substitute, downgrade, or otherwise renegotiate effort.

#### Scenario: Retry endpoint lacks the selected effort tuple

- **WHEN** the Controller cannot prove another endpoint supports the source Request's exact selected-effort tuple
- **THEN** Orchard declines retry before dispatch
- **AND** it does not retry with a different tier or the template default
