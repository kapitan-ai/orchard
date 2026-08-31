## ADDED Requirements

### Requirement: Runtime Endpoint reasoning capability is exact and negotiated

Runtime Endpoint reasoning capability SHALL enumerate complete supported tuples containing generation policy, projection, exact model artifact and chat-template contracts, render contract and version, parser family and version, runtime contract version, and event-binding version.
Separate value lists whose Cartesian product could authorize a tuple that was not explicitly advertised SHALL be invalid.
Candidate-time observations SHALL be advisory selection evidence only.
The Controller SHALL select an endpoint for an explicit `final_only` or `reasoning_structured` Request only when a fresh observation proves the exact pinned tuple.
Missing, stale, false, malformed, unknown, or incompatible evidence MUST NOT prove support.
Runtime capability SHALL remain independent of manual model-qualification and support-claim governance.
This requirement refines `SPEC.md` sections 4.6.1, 6.4, and 7.5.3a.

#### Scenario: Endpoint advertises only a different parser version

- **WHEN** the selected endpoint advertises reasoning support but not the pinned parser family and version
- **THEN** the endpoint is incompatible with the explicit Request
- **AND** Orchard does not dispatch the Request to that endpoint

#### Scenario: Capability evidence is absent

- **WHEN** a Runtime Endpoint omits reasoning capability evidence
- **THEN** it remains eligible for supported legacy requests
- **AND** it cannot receive an explicitly negotiated reasoning Request

#### Scenario: Separate capability lists imply an unadvertised combination

- **WHEN** an endpoint advertises separate values that could be combined into a tuple it did not explicitly support
- **THEN** Orchard treats that implied tuple as unsupported
- **AND** it does not use the Cartesian product as dispatch authority

### Requirement: Loaded Worker Runtime proves the tuple before execution

For each negotiated dispatch, the loaded Worker Runtime SHALL validate the requested complete tuple and produce an authoritative execution-acceptance proof before model invocation.
The proof SHALL echo the complete tuple and identify the loaded worker incarnation that will execute the Request.
The Node Agent and Worker Runtime MUST NOT invoke the model or emit content or usage before the proof is produced.
The Controller SHALL validate the proof before accepting the attempt as running or forwarding later events.
Missing, malformed, stale, or mismatched proof SHALL fail with `503 server_error` and `runtime_incompatible` before model invocation.
If an attempt already exists, its durable evidence SHALL use `pre_acceptance_unavailable + runtime_incompatible` with `retry_decision = not_retryable`.
The Controller-detected acceptance failure MUST NOT trigger Automatic Attempt Retry, and an arbitrary Worker or Runtime Endpoint `Failed` event with code `runtime_incompatible` SHALL remain insufficient to authorize retry.
Concrete protocol fields remain blocked until the additive Runtime Endpoint encoding and `N`/`N-1` contract is separately accepted.
This requirement refines `SPEC.md` sections 5.8, 7.5.3a, and 13.1.

#### Scenario: Worker restarts after candidate observation

- **WHEN** the observed compatible Worker Runtime is replaced before execution acceptance
- **THEN** the replacement must prove the same complete tuple and its own incarnation before model invocation
- **AND** a missing or mismatched proof fails as `runtime_incompatible` without exposing output

#### Scenario: Acceptance mismatch is non-retryable

- **WHEN** a negotiated attempt receives a mismatched acceptance proof before model invocation
- **THEN** the attempt records `pre_acceptance_unavailable + runtime_incompatible`
- **AND** it records `retry_decision = not_retryable` and does not trigger Automatic Attempt Retry

### Requirement: Runtime Endpoint reasoning events obey negotiated bindings

An endpoint without a complete negotiated reasoning contract SHALL receive and emit only legacy request and event variants.
A typed internal reasoning delta MAY cross the Runtime Endpoint boundary only for `projection = reasoning_structured` when the complete contract and compatible event binding were negotiated before execution.
The Controller MUST NOT send a new request field to an older or non-advertising binding, and an endpoint MUST NOT emit a new reasoning event to such a binding.
This requirement refines `SPEC.md` sections 7.5.3a and 13.1.

#### Scenario: New Node Agent serves an older Controller

- **WHEN** a newer Node Agent communicates with an older Controller in the supported version window
- **THEN** the Node Agent does not infer a reasoning mode
- **AND** it emits only event variants the Controller advertised

#### Scenario: Explicit mode has no compatible endpoint

- **WHEN** no eligible endpoint proves the exact pinned contract and compatible event binding
- **THEN** Orchard fails the explicit Request before dispatch with `503 server_error` and `runtime_incompatible`
- **AND** it does not silently downgrade the projection or widen capture

### Requirement: Raw token events remain legacy-only until channel-aware

An explicit negotiated reasoning Request SHALL reject `return_token_ids = true` or `return_logprobs = true` before dispatch because the current `TokenDelta` event has no projection channel and can expose reconstructable hidden or framing tokens.
Omitted `model_default + legacy_blended` requests SHALL preserve the existing opt-in TokenDelta behavior.
Negotiated token-ID or logprob emission MUST NOT be enabled until a separately accepted channel-aware token-event contract defines projection, capture, and mixed-version behavior.
This requirement refines `SPEC.md` section 7.5.3.

#### Scenario: Final-only request opts into token IDs

- **WHEN** an explicit negotiated final-only Request sets `return_token_ids = true`
- **THEN** Orchard rejects the Request before dispatch
- **AND** no reconstructable hidden or framing tokens cross the Runtime Endpoint boundary

## MODIFIED Requirements

### Requirement: Validated Runtime Endpoint output controls commitment

The Controller SHALL evaluate Output Commitment only after a Runtime Endpoint event passes protocol validation and before the event reaches a public handler or serializer.
Output Commitment SHALL occur on the first validated non-empty delta selected for the logical public response.
A non-empty reasoning delta SHALL commit only for `projection = reasoning_structured` and SHALL record commitment kind `reasoning`.
Hidden reasoning under `projection = final_only` MUST NOT commit output.
A non-empty selected text delta, a valid tool-call delta with stable non-empty identity, or a future content-bearing structured-output delta SHALL keep its existing commitment behavior.
When commitment occurs, the Controller SHALL deliver all earlier buffered validated events in original order before exposing the committing event.
Accepted, progress, usage, model-load, empty, hidden-reasoning, and terminal events SHALL NOT commit output.
This requirement refines `SPEC.md` sections 3.6, 3.7.1, 5.8, and 5.9 and preserves `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Selected reasoning commits before delivery

- **WHEN** a negotiated `reasoning_structured` Request emits its first validated non-empty reasoning delta
- **THEN** the Controller records Output Commitment with kind `reasoning` before downstream delivery
- **AND** a later attempt failure does not trigger Automatic Attempt Retry

#### Scenario: Hidden reasoning does not commit

- **WHEN** a negotiated `final_only` Request emits hidden reasoning but no selected final text or tool output before an eligible transient failure
- **THEN** Output Commitment remains false
- **AND** the retry decision continues through the remaining gates

#### Scenario: Valid tool-call identity commits before delivery

- **WHEN** the Runtime Endpoint emits a valid selected tool-call delta with a stable identity
- **THEN** the Controller records tool-call Output Commitment before downstream delivery
- **AND** it delivers earlier buffered validated events in original order before the committing event
- **AND** a later transport or handler failure does not retry

#### Scenario: Malformed output does not become safe retry input

- **WHEN** a Runtime Endpoint output event fails protocol validation
- **THEN** Orchard does not treat it as valid committed output
- **AND** the protocol-conformance failure remains non-retryable
