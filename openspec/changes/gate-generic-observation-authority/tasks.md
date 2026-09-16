# Tasks: gate generic observation authority

## 1. Contract

- [x] 1.1 Clarify denied generic-status invalidation in `SPEC.md` §5.4.
- [x] 1.2 Add the scoped Runtime Endpoint OpenSpec delta.

## 2. Implementation and tests

- [x] 2.1 Gate generic status and candidate-only observation with the lifecycle write gate.
- [x] 2.2 Keep denied candidate-only observation queue-inert.
- [x] 2.3 Clear only safely resolved, freshness-qualified original-target sources with no promotion.
- [x] 2.4 Add direct durable-state and denial-cleanup regression tests.

## 3. Validation

- [x] 3.1 Run strict scoped and repository-wide OpenSpec validation.
- [x] 3.2 Run the required Elixir quality workflow.
