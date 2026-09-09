## ADDED Requirements

### Requirement: Safe tool-result continuation

Under `SPEC.md` §3.5, contract-v3 segmented rendering SHALL decode assistant tool-call argument JSON strings into objects before baseline rendering and caller-string tagging.
Malformed, non-object, duplicate-key, and non-finite arguments SHALL fail before inference without echoing their contents.
Recursive argument keys and string values SHALL remain caller-authored material subject to safe encoding.

#### Scenario: Mapping-based template renders tool history

- **WHEN** assistant tool-call history contains a JSON argument object string and a matching tool result
- **THEN** the template receives the argument object with its scalar types preserved
- **AND** the same normalized history supplies baseline and tagged renders
- **AND** the dual-render comparison remains mandatory

#### Scenario: Assistant content is empty

- **WHEN** a caller string is exactly empty
- **THEN** tagging preserves the empty value without allocating markers
- **AND** all nonempty values remain tagged
- **AND** all original bytes, including edge whitespace, stay inside ordinary markers during raw and JSON rendering
- **AND** trimming operates on the original value and keeps every nonempty result tagged
- **AND** text parts are concatenated before tagging so combined-value trimming preserves internal whitespace
- **AND** trimming a marker-bearing plain string after coercion fails closed through both filters and bound methods

#### Scenario: Assistant tool-call content is absent

- **WHEN** valid nonempty assistant function-call history has null or omitted content
- **THEN** segmented rendering treats the absent text as an empty string
- **AND** invalid tool-call history and absent user or tool content still fail

#### Scenario: One request has incompatible rendering

- **WHEN** a request-dependent render or decode failure occurs
- **THEN** the request fails without dispatch
- **AND** the failure does not poison the bundle compatibility cache
- **AND** deterministic tokenizer and sentinel-preflight incompatibilities remain cacheable

#### Scenario: Template transforms protected arguments

- **WHEN** a template attempts an unaudited operation, character indexing, slicing, iteration, or unpacking on protected text
- **THEN** segmented rendering fails before exposing unprotected fragments or prompt IDs
- **AND** this applies after concatenation, macro capture, and JSON serialization, including when preflight is cached

#### Scenario: Audited template operations preserve provenance

- **WHEN** a template uses whole-value traversal, original-value trimming, serialization, concatenation, observations, or the audited literal schema-key replacements
- **THEN** surviving caller text retains its marker envelopes
- **AND** serialization, concatenation, and replacement preserve marker identity counts and balanced spans
- **AND** ignored whole values and empty trims remain valid without declassifying other uses

#### Scenario: Template rendering diverges

- **WHEN** tagged argument rendering differs from baseline rendering after removing markers
- **THEN** the request fails with a template incompatibility
- **AND** no unprotected fallback dispatch occurs
