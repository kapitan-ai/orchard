# Tasks

## 1. Accept the public contract

- [x] 1.1 Amend `SPEC.md` with the explicit `reasoning.enabled` final-only selector on Chat Completions and Responses and its canonical mapping, layered on `request-local-reasoning-effort` (#491) without changing its fields or effort-only semantics.
- [x] 1.2 Define the validation order and the invalid-value, unsupported-field, contradictory-control, exact-capability, runtime-proof, and terminal-conformance boundaries with concrete public `param` paths, including Chat `reasoning_effort` and Responses `reasoning.*`.
- [x] 1.3 Preserve omitted and effort-only bytes, serialization, `body_hash`, idempotency, legacy behavior, and first-release output boundaries.
- [x] 1.4 Record #326-#329 implementation and applicable PR #421 deployment-attestation gates without duplicating PRs #425, #431, #434, or #491.

## 2. Validate the contract

- [x] 2.1 Run strict validation for `define-public-reasoning-controls`.
- [x] 2.2 Run strict validation for every OpenSpec change and review the package for placeholder prose.
- [ ] 2.3 Run applicable documentation and specification checks and independent contract review of the reconciled selector design.
- [ ] 2.4 After dependency-ordered archive or sync, rerun strict all-spec validation and review generated main specs for placeholder prose and for deferral prose this change has now satisfied. This includes `define-qualified-reasoning-effort`'s deferred-public-field-name sentence, the `define-reasoning-output-contract` 6.1 and `define-qualified-reasoning-effort` 4.2 tracking items, and the "negotiated final-only parsing remains separate" note in `request-local-reasoning-effort`. Reconcile each in its owning package rather than here.
- [ ] 2.5 Product owner accepts the selector design: the `enabled` name rather than a named projection selector, the Chat top-level `reasoning` object containing only `enabled`, final-only effort limited to the closed negotiated vocabulary with other well-formed identifiers rejected as `unsupported_reasoning_control`, and unrecognized members keeping main's `unsupported_parameter` with `reasoning.<member>` instead of the earlier echo-free `reasoning` path.

## 3. Implement and activate in owned follow-on work

- [ ] 3.1 Complete and merge issue #326 canonical normalization and exact rendering without changing omitted or effort-only request behavior. Accept Responses `reasoning.enabled` and the Chat top-level `reasoning` object only at activation. Narrow the shared `validate_reasoning_combination!/5` so `explicit_public + model_default` is rejected, and add shared canonical-request regression coverage for that combination.
- [ ] 3.2 Complete and merge issue #327 negotiated runtime encoding and exact loaded-proof implementation.
- [ ] 3.3 Complete and merge issue #328 parser and final-only projection implementation.
- [ ] 3.4 Complete and merge issue #329 usage, retry, capture, and replay implementation. Before its classified writers activate, explicitly attest that PR #421's compatible readers are deployed to every Controller and background reader.
- [ ] 3.5 Implement the accepted selector consistently in Chat Completions and Responses only after tasks 3.1-3.4 are satisfied, with regression tests proving that omitted and effort-only requests keep their current outcomes.
- [ ] 3.6 Keep Console #330, structured reasoning items and events, public reasoning-token usage, final-only discovery metadata, production registrations, and model-specific mappings outside this change.
