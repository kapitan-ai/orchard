## ADDED Requirements

### Requirement: Canonical reasoning behavior follows the apex contract

Orchard SHALL implement reasoning policy, projection, legacy compatibility, staged public exposure, Console defaults, and assistant-history handling from `SPEC.md` sections 3.4, 3.5, 7.2.1, and 7.2.8 without creating a second normative contract in OpenSpec.
Implementation MUST preserve omitted public controls on the complete legacy pipeline and MUST keep unaccepted concrete public final-only selectors and structured reasoning wire shapes disabled until their separate contracts are accepted.

#### Scenario: A capable endpoint receives an omitted public control

- **WHEN** Chat Completions or Responses omits reasoning control and the selected endpoint supports negotiated reasoning
- **THEN** Orchard preserves the complete legacy request, output, capture, hash, and replay behavior
- **AND** it does not infer or enter a negotiated reasoning mode

#### Scenario: An explicit control lacks an accepted contract

- **WHEN** a caller requests reasoning behavior whose required public input or exact effective contract has not been accepted
- **THEN** Orchard rejects the request before dispatch
- **AND** it does not downgrade the request to legacy blended output

#### Scenario: Accepted input effort preserves legacy blended projection

- **WHEN** a caller selects a supported request-local effort under the exact rendered-input contract defined by `request-local-reasoning-effort` and SPEC §3.4
- **THEN** Orchard applies and verifies its exact native render arguments before scheduling
- **AND** legacy blended output does not imply negotiated separation, final-only privacy or structured reasoning support
