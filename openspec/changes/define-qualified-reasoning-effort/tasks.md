# Tasks

## 1. Finalize the contract

- [x] 1.1 State the `SPEC.md` impact and preserve PR #325's independent generation-policy and projection axes.
- [x] 1.2 Define the closed `reasoning_effort = nil | low | medium | high` axis and reject supplied effort unless generation policy is `enabled`.
- [x] 1.3 Keep public field names, renderer implementation, Runtime Endpoint encoding, and product behavior deferred to their established child issues.
- [x] 1.4 Run targeted strict OpenSpec validation and resolve every structural finding.
- [x] 1.5 Run applicable documentation and contract validation and complete independent review before acceptance.

## 2. Implement canonical normalization and rendering

- [x] 2.1 In issue #326, add canonical effort normalization without changing omitted-request bytes, hashes, serialization, or generation-policy semantics.
- [x] 2.2 In issue #326, implement closed artifact/template renderer mappings and reject arbitrary provider-value or template-keyword input. The renderer resolves only exact static registrations keyed by artifact digest, template digest, policy, projection, and effort; the production registry stays empty until an exact qualified tuple is accepted.
- [x] 2.3 Add static fixtures for the exact Qwen3.8 template mapping `low`, `medium`, and `xhigh` from canonical `low`, `medium`, and `high`, plus missing, unknown, contradictory, and incompatible mapping evidence. The Qwen3.8 mapping is test-fixture-only evidence; it is not a registration and asserts no support claim.

## 3. Implement negotiation and projection

- [ ] 3.1 In issue #327, extend the accepted live-observation tuple and unary `PrepareInference` proof and authorization encoding with optional selected effort, preserving loaded-only selection and pre-invocation acceptance.
- [ ] 3.2 In issue #327, add `N` and `N-1` fixtures that keep selected effort and new variants off older or non-advertising bindings.
- [ ] 3.3 In issue #328, prove provider-neutral parser and final-only conformance for each qualified tier without changing the omitted legacy pipeline.
- [ ] 3.4 In issues #327 and #328, gate a provider's tier advertisement on the exact renderer mapping plus provider-neutral protocol conformance only, adding no provider-owned semantic record, no manifest semantic assertion, and no read of a repository-owned qualification record.
- [ ] 3.5 In issue #328, keep the fail-closed `500 api_error` and `internal_error` terminal conformance outcome when an advertised tier completes without valid non-empty reasoning content.
- [x] 3.6 In issue #326, fail an unprovable render-metadata result before dispatch through the existing `503 server_error` and `runtime_incompatible` mapping rather than a caller error.

## 4. Implement retention, retry, and public controls

- [ ] 4.1 In issue #329, pin effort across automatic and operator retry and prove every capture, usage, hashing, idempotency, and replay boundary preserves hidden-reasoning protections for each tier.
- [ ] 4.2 In issue #331, accept concrete consistent Chat Completions and Responses fields, validation, and error envelopes before exposing effort publicly, setting `param` to the concrete offending accepted public field for both `unsupported_reasoning_control` rows.
- [ ] 4.3 Keep the Console without an effort selector and at `reasoning_effort = nil` until a later accepted Console contract gates operator tier selection behind `enabled + final_only` and exact-tuple proof.
- [ ] 4.4 Do not expose raw structured reasoning, typed prior-reasoning history, server-side tool execution, or a support/default-model claim as part of this work.

## 5. Qualify any offered tier

- [ ] 5.1 Record static mapping, runtime conformance, and semantic tier evidence separately for each exact qualification tuple.
- [ ] 5.2 Prove valid non-empty reasoning content across each claimed tier envelope, and record a tier that cannot as `unsupported` for that exact tuple rather than offering it; keep that record out of manifest fields, Runtime Endpoint capability, scheduling, and dispatch.
- [ ] 5.3 Require an approved scoped support claim before representing a tier as offered; preserve unsupported and unknown results rather than generalizing the Qwen3.8 fixture.
