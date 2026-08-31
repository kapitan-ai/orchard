## ADDED Requirements

### Requirement: Worker providers conform to the negotiated reasoning contract

Every supported Worker Runtime provider SHALL satisfy the provider-neutral acceptance, parsing, projection, and accounting behavior defined by `SPEC.md` sections 4.9 and 7.5.3a through shared conformance tests.
At the current Worker Runtime-to-Runtime Endpoint boundary, a provider SHALL emit exact cumulative total output usage and SHALL NOT emit a reasoning-token subset; the Controller SHALL record the Worker-originated total with `output_usage_status = exact` in terminal Inference Attempt evidence.
When a provider can prove an exact reasoning-token subset, it SHALL retain that subset as Worker-internal non-content evidence until a separately accepted presence-aware Runtime Endpoint contract exists.
When the subset cannot be proved, the provider MUST preserve unknown rather than report zero.

#### Scenario: A parser marker spans decoded chunks

- **WHEN** a negotiated parser marker is split across decoded chunks
- **THEN** every conforming provider produces the same channel classification under the pinned parser contract
- **AND** no framing fragment enters selected output or tool-call parsing

#### Scenario: A provider cannot prove the reasoning-token subset

- **WHEN** a provider proves exact cumulative total output usage but cannot prove a separate reasoning-token count
- **THEN** its current Runtime Endpoint terminal event carries the exact total only and the Controller records its status as exact in attempt evidence
- **AND** the internal reasoning-token subset remains unknown rather than zero
