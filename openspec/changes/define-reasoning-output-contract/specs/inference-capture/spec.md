## ADDED Requirements

### Requirement: Reasoning retention follows the selected public projection

Reasoning hidden by `projection = final_only` SHALL be ephemeral under `none`, `metadata`, and `full`.
Hidden reasoning MUST NOT enter canonical request content, public events, request or response payloads, request events, response previews, scheduler metadata, logs, traces, metrics, audit payloads, crash evidence, diagnostics, or support bundles.
The canonical Request MAY retain only closed non-content reasoning policy, provenance, exact contract identifiers, `output_usage_status`, and exact or unknown usage detail allowed by its effective capture mode.
If a later accepted contract enables selected public `reasoning_structured`, only `full` MAY retain that selected reasoning as part of the exact assembled public response required for replay.
This requirement refines `SPEC.md` sections 9.3 and 10.10.

#### Scenario: Full capture does not retain hidden reasoning

- **WHEN** a `full` Request uses `projection = final_only` and the model generates reasoning
- **THEN** exact total usage includes the reasoning tokens when proven
- **AND** no hidden reasoning content is persisted or included in operational evidence

#### Scenario: Selected structured reasoning is retained only under full

- **WHEN** a later accepted contract enables `reasoning_structured` and the public response selects reasoning content
- **THEN** `full` may retain that content in the exact assembled public response
- **AND** `none` and `metadata` retain no reasoning content

### Requirement: Hashing and replay preserve the exact historical public projection

`response_hash` SHALL hash the exact assembled public terminal response after projection and SHALL NOT add hidden reasoning bytes, SSE framing, or chunk boundaries to the hash domain.
For `final_only`, and for a later accepted `reasoning_structured` projection, `response_preview` SHALL derive only from final-answer text and MUST NOT contain hidden or selected public reasoning.
For omitted `legacy_blended`, `response_preview` SHALL preserve its existing derivation from undifferentiated public assistant text without parsing, stripping, or reclassification.
The synthesized omitted reasoning defaults and `effective_contract.mode = legacy` marker SHALL remain outside the existing `body_hash` domain.
Idempotent replay SHALL return the retained historical public response payload exactly and MUST NOT rerender, reparse, reproject, or recover hidden reasoning.
Existing rows MUST NOT be reclassified by delimiter matching, parser heuristics, or model-family inference.
This requirement refines `SPEC.md` section 10.10.

#### Scenario: Equivalent stream chunking produces the same response hash

- **WHEN** two executions assemble the same selected public terminal response through different SSE chunk boundaries or with different hidden reasoning bytes
- **THEN** the assembled public bytes produce the same `response_hash`
- **AND** hidden reasoning bytes are not separately added to the hash domain

#### Scenario: Historical blended response is replayed

- **WHEN** Orchard replays a retained legacy blended response after newer reasoning parsers exist
- **THEN** Orchard returns the retained historical payload exactly
- **AND** it does not split, strip, or reclassify the historical output

#### Scenario: Omitted blended preview remains compatible

- **WHEN** an omitted legacy Request produces undifferentiated public assistant text containing reasoning-like delimiters
- **THEN** metadata or full preview behavior uses that existing blended public text without parser classification
- **AND** an otherwise identical omitted public body retains its existing `body_hash`
