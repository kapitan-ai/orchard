# Define reasoning output contract

## Why

Orchard currently treats model reasoning as undifferentiated generated text.
That behavior preserves compatibility when callers omit a control, but it cannot safely support an operator request to suppress reasoning from the public answer.
Display-only delimiter stripping cannot control generation, prove parser correctness, preserve retry identity, or prevent hidden reasoning from leaking into persistence and diagnostics.

Issue #190 therefore needs one cross-layer contract before product code changes.
The contract must preserve existing omitted-request behavior byte for byte while defining how typed reasoning policy is rendered, negotiated, parsed, projected, accounted, retried, captured, and exposed.

## What changes

- Define independent generation and projection axes plus source provenance and one discriminated pinned effective contract on the canonical Request.
- Preserve the complete legacy pipeline for omitted Chat Completions and Responses controls.
- Make the Controller authoritative for typed policy, parser selection, exact model and template identity, and compatibility checks.
- Add provider-neutral Worker Runtime and Runtime Endpoint capability negotiation for explicitly selected reasoning modes.
- Require complete capability tuples and an authoritative loaded-worker acceptance proof before model invocation.
- Classify negotiated decoded output before tool-call parsing and caller stop matching, with fail-closed parser behavior.
- Extend Output Commitment and usage semantics for selected public reasoning and hidden reasoning tokens.
- Define exact-versus-lower-bound usage evidence and keep reasoning-token subsets internal until presence-aware wire contracts are accepted.
- Define final-only first-release behavior while deferring all concrete public control names and structured reasoning wire shapes to later accepted API contracts.
- Make hidden reasoning ephemeral under every capture mode and preserve exact public response hashing and replay behavior.
- Pin the complete reasoning contract across automatic and operator retry and fail closed across mixed versions.
- Preserve issue #189 as a display-only fallback for legacy blended output.

## Capabilities

### New capabilities

- `reasoning-output`: Defines Orchard's canonical reasoning policy, public projection, compatibility, API staging, Console behavior, and history rules.

### Modified capabilities

- `runtime-endpoints`: Adds exact reasoning capability negotiation, event compatibility, validation, and projection-selected commitment behavior.
- `worker-runtime-providers`: Adds provider-neutral reasoning parser ordering, hidden-content disposal, and exact usage requirements.
- `automatic-attempt-retry`: Pins the exact reasoning contract across attempts and aligns commitment, evidence, and accounting with the selected projection.
- `inference-capture`: Makes reasoning retention depend on public projection and prevents hidden content from entering any retained or diagnostic surface.

## SPEC.md impact

This change reconciles `SPEC.md` sections 3.4, 3.5, 3.6, 3.7.1, 5.3, 5.8, 6.4, 7.2.1, 7.2.8, 7.3.4, 7.5.3a, 9.3, 10.10, and 13.1.
`SPEC.md` remains the normative contract, and this package organizes the implementation intent across affected capabilities.

## Dependencies and coherence

This change depends on the payload-capture semantics in `enforce-inference-capture-modes` and the bounded retry semantics in `automatic-attempt-retry`.
It extends those contracts without widening capture or creating a second retry model.
The `enforce-inference-capture-modes` change SHALL be archived into the main `inference-capture` capability before this change is archived, so the additive reasoning requirements cannot create an incomplete capability on their own.
The reasoning capability is an exact runtime product contract and is independent of the manual repository governance proposed by `establish-model-qualification-governance`.
Neither an approved manual support claim nor a plausible model response proves runtime reasoning compatibility.

## Out of scope

- Product code, database migrations, protobuf field numbers, manifest encoding, or generated bindings.
- Concrete public request field names for final-only control.
- Concrete public reasoning-usage fields or channel-aware token-ID and logprob events.
- Chat Completions raw structured reasoning output.
- Responses structured reasoning item names, event names, raw-versus-summary semantics, replay shapes, or terminal ordering.
- Typed prior-reasoning input or reconstruction of reasoning from ordinary assistant messages.
- Historical reclassification of stored blended responses.
- Automated coupling to manual model-qualification records or support claims.
- Changing the omitted-request default away from the complete legacy pipeline.
