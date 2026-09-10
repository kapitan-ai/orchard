## ADDED Requirements

### Requirement: Selected effort is part of complete negotiated evidence

Runtime Endpoint implementations SHALL conform to `SPEC.md` sections 6.4, 7.5.3a, and 13.1 by advertising and proving a selected non-`nil` effort only as part of one complete tuple. The tuple MUST include generation policy, projection, reasoning effort, exact artifact and template digests, render contract and version, parser family and version, runtime contract version, and event-binding version. Separate lists MUST NOT authorize an unadvertised combination.

#### Scenario: Observation lists a tier but not its complete tuple

- **WHEN** a fresh observation lists a canonical effort tier without the exact complete tuple
- **THEN** Orchard treats the evidence as insufficient
- **AND** it does not dispatch the selected-effort Request

#### Scenario: Loaded worker proves a different tier

- **WHEN** the loaded-worker acceptance proof differs from the selected tier or any other pinned tuple value
- **THEN** Orchard fails before model invocation with the existing `runtime_incompatible` boundary
- **AND** it emits no content or usage
