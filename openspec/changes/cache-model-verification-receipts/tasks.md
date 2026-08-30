## 1. Contract

- [x] 1.1 Reconcile `SPEC.md` §6.7 with authoritative first/full verification and receipt-only acceleration.
- [x] 1.2 Record receipt binding, invalidation, crash ordering, force-full behavior, logs, and threat boundaries.

## 2. Test-Driven Implementation

- [x] 2.1 Characterize the repeated full hash through the public acquisition seam, then require the second unchanged load to skip it.
- [x] 2.2 Cover same-size tampering, truncation, forced verification, path-safe logs, and receipt invalidation.
- [x] 2.3 Persist receipts atomically outside Artifact Bundles and retain the existing Catalog digest algorithm unchanged.

## 3. Operator Route

- [x] 3.1 Add and document `ORCHARD_FORCE_FULL_MODEL_VERIFICATION` for source-development and packaged Node Agent configuration.

## 4. Validation And Review

- [x] 4.1 Run focused acquisition, adjacent source-adapter, ModelManager, and Artifact Bundle tests.
- [x] 4.2 Run the complete Orchard Elixir format, compile, Credo, Dialyzer, test, and coverage workflow.
- [x] 4.3 Run strict OpenSpec validation and obtain independent contract and diff review.
