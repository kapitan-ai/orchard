## ADDED Requirements

### Requirement: Negotiated reasoning retries use the frozen canonical source

Automatic retry SHALL pin every field of the negotiated reasoning tuple and require a different endpoint to provide fresh live evidence and a new preparation proof for the same tuple. It SHALL not pin attempt-local authorization, preparation identity, selected profile, or worker incarnation.

An operator retry may recover that tuple only from `requests.canonical_request["reasoning"]` retained under full capture. If the value is absent or malformed, Orchard SHALL fail the retry with `retry_source_unavailable`; it SHALL not rerender historical messages, renegotiate a newer contract, downgrade to legacy behavior, or create a new persistence column.

#### Scenario: Full-capture retry source is unavailable

- **WHEN** an operator retry lacks a valid retained `canonical_request["reasoning"]`
- **THEN** Orchard returns `retry_source_unavailable`
- **AND** it performs no model invocation or replacement rendering
