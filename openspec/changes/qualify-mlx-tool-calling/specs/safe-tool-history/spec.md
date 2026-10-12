## ADDED Requirements

### Requirement: Safe tool-result continuation

Under `SPEC.md` §3.5, legacy and contract-v3 segmented rendering SHALL decode assistant tool-call argument JSON strings into objects before rendering and, when applicable, caller-string tagging.
Malformed, non-object, duplicate-key, and non-finite arguments SHALL fail before inference without echoing their contents.
Recursive argument keys and string values SHALL remain caller-authored material subject to safe encoding.
Legacy rendering SHALL forward only each message's `role`, normalized `content`, valid `tool_calls`, and string `tool_call_id` and `name` values.
Within each tool call it SHALL forward only `id`, `type`, and the function `name` and `arguments`.
It SHALL NOT forward `reasoning_content`, `reasoning`, or other unlisted message, tool-call, or function fields.
Legacy rendering SHALL reject invalid tool-call entries as invalid input without echoing their contents.
Omitted-control legacy content SHALL remain byte-preserved; delimiter-like text SHALL NOT be heuristically reconstructed into a typed reasoning channel under `SPEC.md` §7.2.8–§7.2.9.

#### Scenario: Legacy rendering excludes unlisted history fields

- **WHEN** a legacy render request carries valid tool-call history together with prior-reasoning or other unlisted message, tool-call, or function fields
- **THEN** the template receives only the allowlisted fields, normalized argument objects, tool-result IDs, names, and byte-preserved content
- **AND** reasoning-like delimiter text in assistant content is neither split nor reconstructed

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
- **AND** audited trimming after macro capture or concatenation operates on the unmarked segment text and retains each surviving caller span's original marker identity and provenance
- **AND** only bytes removed by whole-value trimming may lose their marker envelopes; another occurrence of the original leaf remains protected
- **AND** unsupported transforms, malformed marker spans, and marker-bearing trim character sets fail closed

#### Scenario: Assistant tool-call content is absent

- **WHEN** valid nonempty assistant function-call history has null or omitted content
- **THEN** legacy and segmented rendering treat the absent text as an empty string
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
