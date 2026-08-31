## ADDED Requirements

### Requirement: Provider-neutral reasoning parsing precedes tools and stops

Every Worker Runtime provider that advertises a negotiated reasoning contract SHALL implement the same versioned stateful parser semantics over the ordered decoded stream.
The parser SHALL classify reasoning, final-answer text, and framing before tool-call classification and before caller stop-sequence matching.
Only final-answer text SHALL enter tool-call parsing, and caller stop sequences SHALL apply only to final-answer text.
Parser framing markers MUST NOT be emitted as reasoning, final text, tool content, errors, or diagnostics.
This requirement refines `SPEC.md` sections 4.9, 7.5.2a, and 7.5.3a.

#### Scenario: Chunk boundaries split a parser marker

- **WHEN** a negotiated parser marker is split across decoded chunks
- **THEN** the stateful parser classifies the ordered stream according to the pinned parser version
- **AND** no partial marker enters a content channel or tool parser

#### Scenario: Caller stop appears in reasoning

- **WHEN** a caller stop sequence appears only in a reasoning segment
- **THEN** the Worker Runtime does not stop generation because of that segment
- **AND** the stop applies if it later appears in ordinary final-answer text

### Requirement: Explicit parser failures fail closed without content fallback

A Worker Runtime SHALL terminalize an explicit `final_only` or `reasoning_structured` Request deterministically when parser state is malformed, ambiguous, incomplete, or incompatible with the pinned contract.
It SHALL also terminalize when any reasoning frame or content occurs under `generation_policy = disabled`, or when `generation_policy = enabled` reaches terminal completion without valid non-empty reasoning.
The failure MUST NOT emit ambiguous bytes as raw blended output, final text, tool content, error detail, or diagnostics.
Every such post-execution failure SHALL use `terminal_conformance + internal_error`, emit no selected output or parser content, and remain non-retryable.
The omitted legacy pipeline SHALL retain its existing processing order and byte behavior and SHALL leave unknown or unqualified output undifferentiated.
This requirement refines `SPEC.md` sections 7.5.3a and 12.7.

#### Scenario: Explicit stream ends in incomplete parser state

- **WHEN** an explicit final-only stream terminates before the pinned parser reaches a valid terminal state
- **THEN** the Worker Runtime emits a deterministic terminal-conformance failure
- **AND** it emits none of the ambiguous buffered content
- **AND** it does not request raw-output fallback

#### Scenario: Omitted legacy stream uses unknown framing

- **WHEN** an omitted legacy Request emits unknown or unqualified framing-like text
- **THEN** the Worker Runtime preserves the existing raw blended output behavior
- **AND** it does not apply the negotiated reasoning parser

#### Scenario: Disabled policy enters a reasoning frame

- **WHEN** a negotiated Worker Runtime observes a reasoning frame or reasoning content under `generation_policy = disabled`
- **THEN** it emits `terminal_conformance + internal_error`
- **AND** it emits no selected output or parser content

#### Scenario: Enabled policy has no reasoning

- **WHEN** a negotiated Worker Runtime reaches terminal completion under `generation_policy = enabled` without valid non-empty reasoning
- **THEN** it emits `terminal_conformance + internal_error`
- **AND** it emits no selected output or parser content

### Requirement: Hidden reasoning is disposed after exact accounting

For `projection = final_only`, the Worker Runtime SHALL account for hidden reasoning and then discard its content at the Worker contract boundary.
Hidden reasoning MUST NOT cross that boundary as text, metadata, an error, diagnostics, or an untyped event.
A typed reasoning delta MAY cross the boundary only for a fully negotiated `reasoning_structured` Request whose binding advertises that event.
This requirement refines `SPEC.md` sections 7.5.3a and 10.10.

#### Scenario: Full capture request hides reasoning

- **WHEN** a `full` capture Request uses `projection = final_only`
- **THEN** the Worker Runtime includes hidden reasoning tokens in exact total usage
- **AND** hidden reasoning content does not cross the Worker contract boundary

### Requirement: Terminal usage distinguishes exact totals from unknown subsets

Every Worker-originated terminal event SHALL carry exact cumulative total output usage for that attempt, including reasoning and final-answer tokens, with `output_usage_status = exact`.
The event SHALL carry an exact reasoning-token subset when the Worker Runtime can prove it.
An unavailable or unproven reasoning-token subset MUST remain absent or explicitly unknown and MUST NOT default to zero.
The subset SHALL remain internal non-content evidence until separately accepted presence-aware Runtime Endpoint and public API usage contracts define its encoding.
This requirement refines `SPEC.md` sections 5.3 and 7.5.3a.

#### Scenario: Exact reasoning subset is unavailable

- **WHEN** a provider can prove exact total output tokens but cannot prove a separate reasoning-token subset
- **THEN** terminal usage carries the exact total
- **AND** reasoning-token usage remains unknown rather than zero

#### Scenario: Exact reasoning subset is zero

- **WHEN** a provider proves that a completed attempt generated zero reasoning tokens
- **THEN** terminal usage records an exact reasoning-token count of zero
- **AND** consumers can distinguish that value from unknown usage

### Requirement: Loaded Worker Runtime proves negotiated identity before invocation

A loaded Worker Runtime SHALL validate the requested complete reasoning tuple and produce an authoritative execution-acceptance proof before model invocation.
The proof SHALL echo the tuple and identify the loaded worker incarnation.
The Worker Runtime MUST NOT invoke the model or emit content or usage when the proof is missing, malformed, stale, or mismatched.
Such a failure SHALL return `runtime_incompatible` through the pre-acceptance boundary.
This requirement refines `SPEC.md` section 7.5.3a.

#### Scenario: Loaded worker differs from the observed worker

- **WHEN** the loaded worker incarnation cannot reproduce the observed complete tuple
- **THEN** it rejects the negotiated execution before model invocation with `runtime_incompatible`
- **AND** it emits no content or usage

## MODIFIED Requirements

### Requirement: Versioned Runtime Capability Negotiation

A Worker Runtime provider SHALL report protocol version, provider identity and version, supported artifact formats, runtime features, acceleration implementations, device-resource bindings, memory semantics, concurrency, cache capabilities, and any reasoning capability before those facts authorize work.
Reasoning capability SHALL enumerate complete supported tuples containing generation policy, projection, exact compatible model artifact and chat-template contracts, render contract and version, parser family and version, runtime contract version, and event-binding version.
Independent value lists whose Cartesian product could authorize an unadvertised tuple SHALL be invalid evidence.
Unknown, malformed, incompatible, stale, false, or absent required capability evidence MUST NOT be treated as affirmative compatibility.
This requirement refines `SPEC.md` sections 4.6.1, 4.9, 6.4, and 7.5.3a while preserving the provider-neutral capability-negotiation contract.

#### Scenario: New Node Agent contacts an older worker

- **WHEN** an older worker omits additive capability negotiation fields
- **THEN** the Node Agent decodes the response without crashing
- **AND** it does not claim capabilities the worker did not prove
- **AND** it sends only legacy requests and accepts only legacy event variants

#### Scenario: Worker advertises a different exact template contract

- **WHEN** a Worker Runtime advertises reasoning support for a different model artifact or chat-template digest
- **THEN** it does not prove support for the selected Request
- **AND** Orchard does not dispatch the explicit mode to that worker
