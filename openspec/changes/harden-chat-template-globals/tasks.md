## 1. Contract

- [x] 1.1 State the narrow renderer restriction in SPEC.md §3.5 without changing template trust or Python policy.
- [x] 1.2 Validate the OpenSpec change with strict validation.

## 2. Implementation and verification

- [x] 2.1 Limit the dictionary global and validate namespace construction and assignment.
- [x] 2.2 Confirm each new restriction's regression fails on the unchanged renderer.
- [x] 2.3 Verify legitimate operations, marker preservation, and qualified real-template render parity.
- [x] 2.4 Run tokenizer Ruff formatting/lint, pytest, and coverage.
