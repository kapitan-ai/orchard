## ADDED Requirements

### Requirement: Limited chat-template construction globals

Under SPEC.md §3.5, the chat-template renderer SHALL expose dictionary construction
through a limited callable, not the Python dictionary type. It SHALL preserve
ordinary dictionary construction and `fromkeys`. Namespace construction and
assignment SHALL reject underscore-prefixed names in both plain and
marker-aware rendering. Ordinary mapping keys SHALL remain unaffected, and
supported operations SHALL retain the existing marker-provenance checks.

#### Scenario: Construct ordinary template data

- **WHEN** a template constructs dictionaries or reads and updates public namespace state
- **THEN** its ordinary rendered output and caller provenance remain unchanged

#### Scenario: Use reserved namespace state

- **WHEN** a template constructs or assigns an underscore-prefixed namespace name
- **THEN** rendering fails with a sandbox security error

#### Scenario: Use the dictionary global as a type

- **WHEN** a template uses the dictionary global as a Python type
- **THEN** the renderer does not expose that operation
