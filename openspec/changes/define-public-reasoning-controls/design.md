# Public reasoning-control design

## Context

The apex contract already separates reasoning generation from public projection and fixes the downstream exact renderer, loaded-proof, parser, conformance, retry, usage, capture, and compatibility boundaries. The missing decision is the public JSON shape that selects those semantics consistently for Chat Completions and Responses.

A design record is warranted because the field is an irreversible public compatibility choice with nested validation and error paths across two endpoints. This document records only that choice and does not define an implementation.

## Goals

- Use one provider-neutral input shape on both public inference endpoints.
- Preserve the exact legacy path when the field is absent.
- Keep malformed values distinct from valid but unsupported explicit controls.
- Preserve the existing final-only response and failure contracts without adding reasoning output fields or events.
- Keep activation separate from contract acceptance.

## Non-goals

This change does not define protocol encoding, renderer mappings, parser behavior, accounting writers, Console behavior, production registrations, or model-specific policy. It does not introduce structured reasoning output or prior-reasoning input.

## Decisions

### 1. One presence-aware object

Both endpoints use the same top-level object:

```text
reasoning = {
  enabled: boolean,
  effort?: null | "low" | "medium" | "high"
}
```

The top-level value cannot be `null`. `enabled` is required and is not coerced. `effort` is optional; omission and explicit `null` both select canonical `nil` and do not infer a tier. Non-`null` values are exact, case-sensitive provider-neutral strings.

Object presence selects `projection = final_only` and `source = explicit_public`. `enabled = false` selects `generation_policy = disabled`; `enabled = true` selects `generation_policy = enabled`. The public object has no representation for `explicit_public + model_default`. A selected tier is valid only with `enabled = true`.

The shape exposes no provider values or renderer parameters. `xhigh` remains outside public vocabulary even when an exact closed renderer mapping uses it internally. No model name, family, publisher, or template convention changes normalization.

### 2. Validation precedes persistence and capability decisions

The Controller validates the accepted public shape before the first Request write, scheduling, or dispatch:

1. omission preserves the legacy path;
2. the present value must be a non-null object;
3. `enabled` must be present and boolean;
4. no member other than `enabled` and `effort` may be present;
5. a present non-null `effort` must be one of the three canonical strings;
6. a recognized non-null effort with `enabled = false` is rejected as a contradictory explicit control.

Invalid types and effort values use `400 invalid_request_error`, code `invalid_value`, with `param` set to `reasoning`, `reasoning.enabled`, or `reasoning.effort`. An unrecognized member uses the same status and code with the bounded `param = reasoning`, so several unrecognized members still reject deterministically and no caller-supplied key name reaches the envelope. The contradiction uses `unsupported_reasoning_control` and `reasoning.effort`.

Additional members and top-level aliases are not part of the accepted object and cannot become provider pass-through. Ignoring an unrecognized member would let the two endpoints diverge and answer a control the caller did not get, so it is rejected instead.

After shape validation, inability of the exact artifact, template, or renderer to honor the base control uses `unsupported_reasoning_control` with `reasoning`; inability to honor the selected tier uses the same code with `reasoning.effort`. No exact loaded proof retains `503 server_error` with `runtime_incompatible`. Post-invocation parser or generation-policy conformance retains content-free `500 api_error` with `internal_error`. Runtime and terminal failures keep `param = nil`.

These mappings do not change the existing distinction between confirmed incompatibility and transient capacity or unknown evidence in `SPEC.md` §7.5.3a.

### 3. Omission is the compatibility boundary

An omitted `reasoning` key does not synthesize canonical defaults into request bytes, serialization, or `body_hash`. It continues through the exact `model_default + legacy_blended` path for sync and streaming requests.

A present, valid object participates in the existing normalized public-body hash. Omitted or `null` effort produces no default tier or provider-specific value. This change adds no new idempotency key scope or replay rule: §3.9 and §10.10 continue to govern replay from the retained public response.

### 4. Final-only reuses existing public shapes

The explicit object selects final-only projection on both endpoints. Chat Completions continues to publish final text only through `message.content` and `choices[0].delta.content`; Responses continues through `output_text` and existing `response.output_text.*` events. Existing selected tool output remains unchanged.

No reasoning item, reasoning delta, raw token channel, usage subset, or control echo is added. A post-start streaming failure uses the endpoint's existing error termination; this contract adds no event name and does not reinterpret a status already sent.

### 5. Acceptance does not authorize activation

The public field remains disabled until the canonical/render, runtime-proof, parser/projection, and usage/retry/capture implementations owned by #326-#329 are merged. The PR #421 reader bridge must be deployed and attested everywhere required before #329 classified writers activate. PRs #425, #431, and #434 retain their existing ownership and are not duplicated here.

Mixed-version behavior remains fail-closed: an explicit request MUST NOT be sent to a binding that lacks the complete negotiation required by §13.1 and MUST NOT be silently downgraded. Omission continues to use the legacy binding behavior.

Console #330 is a separate input and UI surface. It does not inherit this public decoder, its effort-selector gate, or these public `param` paths merely because this contract is accepted.

## Alternatives rejected

- Separate Chat and Responses fields: rejected because they could drift while selecting the same canonical contract.
- Flat `reasoning_enabled` and `reasoning_effort` fields: rejected because the accepted contract is one presence-aware object and effort must not imply enablement.
- A string mode or provider dictionary: rejected because it would expose provider vocabulary or create arbitrary template arguments.
- Public `xhigh` or model-family aliases: rejected because canonical vocabulary is closed and exact mappings are artifact- and template-bound.
- Presence defaults to enabled or to a tier: rejected because `enabled` is required and effort has no default.
