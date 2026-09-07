## 1. Contract and reproduction

- [x] 1.1 Reproduce raw wrapper emission at the smallest worker boundary with a failing regression using the pinned JSON parser semantics.
- [x] 1.2 Reconcile SPEC.md with parsed-call publication and incomplete-call behavior; verify strict OpenSpec validation.

## 2. Worker correctness

- [x] 2.1 Publish only validated parser results and verify correct arguments, ordered multi-call results, stable identity, and requested names in worker tests.
- [x] 2.2 Preserve cancellation and truncation failure behavior without unvalidated calls; verify deterministic and generation-level regression tests.
- [x] 2.3 Exercise the actual pinned MLX-LM parser and real-model tool generation with the existing pinned runtime.
- [x] 2.4 Normalize tool history arguments for mapping-based chat templates and cover recursive caller-string protection, invalid input, and dual-render failures with tokenizer regressions.

## 3. Qualification and handoff

- [x] 3.1 Add reusable qualification coverage and model prerequisites; verify a real OpenCode Chat Completions tool-result round trip with exact model/runtime/client identities.
- [x] 3.2 Run the native package formatting, lint, tests, and coverage workflow and any additional affected quality gates; report actual results.
- [x] 3.3 Obtain independent review, resolve findings, and verify the final diff and strict OpenSpec validation.
- [ ] 3.4 When the accepted change is archived or synced, inspect generated main specs for placeholder prose and run strict all-spec validation.
