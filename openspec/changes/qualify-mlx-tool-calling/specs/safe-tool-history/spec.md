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
- **AND** nonempty values, including whitespace-only values, remain tagged

#### Scenario: Template transforms protected arguments

- **WHEN** tagged argument rendering differs from baseline rendering after removing markers
- **THEN** the request fails with a template incompatibility
- **AND** no unprotected fallback dispatch occurs
