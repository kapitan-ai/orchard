## 1. Contract

- [x] 1.1 Reconcile SPEC.md §§3.5 and 6.4 and ADR 0045 with the delivered boundary.
- [x] 1.2 Validate this change and all OpenSpec materials strictly.

## 2. Implementation and verification

- [x] 2.1 Scrub the request-time environment and use an empty private cwd.
- [x] 2.2 Preserve cwd through the uv fallback and inventory other render sites.
- [x] 2.3 Prove secret/cwd regressions fail before and pass after on Linux and Darwin.
- [x] 2.4 Run full Elixir and tokenizer native workflows and pinned template smoke.

## 3. Handoff

- [x] 3.1 Publish the branch and PR with exact-head evidence; request independent review and product-owner approval before merge.
