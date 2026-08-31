## ADDED Requirements

### Requirement: Canonical reasoning behavior follows the apex contract

Orchard SHALL implement reasoning policy, projection, legacy compatibility, staged public exposure, Console defaults, and assistant-history handling from `SPEC.md` sections 3.4, 3.5, 7.2.1, and 7.2.8 without creating a second normative contract in OpenSpec.
Implementation MUST preserve omitted public controls on the complete legacy pipeline and MUST keep concrete public reasoning fields and structured reasoning wire shapes disabled until their separate contracts are accepted.

#### Scenario: A capable endpoint receives an omitted public control

- **WHEN** Chat Completions or Responses omits reasoning control and the selected endpoint supports negotiated reasoning
- **THEN** Orchard preserves the complete legacy request, output, capture, hash, and replay behavior
- **AND** it does not infer or enter a negotiated reasoning mode

#### Scenario: An explicit control lacks an accepted contract

- **WHEN** a caller requests reasoning behavior whose public field or exact negotiated contract has not been accepted
- **THEN** Orchard rejects the request before dispatch
- **AND** it does not downgrade the request to legacy blended output
