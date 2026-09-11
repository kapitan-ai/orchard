## 1. Contract

- [x] 1.1 Update `SPEC.md` and the Model Manifest schema with revision-bound tool-admission evidence and explicit repair-import behavior.
- [x] 1.2 Validate this OpenSpec change strictly before implementation.

## 2. Artifact and catalog admission

- [x] 2.1 Add tokenizer-only preflight for recognized parser plus synthetic definition and structured-history rendering.
- [x] 2.2 Generate fail-closed evidence and Catalog capabilities in BundleBuilder without model-name heuristics.
- [x] 2.3 Preserve sidecar provenance in the Artifact Bundle and Catalog through normal import, keep the worker manifest N-1 compatible, and keep duplicate identities immutable.
- [x] 2.4 Coordinate concurrent Artifact Bundle publication through Postgres and reject staged identity changes.
- [x] 2.5 Retain the server-owned repair Catalog version through retry, restart, and remount.

## 3. Request safety

- [x] 3.1 Reject malformed inline function-schema shapes in shared Chat and Responses validation before dispatch.
- [x] 3.2 Cover safe structured tool-history rendering and negative argument cases at the tokenizer boundary.

## 4. Validation and handoff

Validation checkmarks record completed workflows, not certification of later
commits. The follow-up PR must bind fresh validation results to its exact
published head after integration with main.

- [x] 4.1 Run focused Elixir and native tests, strict OpenSpec validation, and the full applicable Orchard quality workflow.
- [ ] 4.2 Complete required CI and human review for the follow-up PR before merging.
- [x] 4.3 Repeat the full applicable Elixir quality workflow for publication coordination and repair-version retention.
