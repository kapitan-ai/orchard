## ADDED Requirements

### Requirement: Selected effort is part of complete negotiated evidence

For negotiated selected-effort Requests, Runtime Endpoint implementations SHALL conform to `SPEC.md` sections 6.4, 7.5.3a, and 13.1 by advertising and proving a selected non-`nil` effort only as part of one complete tuple. The tuple MUST include generation policy, projection, reasoning effort, exact artifact and template digests, render contract and version, parser family and version, runtime contract version, and event-binding version. Separate lists MUST NOT authorize an unadvertised negotiated combination. The separate rendered-input contract in `SPEC.md` sections 3.4–3.5 (and its section 6.4 advertisement boundary) proves the selected native arguments during tokenization and does not add negotiated effort evidence or Worker protocol fields.

#### Scenario: Observation lists a tier but not its complete tuple

- **WHEN** a fresh observation lists a canonical effort tier for a negotiated Request without the exact complete tuple
- **THEN** Orchard treats the evidence as insufficient
- **AND** it does not dispatch that negotiated selected-effort Request

#### Scenario: Selected loaded worker prepares the exact tier

- **WHEN** fresh observation and valid render proof permit Orchard to select and dispatch a negotiated selected-effort Request to an already loaded placement
- **THEN** unary `PrepareInference` validates the exact tuple against the current loaded binding and worker incarnation before model invocation
- **AND** the Controller validates the returned proof and single-use authorization before marking the attempt running or forwarding later events
- **AND** a missing, malformed, stale, or mismatched proof fails through the existing `503 server_error` and `runtime_incompatible` mapping without model invocation, content, or usage

#### Scenario: Loaded worker proves a different tier

- **WHEN** the loaded-worker acceptance proof for a negotiated Request differs from the selected tier or any other pinned tuple value
- **THEN** Orchard fails before model invocation with the existing `runtime_incompatible` boundary
- **AND** it emits no content or usage
