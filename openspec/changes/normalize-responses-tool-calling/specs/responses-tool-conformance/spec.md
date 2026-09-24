## ADDED Requirements

### Requirement: Endpoint-local Responses tools
Per SPEC.md §7.2.5, Responses SHALL accept flattened function definitions and
named choices, preserve strict, and normalize before shared tool validation.
Nested definitions SHALL remain a compatibility extension. Ambiguous mixed
objects and unknown kinds SHALL fail closed. Chat semantics SHALL not change.

#### Scenario: Canonical function and choice
- **WHEN** a client supplies a flattened function and names it in tool_choice
- **THEN** preparation receives the equivalent nested internal definition
- **AND** registry refs are resolved before tokenization and dispatch

### Requirement: Typed client tool history
Responses SHALL accept function_call and function_call_output history preserving
call IDs and order. Malformed calls and orphan or duplicate results SHALL be
rejected before dispatch. Orchard components SHALL NOT execute client tools.

#### Scenario: Client continuation
- **WHEN** a client returns a result for a preceding call
- **THEN** canonical history contains the same call ID and exact result

### Requirement: Correlated call stream lifecycle
Successful streamed calls SHALL expose response.output_item.added,
response.function_call_arguments.delta, response.function_call_arguments.done,
response.output_item.done and response.completed with consistent IDs and indices.
Malformed or interrupted streams SHALL NOT complete partial calls.

#### Scenario: Multiple calls with public text
- **WHEN** a stream includes text and multiple calls
- **THEN** each call has a distinct correlated lifecycle and terminal output item
- **AND** public text remains separate from tool arguments
