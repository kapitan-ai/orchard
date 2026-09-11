# Tasks

## 1. Finalize the contract

- [x] 1.1 Reconcile the issue #190 workshop decisions into `SPEC.md` and this single cross-capability OpenSpec package.
- [x] 1.2 Run targeted strict OpenSpec validation and resolve every structural finding.
- [x] 1.3 Complete independent product, API, runtime, retry, capture, and mixed-version review.
- [x] 1.4 Record the accepted decision readback and stage implementation child issues only after contract review and validation pass.
- [ ] 1.5 Before archiving this change, confirm `enforce-inference-capture-modes` has been archived into the main `inference-capture` capability.

## 2. Implement canonical policy and rendering

- [x] 2.1 Add canonical generation policy, projection, provenance, and exact effective-contract types without changing omitted-request behavior.
- [x] 2.2 Add a closed tokenizer mapping infrastructure for supported exact model artifact and chat-template contracts. The production registry is intentionally empty until an exact qualified tuple is accepted; synthetic exact-identity fixtures cover the fail-closed contract.
- [x] 2.3 Return and validate exact model artifact, chat-template, render contract, parser, runtime contract, and event-binding metadata before dispatch.
- [x] 2.4 Reject arbitrary template keyword arguments and unsupported explicit controls before scheduling or dispatch.

## 3. Implement negotiated runtime contracts

- [ ] 3.1 Define additive Runtime Endpoint and Worker Runtime capability fields for complete supported tuples, loaded-worker incarnation, pre-execution acceptance proof, terminal usage completeness, and exact optional reasoning usage only after their concrete encoding and version-skew contract is accepted.
- [ ] 3.2 Add legacy-only fallback for absent, stale, malformed, false, unknown, or incompatible reasoning capability evidence.
- [ ] 3.3 Pin the exact reasoning contract across dispatch, terminal evidence, and both automatic and operator retry.
- [ ] 3.4 Add `N` and `N-1` compatibility fixtures proving no new field or event reaches an older or non-advertising binding.
- [ ] 3.5 Reject raw TokenDelta token-ID and logprob opt-ins for negotiated modes until a channel-aware token-event contract is accepted.

## 4. Implement parser, projection, commitment, and usage

- [ ] 4.1 Add provider-neutral stateful parser conformance fixtures for ordered decoded streams, chunk boundaries, malformed state, tool calls, and caller stops.
- [ ] 4.2 Classify negotiated streams before tool-call parsing and stop matching while preserving the complete omitted legacy pipeline.
- [ ] 4.3 Fail explicit final-only and structured modes closed without raw fallback or ambiguous-content leakage, including disabled-generation reasoning and enabled-generation absence.
- [ ] 4.4 Add projection-selected Output Commitment for reasoning, final text, tool calls, and structured output.
- [ ] 4.5 Add `exact | lower_bound` total output usage, optional exact reasoning subset, unknown-versus-zero handling, and durable Controller-synthesized lower-bound terminal usage.

## 5. Implement capture and history boundaries

- [ ] 5.1 Enforce hidden-reasoning disposal before public, persistence, logging, tracing, metrics, crash, and diagnostic boundaries under every capture mode.
- [ ] 5.2 Hash and replay only the exact assembled public projection and prohibit historical reclassification.
- [ ] 5.3 Keep Console transcript reasoning separate and re-feed final-answer content only.
- [ ] 5.4 Preserve issue #189 as a display-only fallback for legacy blended output.

## 6. Accept and implement public final-only controls

- [ ] 6.1 Accept a separate API contract for the concrete Chat Completions and Responses request field names before exposing either field.
- [ ] 6.2 Implement explicit final-only sync and streaming behavior after task 6.1 is accepted.
- [ ] 6.3 Reject Chat raw structured reasoning and explicit structured prior-reasoning input.
- [ ] 6.4 Preserve the closed `unsupported_reasoning_control`, `runtime_incompatible`, and `internal_error` mappings when concrete public fields are accepted.

## 7. Defer Responses structured reasoning

- [ ] 7.1 Accept a later contract for Responses item and event names, raw-versus-summary semantics, sync shape, stream ordering, terminal behavior, capture, and replay.
- [ ] 7.2 Do not implement or advertise public Responses structured reasoning until task 7.1 is accepted.

## 8. Validate implementation children

- [ ] 8.1 Run strict validation for this change after every accepted contract amendment.
- [ ] 8.2 Run the applicable `AGENTS.md` quality and coverage workflow for each implementation child.
- [ ] 8.3 Run adjacent Chat Completions, Responses, Console, retry, capture, and provider-neutral conformance suites for every changed public seam.
- [ ] 8.4 After archive or sync, validate all OpenSpec packages strictly and remove generated placeholder prose such as `Purpose TBD`.
