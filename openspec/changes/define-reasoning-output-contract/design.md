# Design: Define reasoning output contract

## Context

Models may generate reasoning through template controls and may delimit reasoning in the decoded stream.
Those properties vary by exact model artifact, chat template, renderer, parser, Worker Runtime, and Runtime Endpoint contract.
A model-family name, a manual qualification record, or a successful sample response cannot prove that a particular request can be parsed without leaking or losing content.

Orchard also has an established legacy behavior.
When callers omit reasoning controls, the existing render, decode, tool, stop, output, capture, hash, and replay behavior is part of the compatibility contract.
The new contract therefore adds a negotiated path without silently changing omitted requests.

## Goals and non-goals

### Goals

- Preserve omitted Chat Completions and Responses behavior across the entire existing pipeline.
- Give the Controller a closed, typed, versioned reasoning policy and exact capability proof.
- Separate generation policy from public projection.
- Keep hidden reasoning out of every public, retained, operational, and diagnostic content surface.
- Make parser, commitment, usage, retry, and mixed-version behavior deterministic.
- Stage irreversible public wire choices behind later accepted contracts.

### Non-goals

- Implement the contract in this change package.
- Expose arbitrary template keyword arguments.
- Infer capability from model names or manual support claims.
- Define public raw structured reasoning wire shapes.
- Preserve or re-feed typed prior reasoning in conversation history.
- Replace the capture-mode or bounded-retry contracts.

## Decisions

### Use independent canonical axes with provenance

The canonical Request carries `generation_policy` as `model_default`, `disabled`, or `enabled`.
It separately carries `projection` as `legacy_blended`, `final_only`, or `reasoning_structured`.
It also carries source provenance and a pinned effective contract.
The outer fields are the sole authority for generation and projection.
The effective contract is discriminated: omitted requests carry only `mode = legacy`, while negotiated requests carry `mode = negotiated` plus non-empty exact artifact, template, render, parser, runtime, and event-binding identity.

The axes are independent because generation and disclosure answer different questions.
For example, a request may enable reasoning generation while selecting only final answer text for public output.
The Controller must not infer either axis from the other.

When a public request omits reasoning control, Orchard normalizes it to `model_default + legacy_blended` with omitted-public provenance.
That request stays on the complete legacy path even when every component advertises a newer reasoning capability.
The synthesized defaults and legacy mode marker remain outside the omitted request's existing `body_hash` domain.

The first-release combination matrix is closed.
Omitted public requests use only `model_default + legacy_blended`, Console defaults use only `disabled + final_only`, and accepted explicit controls may combine `model_default`, `disabled`, or `enabled` only with `final_only`.
Structured reasoning stays unavailable until its separate contract expands the matrix.

### Pin exact capability identity before dispatch

The effective negotiated contract pins exact `model_artifact_digest`, exact `chat_template_digest`, `render_contract`, `render_contract_version`, `parser_family`, `parser_version`, `runtime_contract_version`, and `event_binding_version`.
The Controller owns this typed contract and pins it for every attempt of the logical Request.

The tokenizer maps the typed generation policy through a closed mapping for the exact artifact and template.
It returns the effective render and parser metadata needed to prove the contract.
The public API cannot pass arbitrary template keyword arguments.

Runtime capability is distinct from manual model-qualification governance.
Manual support evidence can constrain a support claim, but it is not a manifest field, scheduling fact, or dispatch permit.
Likewise, runtime capability does not approve a manual support claim.

Capability evidence advertises complete supported tuples, not independent value lists whose Cartesian product could authorize an untested combination.
Candidate-time observations select a possible endpoint.
The loaded Worker Runtime then returns an authoritative pre-execution acceptance proof that echoes the tuple and its worker incarnation before model invocation.

### Parse negotiated output before tools and stops

For an explicitly negotiated mode, the Worker Runtime applies the pinned stateful parser to the ordered decoded stream before tool-call classification and caller stop-sequence matching.
Only final-answer text enters tool-call parsing.
Caller stop sequences apply only to final-answer text.
Existing protection against truncating tool-call JSON remains in force after tool emission begins.

Parser framing markers are not content.
Malformed, ambiguous, or incomplete parser state fails closed for explicit `final_only` or `reasoning_structured` requests.
The failure cannot fall back to raw blended output, expose ambiguous bytes in an error, or reclassify them as final text or tool content.

Ambiguity is a property of the streaming seam, not of the bytes themselves, so the terminal decides what the seam could not.
A trailing partial-marker prefix retained by the shared chunk-boundary seam is ambiguous only while further decoded output can still arrive.
At the non-truncating `completed` and `stop` terminals the provider has proved that no further output exists, so the retained prefix was never a framing marker.
Under those terminals the parser is definitively in FINAL when no reasoning frame is open, either because its frame closed or because tagged-pair framing never opened one, and the retained prefix is then ordinary final-answer text.
An actually open or incomplete reasoning frame still fails closed: an opened and unclosed frame fails with `parser_unclosed_marker`, and a prefix retained at the truncating `length` terminal fails with `parser_incomplete_marker`.
This is neither a strictness or projection axis nor a legacy-blended exception; it is one closed rule applied to every negotiated request.

Tagged-pair text that precedes any open marker is likewise unclassified until a complete reasoning frame or the terminal resolves it, so the parser withholds that text instead of streaming it.
A later framing violation discards the withheld text rather than exposing it as final text or tool input, which makes the classification independent of how the provider happened to chunk the stream.

A preempting `cancelled`, `deadline`, or `timed_out` terminal wins outright.
The parser reports only that terminal, discards every still-unclassified byte including the tagged-pair pre-open buffer, and neither synthesizes a conformance failure nor flushes partial text.

The parser also enforces generation policy.
Any reasoning frame or content under `disabled`, and terminal completion without valid non-empty reasoning under `enabled`, fails with the same deterministic terminal-conformance boundary.
Whitespace-only decoded reasoning is framing rather than valid content, so an empty or whitespace-only frame does not satisfy `enabled`.
The no-selected-output guarantee binds the parser terminal rather than only the later projection boundary, so the parser withholds final-answer text while the negotiated policy is still unsatisfied and a policy-conformance terminal releases nothing.
Under `enabled` that means a stream which never produces valid reasoning emits no final-answer delta before it fails, for both the tagged-pair and prompt-opened families; once valid reasoning is observed, ordinary final text streams normally after the close transition.
`model_default` permits either presence or absence.

The current raw `TokenDelta` has no projection channel.
Negotiated modes therefore reject token-ID and logprob opt-ins before dispatch until a separately accepted channel-aware token-event contract exists.

The omitted legacy path retains its current ordering and byte behavior.
Unknown or unqualified output on that path remains raw blended text.

### Make commitment follow the selected public projection

Output Commitment occurs on the first validated non-empty delta selected for the logical public response.
A selected public reasoning delta under `reasoning_structured` commits before downstream delivery.
Hidden reasoning under `final_only` does not commit.
Final text, tool calls, and future structured output keep their existing commitment semantics.

This rule prevents an invisible internal token from blocking a safe retry while also preventing regeneration after selected public reasoning has become observable.
Commitment remains transport-independent and is recorded before a handler or serializer is called.

### Account exact generated output without inferring reasoning usage

The selected terminal attempt reports total generated output tokens with `output_usage_status = exact` or `lower_bound`.
Worker-originated terminals are exact.
Controller-synthesized terminals use a validated lower bound when the exact total cannot be proved.
An exact reasoning-token subset is additive when the Worker Runtime can prove it.
Unavailable or unproven reasoning usage stays unknown and is never normalized to zero.

A lower bound remains durable non-content evidence for quota reconciliation, metrics, and audit and is never serialized through a public field that implies an exact value.
The reasoning subset remains internal until presence-aware Runtime Endpoint and public usage contracts preserve exact zero versus unknown.
Orchard does not estimate reasoning tokens by retokenizing decoded text or by subtraction.

### Stage the public API contract

The first public behavior supports explicit final-only semantics for both Chat Completions and Responses after a concrete request-field contract is separately accepted.
This package defines the semantics but intentionally does not invent the public request field names.
No ad hoc input field may ship before that gate is accepted.

Chat Completions raw structured reasoning remains unsupported.
Responses structured reasoning remains disabled until a later accepted contract defines item and event names, raw-versus-summary semantics, sync and streaming shapes, ordering, terminal behavior, capture, and replay.

Ordinary assistant input remains opaque caller-authored content.
Explicit typed prior reasoning is rejected in the first release.

### Give the Console stricter operator-facing defaults

The Console Playground defaults to `disabled + final_only` with Console-default provenance.
An explicit enable action requires exact contract proof and fails before dispatch when unsupported.
The Console never falls back from an unsupported explicit control to model default, legacy blended output, or heuristic stripping.

The transcript stores reasoning and final answer channels separately while rendering the selected operator view.
Only final-answer content is re-fed as later assistant history.
Issue #189 remains a display-only fallback for legacy blended output and has no policy, parser, capture, replay, or history authority.

### Make hidden reasoning ephemeral under every capture mode

Reasoning hidden by `final_only` is discarded at the Worker contract boundary after accounting.
It cannot enter public payloads or events, request or response payloads, request events, previews, logs, traces, metrics, audit payloads, crash evidence, or diagnostics.
This applies under `none`, `metadata`, and `full`.

If a later accepted contract enables selected public structured reasoning, only `full` may retain that content as part of the exact assembled public response needed for replay.
`response_hash` covers the exact assembled public projection rather than hidden content or SSE framing.
Negotiated previews use final-answer text only.
Legacy blended previews continue to use the existing undifferentiated public assistant text without parsing.
Historical rows are replayed as retained and are never reclassified by a later parser.

### Pin retry and mixed-version behavior

Automatic attempt 2 and operator retry preserve the exact artifact, template, render, parser, generation, projection, provenance, runtime, and event-binding identity for negotiated requests.
Retry chooses a different endpoint that proves the same complete contract or is declined before dispatch.
An omitted legacy request remains `mode = legacy` on every attempt and retains existing legacy retry semantics without fabricated nullable identity.

Protocol evolution is additive within the existing `N` and `N-1` window.
Without a complete negotiated contract, endpoints exchange only legacy requests and legacy events.
A Controller never sends a new request field to an older or non-advertising binding, and a Node Agent never emits a new event to such a binding.
An explicit request is never silently downgraded during a rolling upgrade.

## Compatibility matrix

| Request mode | Capability evidence | Runtime path | Public output | Failure behavior |
| --- | --- | --- | --- | --- |
| Omitted public control | Any supported legacy endpoint | Complete legacy pipeline | Existing blended output | Existing legacy behavior |
| Explicit `final_only` | Exact complete contract | Negotiated parser pipeline | Final answer and existing tool output only | Fail before dispatch or fail closed during parsing |
| Explicit `reasoning_structured` on Chat | Any | None | Unsupported | Reject during request validation |
| Explicit `reasoning_structured` on Responses before later contract | Any | None | Disabled | Reject during request validation |
| Explicit negotiated mode with missing or incompatible evidence | Missing, stale, malformed, false, or incompatible | None | None | Fail before dispatch |

## Failure and security implications

Reasoning delimiters and reasoning text are untrusted model output.
Parser failures therefore use stable bounded error categories and never copy ambiguous content into error messages or diagnostics.
The exact capability gate prevents a parser or template mismatch from becoming silent content disclosure.
Projection-based capture prevents `full` from becoming permission to retain hidden reasoning.
Closed metrics and usage fields prevent raw model output, parser fragments, or high-cardinality contract identifiers from becoming telemetry labels.

The public failure mapping is closed.
An exact artifact or template that cannot honor an accepted control returns `400 invalid_request_error` with `unsupported_reasoning_control` before a Request write.
No compatible endpoint or a mismatched pre-execution acceptance proof returns `503 server_error` with `runtime_incompatible` and is non-retryable.
Post-execution parser or generation-policy conformance returns `500 api_error` with `internal_error` and durable `terminal_conformance` evidence.

## Staged delivery and irreversible gates

1. Land and review this normative `SPEC.md` and OpenSpec contract without product code.
2. Archive `enforce-inference-capture-modes` before archiving this dependent change.
3. Implement canonical policy, exact render metadata, and capability representation without exposing new public wire fields.
4. Implement provider-neutral protocol negotiation, parser ordering, failure handling, usage, and retry pinning behind compatibility gates.
5. Implement Console defaults and separate transcript channels without replacing issue #189's legacy-only fallback until the negotiated path is proven.
6. Accept concrete public final-only input fields before enabling the feature on either public endpoint.
7. Accept a separate Responses structured reasoning contract before defining or emitting any public structured reasoning item or event.

Public field names, event names, protobuf field numbers, manifest encoding, raw-versus-summary semantics, and replay shapes are irreversible compatibility choices.
They remain blocked until their dedicated contract and mixed-version tests are accepted.

## Rejected alternatives

### Change the omitted default when a model is capable

This was rejected because capability discovery must not silently alter established public output, tool behavior, stop behavior, capture, or replay.

### Expose arbitrary template keyword arguments

This was rejected because it delegates product semantics to model-specific templates and prevents exact compatibility, validation, and retry identity.

### Strip delimiters in the Console or Controller after generation

This was rejected because display heuristics cannot safely classify chunked output, tool calls, stops, usage, capture, retries, or history.

### Treat hidden reasoning as committed output

This was rejected because an invisible internal delta should not block a safe retry when no selected public output has been observed.

### Fall back to raw output when explicit parsing fails

This was rejected because the fallback would disclose content the caller explicitly excluded and would make parser conformance non-deterministic.

### Couple runtime support to manual model qualification

This was rejected because repository-owned support claims and live product capability answer different questions and have different authority boundaries.

### Freeze structured reasoning wire names now

This was rejected because raw-versus-summary semantics, item and event ordering, terminal behavior, capture, and replay are not yet accepted.
