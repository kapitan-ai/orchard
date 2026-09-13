# Tasks

## 1. Accept the public contract

- [x] 1.1 Amend `SPEC.md` with the identical Chat Completions and Responses `reasoning` object and its canonical mapping.
- [x] 1.2 Define invalid-value, contradictory-control, exact-capability, runtime-proof, and terminal-conformance error boundaries with concrete public `param` paths.
- [x] 1.3 Preserve omitted bytes, serialization, `body_hash`, idempotency, legacy behavior, and first-release output boundaries.
- [x] 1.4 Record #326-#329 implementation and applicable PR #421 deployment-attestation gates without duplicating PRs #425, #431, or #434.

## 2. Validate the contract

- [x] 2.1 Run strict validation for `define-public-reasoning-controls`.
- [x] 2.2 Run strict validation for every OpenSpec change and review the package for placeholder prose.
- [x] 2.3 Run applicable documentation and specification checks and independent contract review.
- [ ] 2.4 After dependency-ordered archive or sync, rerun strict all-spec validation and review generated main specs for placeholder prose.

## 3. Implement and activate in owned follow-on work

- [ ] 3.1 Complete and merge issue #326 canonical normalization and exact rendering without changing omitted-request behavior.
- [ ] 3.2 Complete and merge issue #327 negotiated runtime encoding and exact loaded-proof implementation.
- [ ] 3.3 Complete and merge issue #328 parser and final-only projection implementation.
- [ ] 3.4 Complete and merge issue #329 usage, retry, capture, and replay implementation; before its classified writers activate, explicitly attest that PR #421's compatible readers are deployed to every Controller and background reader.
- [ ] 3.5 Implement the accepted public field consistently in Chat Completions and Responses only after tasks 3.1-3.4 are satisfied.
- [ ] 3.6 Keep Console #330, structured reasoning items and events, public reasoning-token usage, production registrations, and model-specific mappings outside this change.
