## ADDED Requirements

### Requirement: Canonical reasoning policy separates generation from projection

Every canonical Request SHALL carry `generation_policy` as `model_default`, `disabled`, or `enabled`, `projection` as `legacy_blended`, `final_only`, or `reasoning_structured`, source provenance, and one exact effective contract.
The Controller MUST NOT derive generation policy from projection or projection from generation policy.
The outer `generation_policy` and `projection` SHALL be the sole authority for those axes and MUST NOT be duplicated inside the effective contract.
An omitted Request SHALL carry exactly `effective_contract.mode = legacy` without nullable negotiated identity.
A negotiated Request SHALL carry `mode = negotiated` plus non-empty exact `model_artifact_digest`, `chat_template_digest`, `render_contract`, `render_contract_version`, `parser_family`, `parser_version`, `runtime_contract_version`, and `event_binding_version` for every attempt of the logical Request.
The current valid combinations are closed: omitted public requests use `model_default + legacy_blended`; Console defaults use `disabled + final_only`; Console explicit and later accepted public explicit controls may use `model_default`, `disabled`, or `enabled` only with `final_only`; and `reasoning_structured` remains unavailable until its separate contract expands this matrix.
Every other combination SHALL fail before the first Request write.
This requirement refines `SPEC.md` sections 3.4 and 3.5.

#### Scenario: Generation remains independent from public projection

- **WHEN** a caller selects reasoning generation with `projection = final_only`
- **THEN** Orchard may generate reasoning under the exact negotiated contract
- **AND** the public response contains only final-answer and otherwise selected existing output
- **AND** hidden reasoning does not change the projection

#### Scenario: Effective contract stays pinned

- **WHEN** a logical Request proceeds from attempt 1 to attempt 2
- **THEN** both negotiated attempts use the same exact model artifact, chat template, render contract, parser, generation policy, projection, runtime, and event-binding identity
- **AND** Orchard does not infer the contract again after scheduling

#### Scenario: Contradictory reasoning axes are rejected

- **WHEN** a canonical Request shape duplicates or contradicts the authoritative generation policy or projection inside its effective contract
- **THEN** Orchard rejects the shape before the first Request write
- **AND** no scheduling or dispatch occurs

#### Scenario: Invalid source combination is rejected

- **WHEN** omitted-public provenance is paired with a negotiated projection or explicit provenance is paired with `legacy_blended`
- **THEN** Orchard rejects the Request before persistence
- **AND** it does not normalize the invalid tuple into another mode

### Requirement: Omitted public controls preserve the complete legacy pipeline

When Chat Completions or Responses omits reasoning control, Orchard SHALL normalize the Request to `generation_policy = model_default`, `projection = legacy_blended`, and omitted-public provenance.
That Request MUST preserve the existing template rendering, Worker Runtime text processing, tool classification, stop behavior, Output Commitment, public blended output, capture, hashing, and replay behavior.
Advertised reasoning capability MUST NOT silently move an omitted Request into the negotiated reasoning pipeline.
The synthesized reasoning defaults and `mode = legacy` marker MUST remain outside the omitted request's existing `body_hash` domain.
This requirement refines `SPEC.md` sections 3.4, 7.2.1, and 13.1.

#### Scenario: Capable endpoint receives an omitted request

- **WHEN** every selected component supports a newer reasoning contract but the public request omits reasoning control
- **THEN** Orchard uses the complete legacy request and event path
- **AND** the response preserves existing blended output behavior
- **AND** an otherwise identical public body retains its existing body hash

#### Scenario: Legacy output contains unknown delimiters

- **WHEN** an omitted legacy Request produces output that resembles reasoning delimiters but has no negotiated parser contract
- **THEN** Orchard returns the output as undifferentiated raw blended content
- **AND** it does not infer or strip reasoning

### Requirement: Explicit modes require a closed exact render contract

The Controller SHALL own typed generation policy, projection, parser-family selection, and version selection for explicitly negotiated reasoning modes.
The public API MUST NOT expose arbitrary chat-template keyword arguments.
The tokenizer SHALL use a closed mapping for the exact model artifact and chat-template digest and SHALL return the exact render, parser, runtime, and provenance metadata needed to prove the effective contract.
Missing, stale, false, malformed, unknown, or incompatible evidence SHALL fail an explicit control before dispatch.
Capability evidence SHALL enumerate complete supported tuples rather than independent value lists whose Cartesian product could authorize an unsupported combination.
Capability MUST NOT be inferred from a model name, family substring, unversioned parser heuristic, unqualified template inspection, or manual model-qualification status.
This requirement refines `SPEC.md` sections 3.5, 6.4, and 7.5.3a.

#### Scenario: Exact template mapping is unavailable

- **WHEN** a caller explicitly requests final-only output but the exact artifact and template have no closed compatible mapping
- **THEN** Orchard rejects the request before dispatch
- **AND** it does not fall back to template default or legacy blended output

#### Scenario: Manual support claim exists without runtime capability

- **WHEN** an exact model tuple has an approved manual support claim but the live endpoint cannot prove the pinned reasoning contract
- **THEN** Orchard treats the explicit reasoning mode as unsupported
- **AND** the support claim does not authorize dispatch

#### Scenario: Exact template cannot honor an accepted control

- **WHEN** the exact artifact and template mapping cannot honor an accepted explicit control
- **THEN** Orchard returns `400 invalid_request_error` with code `unsupported_reasoning_control` before a Request write
- **AND** the failure is non-retryable and contains no model or parser content

### Requirement: Explicit projection fails closed and legacy projection remains raw

For a negotiated mode, Orchard SHALL classify the ordered decoded stream under the pinned parser contract before tool-call and caller-stop processing.
Only final-answer text SHALL enter tool-call parsing, and caller stop sequences SHALL apply only to final-answer text.
An explicit `final_only` or `reasoning_structured` parse failure MUST NOT fall back to raw blended output, expose ambiguous bytes, reclassify them as final text, or pass them to tool parsing.
Any observed reasoning frame or content under `generation_policy = disabled` SHALL fail terminal conformance.
Terminal completion without valid non-empty reasoning under `generation_policy = enabled` SHALL fail terminal conformance.
Those post-execution failures SHALL use `500 api_error` with public and durable code `internal_error`, no `param`, and no retry.
Omitted `legacy_blended` output SHALL retain the existing processing order and raw byte behavior.
This requirement refines `SPEC.md` sections 7.5.3a and 12.7.

#### Scenario: Explicit parser state is malformed

- **WHEN** an explicit final-only Request reaches malformed or ambiguous parser state
- **THEN** Orchard terminalizes with a deterministic fail-closed error
- **AND** no ambiguous content becomes public output, tool content, or error detail

#### Scenario: Caller stop appears during hidden reasoning

- **WHEN** a caller stop sequence appears only in hidden reasoning under a valid negotiated final-only Request
- **THEN** the stop does not terminate generation
- **AND** stop matching remains limited to ordinary final-answer text

#### Scenario: Disabled generation emits reasoning

- **WHEN** a negotiated Request with `generation_policy = disabled` enters a reasoning frame or emits reasoning content
- **THEN** Orchard terminalizes with `terminal_conformance + internal_error`
- **AND** it exposes no selected output or parser content and does not retry

#### Scenario: Enabled generation emits no reasoning

- **WHEN** a negotiated Request with `generation_policy = enabled` reaches terminal completion without valid non-empty reasoning
- **THEN** Orchard terminalizes with `terminal_conformance + internal_error`
- **AND** it exposes no selected output or parser content and does not retry

### Requirement: The first public release exposes only accepted final-only semantics

The first public reasoning-control release SHALL support explicit final-only semantics for Chat Completions and Responses only after a separate accepted API contract defines the concrete request field names.
Orchard MUST NOT expose an ad hoc public control before that gate is accepted.
Chat Completions raw structured reasoning SHALL remain unsupported.
Responses structured reasoning SHALL remain disabled until a later accepted contract defines its item and event names, raw-versus-summary semantics, synchronous representation, stream ordering, terminal behavior, capture, and replay.
This requirement refines `SPEC.md` sections 7.2.1, 7.2.4, and 7.2.5.

#### Scenario: Final-only semantics exist before field naming is accepted

- **WHEN** the internal final-only contract is implemented but no concrete public input-field contract has been accepted
- **THEN** Orchard exposes no new Chat Completions or Responses request field
- **AND** omitted requests continue to use legacy blended behavior

#### Scenario: Chat requests structured reasoning

- **WHEN** a Chat Completions request asks for raw structured reasoning
- **THEN** Orchard rejects the request during validation
- **AND** it does not downgrade the request to final-only or blended output

#### Scenario: Responses requests structured reasoning before its gate

- **WHEN** a Responses request asks for structured reasoning before the later wire contract is accepted
- **THEN** Orchard rejects the request during validation
- **AND** it emits no provisional reasoning item or event

### Requirement: Console defaults are strict and conversation history re-feeds final answers only

The Console Playground SHALL default to `generation_policy = disabled`, `projection = final_only`, and Console-default provenance.
An explicit Console control SHALL fail before dispatch unless the exact model, template, parser, and Runtime Endpoint contract proves support.
The Console SHALL keep reasoning and final-answer transcript channels separate and SHALL send only final-answer content as later assistant history.
Issue #189 SHALL remain a display-only fallback for unstructured legacy blended output and MUST NOT become policy, parser, capture, replay, or history authority.
This requirement refines `SPEC.md` section 7.2.8.

#### Scenario: Console default is unsupported

- **WHEN** the selected exact contract cannot disable reasoning and produce final-only output
- **THEN** the Console request fails before dispatch
- **AND** Orchard does not fall back to model default, blended output, or heuristic stripping

#### Scenario: Console continues a conversation

- **WHEN** a prior turn has separate reasoning and final-answer transcript channels
- **THEN** the next Request includes only the final-answer channel as assistant history
- **AND** the reasoning channel is not silently flattened or re-fed

### Requirement: Prior assistant content remains opaque

Orchard SHALL treat ordinary assistant message content as opaque caller-authored input.
Orchard MUST NOT infer, strip, restore, or promote prior reasoning from delimiter-like text.
Explicit structured prior-reasoning input SHALL remain unsupported in the first release and SHALL fail validation.
This requirement refines `SPEC.md` sections 3.4, 7.2.4, and 7.2.5.

#### Scenario: Assistant text resembles a reasoning delimiter

- **WHEN** ordinary assistant history contains text that resembles a model reasoning marker
- **THEN** Orchard preserves that text as caller content
- **AND** it does not reinterpret the text as structured prior reasoning
