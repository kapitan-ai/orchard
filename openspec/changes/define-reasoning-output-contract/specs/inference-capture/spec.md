## ADDED Requirements

### Requirement: Reasoning capture follows the selected public projection

Inference capture, hashing, preview, and replay implementations SHALL conform to the reasoning retention rules in `SPEC.md` sections 9.3 and 10.10 without copying those rules into a second normative specification.
Hidden reasoning MUST remain ephemeral under every capture mode, while retained public output SHALL preserve its exact historical projection.

#### Scenario: Full capture receives hidden reasoning

- **WHEN** a `full` capture Request uses `projection = final_only` and the model generates reasoning
- **THEN** the exact generated total may account for those tokens as non-content evidence
- **AND** no hidden reasoning content is retained

#### Scenario: Historical legacy output is replayed

- **WHEN** Orchard replays retained legacy blended output after negotiated reasoning support exists
- **THEN** Orchard returns the retained public response exactly
- **AND** it does not parse or reclassify the historical output
