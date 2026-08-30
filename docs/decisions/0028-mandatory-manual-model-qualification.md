# ADR: Local model support claims require manual qualification

## Status

Accepted when the pull request that introduces this record and the standing policy merges.

## Context

`SPEC.md` separates Model Catalog state, Tenant publication, Model Placement state, runtime-provider profiles, and acceptance evidence.
It also states that defining or accepting a profile does not declare it supported.

Issue #231 identifies a remaining governance gap.
Orchard can import, activate, publish, load, and produce output from a model without establishing capability-specific conformance or a production operating envelope.
The same model can pass while preloaded and fail when served from cold because request deadlines, routing values, residency, or artifact verification cost differ.

Without a mandatory record, contributors can accidentally turn a narrow smoke result into an unqualified support statement.
Adding product state or automated gates would cross persistence, API, scheduler, manifest, Console, and runtime boundaries that issue #231 explicitly excludes.

## Decision

Adopt mandatory manual governance for Orchard local-model support claims.
An active support claim requires an approved qualification record for the exact model, runtime, artifact, environment, and tested capability tuple.
Repository review and merge authority enforce the policy.
Orchard product state does not.

Qualification results are capability-scoped rather than ordered levels.
Records distinguish artifact and import validation, runtime load, meaningful generation, capability-specific semantic and API conformance, and production qualification.
Untested capabilities remain unknown.

Every measured result states whether cold load was permitted or the placement was preloaded.
The record also captures cold-load time, effective request deadline, request-admission budgets, routing and residency values, and any residency requirement.
Preloaded evidence cannot support a cold-service claim.

Use `approved`, `hold_for_review`, `not_qualified`, `withdrawn`, and `superseded` as record outcomes.
A hold names whether a model defect, Orchard defect, environment deviation, or evidence gap blocks the decision, together with its durable issue and resume condition.

Commit sanitized qualification records under `docs/model-qualification-records/` and support claims under `docs/model-support-claims/`.
Keep raw prompts, responses, credentials, logs, machine paths, identifiers, and transient traces out of Git.
Protected evidence packages remain in a site-local access-controlled store and are referenced by stable identifier and digest.

An Orchard maintainer with repository merge authority approves, withdraws, and supersedes support claims through merged changes.
A qualification reviewer or maintainer may place a record on hold.
When another qualified maintainer is available, the evidence author is not the sole reviewer and approver.

Issue #118 and issue #196 retain pilot model selection, pilot evidence, and pilot-default authority.
Issue #190 retains reasoning-control, parsing, event, API-projection, and persistence authority.

Model qualification cannot promote a Platform, Distribution, Runtime-Provider, or Acceptance Profile to supported status.
An active model support claim requires every applicable profile to have already passed its `SPEC.md` support and acceptance gates.
Evidence on a target-only or experimental profile may be retained, but it cannot authorize an active support claim.

Any machine enforcement, persisted qualification state, API projection, Catalog or scheduling gate, manifest field, Console surface, runtime protocol, or automation requires a separate Feature with explicit `SPEC.md` impact and accepted OpenSpec work.

## Consequences

Support language becomes reviewable against an exact tuple and explicit evidence envelope.
Warm-only, partial, or ambiguous results remain useful without being mislabeled as general support.
The hold outcome preserves the distinction between a model incompatibility and an Orchard defect.

Manual governance adds review and evidence-retention work.
It does not prevent catalog activation, Tenant publication, loading, or inference when no support claim is published.
Claims must be withdrawn or superseded when their tuple or envelope materially changes.
When a qualification record stops being approved, linked active claims change lifecycle in the same merged repository change.

The repository retains sanitized records and claims indefinitely.
Supporting evidence remains available for the lifetime of an active claim and at least twelve months after withdrawal or supersession.
Held evidence remains available until final disposition and for at least twelve months afterward, while other no-claim decisions retain evidence for at least twelve months after the decision.
Stricter security, incident, legal, or data-governance obligations may change those minima.

## SPEC.md impact

None - manual policy only.
This decision applies repository governance around existing `SPEC.md` sections 1.1, 1.4, 1.5, 3.4, 3.5, 5, 6, 7.2, 7.5, and 12 without changing product behavior.
