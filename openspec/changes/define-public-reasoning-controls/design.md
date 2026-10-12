# Public reasoning-control design

## Context

The apex contract already separates reasoning generation from public projection and fixes the downstream exact renderer, loaded-proof, parser, conformance, retry, usage, capture, and compatibility boundaries. PR #491 (`request-local-reasoning-effort`) shipped the public effort fields. Chat Completions takes top-level `reasoning_effort`; Responses takes `reasoning` containing exactly `effort`. Values are model/template-registered public identifiers matching `[a-z][a-z0-9_]{0,31}`. Effort alone selects rendered `explicit_public + enabled + legacy_blended`. #491 states that negotiated final-only parsing remains separate.

The missing decision is how a caller explicitly selects `projection = final_only` without changing what any request valid on main means. A design record is warranted because the selector is an irreversible public compatibility choice with nested validation and error paths across two endpoints. This document records only that choice and does not define an implementation.

## Goals

- Add one explicit, additive final-only selector on both endpoints.
- Keep #491's fields, identifiers, aliases, discovery, and effort-only semantics unchanged.
- Preserve the exact legacy path when every reasoning control is absent.
- Keep malformed values distinct from valid but unsupported explicit controls.
- Preserve the existing final-only response and failure contracts without adding reasoning output fields or events.
- Keep activation separate from contract acceptance.

## Non-goals

This change does not define protocol encoding, renderer mappings, parser behavior, accounting writers, Console behavior, production registrations, final-only discovery, or model-specific policy. It does not widen the closed negotiated effort vocabulary. It does not introduce structured reasoning output or prior-reasoning input.

## Decisions

### 1. `reasoning.enabled` is the explicit final-only selector

```text
Responses:         reasoning = { effort?: identifier, enabled?: boolean }   (at least one member)
Chat Completions:  reasoning_effort?: identifier
                   reasoning = { enabled: boolean }
```

The selector is the JSON boolean `enabled`. Its presence selects `projection = final_only` and `source = explicit_public`. `enabled = false` selects `generation_policy = disabled`; `enabled = true` selects `generation_policy = enabled`. The selector has no representation for `explicit_public + model_default`.

| Selector | Effort | Canonical result |
|---|---|---|
| absent | absent | `omitted_public + model_default + legacy_blended` (main, unchanged) |
| absent | present | `explicit_public + enabled + legacy_blended`, rendered (#491, unchanged) |
| `true` | absent | `explicit_public + enabled + final_only`, no tier |
| `true` | present | `explicit_public + enabled + final_only`, negotiated tier |
| `false` | absent | `explicit_public + disabled + final_only`, no tier |
| `false` | present | `400 unsupported_reasoning_control` at the effort field |

Why this design:

- It is purely additive. On main, Responses rejects `reasoning.enabled` as `unsupported_parameter` and Chat Completions rejects a top-level `reasoning` the same way. Every request valid on main therefore keeps its meaning, and effort alone keeps selecting rendered legacy-blended output.
- Each endpoint keeps exactly one effort field, the one #491 shipped. Chat `reasoning` deliberately has no `effort` member, so callers never have to reconcile two effort values.
- The selector is explicit. Final-only is never inferred from effort, from a registered value, or from a model advertising reasoning support.
- It keeps the canonical mapping the PR #325 matrix and Console #330 already use: one boolean selecting `disabled` or `enabled` with `final_only`.

This is a prospective, unactivated mapping. The lower shared `CanonicalRequest` validator still permits `explicit_public + model_default + final_only + nil`. That dormant representational allowance predates this public shape and does not make the selector accepted. Issue #326 must narrow `validate_reasoning_combination!/5` and test the rejected combination before either public validator admits the selector. This package does not modify runtime code.

### 2. Effort under the selector reuses #491's fields with the negotiated vocabulary

Effort under the selector uses the same field, identifier syntax, and malformed-value rejection as #491. Explicit `null` stays malformed, as on main; omission is the only way to select no tier. There is no public closed enum and no ban on any identifier spelling.

Supported values come from the negotiated contract, not the rendered registration. `SPEC.md` §3.4 and `define-qualified-reasoning-effort` keep the negotiated canonical vocabulary closed at `low | medium | high`, and an exact negotiated renderer mapping must qualify the tier for the selected tuple. A well-formed identifier outside that vocabulary, such as `xhigh`, or a tier the exact tuple does not qualify, is a capability failure (`unsupported_reasoning_control`), not `invalid_value`. The same identifier can be valid rendered effort for that model, so it is not malformed.

A rendered registration, alias, or native mapping does not by itself authorize final-only use. Under the selector, `high` names the negotiated canonical tier `high` and its exact negotiated mapping. It does not name #491's rendered `high`-to-native-`xhigh` alias, although the exact Qwen negotiated fixture may also map to native `xhigh`. The `orchard_reasoning_effort` discovery object stays rendered-effort only.

### 3. Validation order extends #491's order

The Controller validates before the first Request write, scheduling, or dispatch. The endpoint's effort field is `reasoning_effort` on Chat Completions and `reasoning.effort` on Responses. The first failing condition determines the public error and `param`:

1. present `reasoning` is `null` or not an object: `invalid_value`, `reasoning`;
2. unrecognized `reasoning` member (other than `effort`/`enabled` on Responses, other than `enabled` on Chat): the existing `unsupported_parameter`, `reasoning.<member>`;
3. `reasoning` object with no recognized member: `invalid_value`, `reasoning`;
4. present `reasoning.enabled` not a JSON boolean: `invalid_value`, `reasoning.enabled`;
5. present effort that is `null`, not a string, or not a bounded identifier: `invalid_value`, effort field;
6. well-formed effort with `enabled = false`: `unsupported_reasoning_control`, effort field;
7. after model resolution and authorization, exact capability: selector first with `reasoning.enabled`, then tier with the effort field, both `unsupported_reasoning_control`.

Steps 1, 2, 3, 5, and 7 reproduce #491's order. Every request without a Chat top-level `reasoning` or a Responses `reasoning.enabled` therefore keeps its current outcome. Unrecognized members keep the endpoints' existing unsupported-field mapping rather than a new `invalid_value` variant, so this change does not redefine shipped behavior.

After validation, no exact loaded proof keeps `503 server_error` with `runtime_incompatible`. Post-invocation parser or generation-policy conformance keeps content-free `500 api_error` with `internal_error`. Runtime and terminal failures keep `param = nil`. These mappings do not change the §7.5.3a distinction between confirmed incompatibility and transient capacity or unknown evidence.

### 4. Omission and effort-only are the compatibility boundary

Omitting every reasoning control does not synthesize canonical defaults into request bytes, serialization, or `body_hash`. Such a request continues through the exact `model_default + legacy_blended` path for sync and streaming requests. Effort-only requests keep #491's serialization and hash identity.

A present, valid selector, together with any effort, participates in the existing normalized public-body hash. Omitted effort produces no default tier or provider-specific value. This change adds no new idempotency key scope or replay rule; §3.9 and §10.10 continue to govern replay from the retained public response.

### 5. Final-only reuses existing public shapes

The selector selects final-only projection on both endpoints. Chat Completions continues to publish final text only through `message.content` and `choices[0].delta.content`. Responses continues through `output_text` and the existing `response.output_text.*` events. Existing selected tool output remains unchanged.

No reasoning item, reasoning delta, raw token channel, usage subset, or control echo is added. A post-start streaming failure uses the endpoint's existing error termination. This contract adds no event name and does not reinterpret a status already sent.

### 6. Acceptance does not authorize activation

Until activation, both endpoints keep rejecting the selector exactly as they do today. The selector stays disabled until the canonical/render, runtime-proof, parser/projection, and usage/retry/capture implementations owned by #326-#329 are merged. In particular, #326 must reconcile the shared constructor's current `explicit_public + model_default` allowance with Decision 1 before public decoding activates. The PR #421 reader bridge must be deployed and attested everywhere required before #329 classified writers activate. PRs #425, #431, #434, and #491 keep their existing ownership and are not duplicated here. Successful rendered-input steering is not activation evidence.

Mixed-version behavior remains fail-closed. An explicit final-only request MUST NOT be sent to a binding that lacks the complete negotiation required by §13.1, and MUST NOT be silently downgraded to rendered or legacy output. Omission continues to use the legacy binding behavior.

Console #330 is a separate input and UI surface. It does not inherit this public decoder, its effort-selector gate, or these public `param` paths merely because this contract is accepted.

## Alternatives rejected

- Presence of any `reasoning` object selects final-only (this PR's earlier shape): rejected because #491 already gives `reasoning: {effort}` the rendered legacy-blended meaning on Responses.
- Redefining effort as a closed `low | medium | high` public enum, or banning `xhigh` and other registered identifiers: rejected because it contradicts #491's registered-identifier contract. Final-only narrowing is a capability decision instead.
- Chat `reasoning.effort` alongside `reasoning_effort`: rejected because two effort fields on one endpoint need a conflict rule and invite drift.
- A named projection selector (for example a `projection` string or separate Orchard-namespaced object): rejected for now. It needs a second field to express `disabled` generation, and it diverges from the boolean mapping the canonical matrix and Console already use. See the open question in `tasks.md` 2.5.
- Making effort imply final-only on capable models: rejected because it would silently change the meaning of requests valid on main.
- Echo-free `param = reasoning` for unrecognized members (this PR's earlier rule): rejected because main already reports `reasoning.<member>` with `unsupported_parameter`, and this change must not redefine shipped behavior.
