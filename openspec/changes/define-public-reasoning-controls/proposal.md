# Define public reasoning controls

## Why

`SPEC.md` defines provider-neutral reasoning generation, final-only projection, exact runtime proof, conformance, usage, retry, and capture boundaries. PR #491 (`request-local-reasoning-effort`) then shipped the public effort fields: Chat Completions `reasoning_effort` and Responses `reasoning.effort`. Both select rendered-input `enabled + legacy_blended` and accept model/template-registered identifiers. That change explicitly left negotiated final-only parsing separate. Issue #331 still needs a public way to request `projection = final_only` on both endpoints before any activation can be implemented.

This change accepts only that public selector. It layers on #491 without changing any request that is valid on main. It preserves the omitted-request path and the effort-only rendered path. It leaves every runtime, parser, accounting, Console, and model-specific implementation with its existing owner.

## What changes

- Add an explicit final-only selector, the JSON boolean `enabled`, inside a `reasoning` object. On Responses it is the only additional member of #491's `reasoning` object. On Chat Completions it is a new top-level `reasoning` object containing exactly `enabled`; Chat effort stays in #491's top-level `reasoning_effort`.
- Make selector presence select `final_only` and `explicit_public`, mapping `enabled = false` to `disabled` and `enabled = true` to `enabled`. Selector absence keeps main's meaning: omitted stays `model_default + legacy_blended`, and effort-only stays rendered `enabled + legacy_blended`.
- Under the selector, reuse #491's effort fields, identifier syntax, and malformed-value rejection. Supported values are those the exact negotiated renderer mapping qualifies inside the closed negotiated vocabulary `low | medium | high` from `SPEC.md` §3.4. Other well-formed identifiers fail as `unsupported_reasoning_control`, not as malformed input.
- Fix one validation order covering Chat `reasoning_effort` and Responses `reasoning.*`. It keeps #491's order and outcomes for every request without the selector. It uses the existing closed mappings: `invalid_value`, `unsupported_reasoning_control` (400), `runtime_incompatible` (503), and content-free `internal_error` (500). Unrecognized `reasoning` members keep the endpoints' existing `unsupported_parameter` rejection.
- Preserve exact omitted and effort-only request bytes, serialization, `body_hash`, and idempotency. Include the selector in the normalized public-body hash when present.
- Keep structured reasoning input, items, and events disabled in the first release.

## Capabilities

### New capabilities

None.

### Modified capabilities

- `reasoning-output`: Adds the public final-only selector, its validation order, its hashing, response-surface, and activation boundaries. The requirements are added alongside, and do not modify, the requirements `request-local-reasoning-effort` adds to the same capability.

## SPEC.md impact

This change amends `SPEC.md` sections 3.4, 7.2.1, 7.2.4, 7.2.5, 7.2.7, and 7.2.9. `SPEC.md` remains the normative contract; this package is a focused acceptance and implementation handoff.

## Dependencies and sequencing

This is a contract-only child of issue #190 and merged contract PR #325. It satisfies the concrete public final-only input acceptance deferred by `define-reasoning-output-contract`, `define-qualified-reasoning-effort`, and `request-local-reasoning-effort`.

The current public request validators are the activation boundary. Responses rejects `reasoning.enabled` as `unsupported_parameter`, and Chat Completions rejects a top-level `reasoning` the same way, so no public decoder can currently produce `explicit_public + final_only`. The shared `CanonicalRequest` validator nevertheless still accepts the dormant `explicit_public + model_default + final_only + nil` combination. This proposal narrows the future public contract without claiming that implementation already conforms. Issue #326 must close that constructor gap and add regression coverage before activation. Changing that runtime code in this contract-only change is explicitly excluded.

PR #425 retains qualified effort and exact renderer-mapping ownership. PR #431 retains negotiated runtime schema, live proof, and preparation ownership. PR #434 retains post-invocation conformance mapping ownership. PR #491 retains the rendered effort fields, registry, discovery object, and preparation binding. This change references those boundaries and does not duplicate or complete their implementation.

Public activation remains blocked until issues #326, #327, #328, and #329 have each completed and merged their required implementation. Before #329 classified usage writers required for activation are enabled, the reader bridge merged by PR #421 must be deployed to every Controller and background reader and that deployment must be explicitly attested. A merged contract, green CI, static fixture, compatible reader, or successful rendered-input steering alone is not activation or deployment evidence.

Before this change is archived, `enforce-inference-capture-modes` must establish the main `inference-capture` capability and precede `define-reasoning-output-contract`. `define-reasoning-output-contract` must establish the main `reasoning-output` capability, and `establish-model-qualification-governance` must establish its main capability. `define-qualified-reasoning-effort` and then `request-local-reasoning-effort` must be archived after those prerequisites and before this change. This package must not create an incomplete replacement capability or placeholder purpose prose to bypass that order.

Console issue #330 remains included in the offered #400 workflow and retains its own contract, design, and implementation. Accepting this public API contract does not complete or activate Console controls.

## Out of scope

- Public-field implementation in validators, serializers, controllers, or shared normalization code.
- Any change to #491's rendered effort fields, registered identifiers, aliases, discovery object, or effort-only semantics.
- Final-only discovery metadata; the existing `orchard_reasoning_effort` object stays rendered-effort only.
- Protocol declarations, generated bindings, Runtime Endpoint or Worker Runtime implementation, scheduling, dispatch, or preparation changes, including widening the closed negotiated effort vocabulary.
- Parser, usage, retry, capture, replay, persistence, migration, or backfill changes.
- Console contract, design, implementation, or tests.
- Production registry entries, provider-value pass-through, arbitrary template keyword arguments, model-family conditionals, or model-specific code.
- Structured reasoning input, items, events, typed prior-reasoning history, or public reasoning-token usage.
- Archiving predecessor packages, deployment, qualification, inference, or support claims.
