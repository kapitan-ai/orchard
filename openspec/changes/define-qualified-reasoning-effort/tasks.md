# Tasks

## 1. Finalize the contract

- [x] 1.1 State the `SPEC.md` impact and preserve PR #325's independent generation-policy and projection axes.
- [x] 1.2 Define the closed `reasoning_effort = nil | low | medium | high` axis and reject supplied effort unless generation policy is `enabled`.
- [x] 1.3 Keep public field names, renderer implementation, Runtime Endpoint encoding, and product behavior deferred to their established child issues.
- [x] 1.4 Run targeted strict OpenSpec validation and resolve every structural finding.
- [ ] 1.5 Run applicable documentation and contract validation and complete independent review before acceptance.

## 2. Implement canonical normalization and rendering

- [ ] 2.1 In issue #326, add canonical effort normalization without changing omitted-request bytes, hashes, serialization, or generation-policy semantics.
- [ ] 2.2 In issue #326, implement closed artifact/template renderer mappings and reject arbitrary provider-value or template-keyword input.
- [ ] 2.3 Add static fixtures for the exact Qwen3.8 template mapping `low`, `medium`, and `xhigh` from canonical `low`, `medium`, and `high`, plus missing, unknown, contradictory, and incompatible mapping evidence.

## 3. Implement negotiation and projection

- [ ] 3.1 In issue #327, accept a concrete wire encoding for complete selected-effort tuples and loaded-worker acceptance proof before dispatch.
- [ ] 3.2 In issue #327, add `N` and `N-1` fixtures that keep selected effort and new variants off older or non-advertising bindings.
- [ ] 3.3 In issue #328, prove provider-neutral parser and final-only conformance for each qualified tier without changing the omitted legacy pipeline.

## 4. Implement retention, retry, and public controls

- [ ] 4.1 In issue #329, pin effort across automatic and operator retry and prove every capture, usage, hashing, idempotency, and replay boundary preserves hidden-reasoning protections for each tier.
- [ ] 4.2 In issue #331, accept concrete consistent Chat Completions and Responses fields, validation, and error envelopes before exposing effort publicly, setting `param` to the concrete offending accepted public field for both `unsupported_reasoning_control` rows.
- [ ] 4.3 Keep the Console without an effort selector and at `reasoning_effort = nil` until a later accepted Console contract gates operator tier selection behind `enabled + final_only` and exact-tuple proof.
- [ ] 4.4 Do not expose raw structured reasoning, typed prior-reasoning history, server-side tool execution, or a support/default-model claim as part of this work.

## 5. Qualify any offered tier

- [ ] 5.1 Record static mapping, runtime conformance, and semantic tier evidence separately for each exact qualification tuple.
- [ ] 5.2 Prove valid non-empty reasoning content across each claimed tier envelope, and record a tier that cannot as `unsupported` for that exact tuple rather than offering it.
- [ ] 5.3 Require an approved scoped support claim before representing a tier as offered; preserve unsupported and unknown results rather than generalizing the Qwen3.8 fixture.
