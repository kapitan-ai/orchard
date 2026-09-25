# Define public reasoning controls

## Why

`SPEC.md` defines provider-neutral reasoning generation, final-only projection, exact runtime proof, conformance, usage, retry, and capture boundaries, but it still reserves the concrete public request field names. Issue #331 needs one identical Chat Completions and Responses input contract before any public activation can be implemented.

This change accepts only that public contract. It preserves the complete omitted-request path and leaves every runtime, parser, accounting, Console, and model-specific implementation with its existing owner.

## What changes

- Accept one top-level `reasoning` object on both public inference endpoints with required boolean `enabled` and optional `effort = null | low | medium | high`.
- Make object presence select `final_only`, map the boolean to `disabled | enabled`, and map omitted or `null` effort to canonical `nil` without a default tier.
- Reject invalid types, invalid effort values, and unrecognized `reasoning` members as `400 invalid_request_error` with `invalid_value`, and reject a non-`nil` effort with `enabled = false` as `400 invalid_request_error` with `unsupported_reasoning_control`, before Request persistence, scheduling, or dispatch.
- Preserve the existing `unsupported_reasoning_control`, `runtime_incompatible`, and content-free `internal_error` boundaries with concrete `reasoning` and `reasoning.effort` parameter paths.
- Preserve exact omitted request bytes, serialization, `body_hash`, idempotency, and legacy behavior. Include every accepted explicit control in the normalized public-body hash.
- Keep structured reasoning input, items, and events disabled in the first release.

## Capabilities

### New capabilities

None.

### Modified capabilities

- `reasoning-output`: Accepts the concrete public final-only input contract and its validation, hashing, response-surface, and mixed-version boundaries.

## SPEC.md impact

This change amends `SPEC.md` sections 3.4, 7.2.1, 7.2.4, 7.2.5, and 7.2.7. `SPEC.md` remains the normative contract; this package is a focused acceptance and implementation handoff.

## Dependencies and sequencing

This is a contract-only child of issue #190 and merged contract PR #325. It satisfies only the concrete public-input acceptance deferred by `define-reasoning-output-contract` and `define-qualified-reasoning-effort`.

The current public request validators are the activation boundary: neither endpoint accepts `reasoning`, so no public decoder can currently produce `source = explicit_public`. The shared `CanonicalRequest` validator nevertheless still accepts the dormant `explicit_public + model_default + final_only + nil` combination. This proposal narrows the future public contract without claiming that implementation already conforms; issue #326 must close that constructor gap and add regression coverage before activation. Changing that runtime code in this contract-only change is explicitly excluded.

PR #425 retains qualified effort and exact renderer-mapping ownership. PR #431 retains negotiated runtime schema, live proof, and preparation ownership. PR #434 retains post-invocation conformance mapping ownership. This change references those boundaries and does not duplicate or complete their implementation.

Public activation remains blocked until issues #326, #327, #328, and #329 have each completed and merged their required implementation. Before #329 classified usage writers required for activation are enabled, the reader bridge merged by PR #421 must be deployed to every Controller and background reader and that deployment must be explicitly attested. A merged contract, green CI, static fixture, or compatible reader alone is not activation or deployment evidence.

Before this change is archived, `enforce-inference-capture-modes` must establish the main `inference-capture` capability and precede `define-reasoning-output-contract`; `define-reasoning-output-contract` must establish the main `reasoning-output` capability; `establish-model-qualification-governance` must establish its main capability; and `define-qualified-reasoning-effort` must be archived after those prerequisites and before this change. This package must not create an incomplete replacement capability or placeholder purpose prose to bypass that order.

Console issue #330 remains included in the offered #400 workflow and retains its own contract, design, and implementation. Accepting this public API contract does not complete or activate Console controls.

## Out of scope

- Public-field implementation in validators, serializers, controllers, or shared normalization code.
- Protocol declarations, generated bindings, Runtime Endpoint or Worker Runtime implementation, scheduling, dispatch, or preparation changes.
- Parser, usage, retry, capture, replay, persistence, migration, or backfill changes.
- Console contract, design, implementation, or tests.
- Production registry entries, provider-value pass-through, arbitrary template keyword arguments, public `xhigh`, model-family conditionals, or model-specific code.
- Structured reasoning input, items, events, typed prior-reasoning history, or public reasoning-token usage.
- Archiving predecessor packages, deployment, qualification, inference, or support claims.
