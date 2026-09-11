# Design: Define qualified reasoning-effort tiers

## Context

PR #325 established independent reasoning generation-policy and public-projection axes. A reasoning-capable renderer can still expose provider-specific effort values that vary by exact model artifact and template. Those values do not establish a portable public vocabulary, a Runtime Endpoint capability, semantic effect, or a model support claim.

Issue #398 supplies the narrow missing contract. It must preserve omitted public requests on the complete legacy path and let future implementation select only exact, qualified mappings. The first fixture is `mlx-community/Qwen3.8-27B-4bit`, whose exact template values are `low`, `medium`, and `xhigh`; the third is evidence for canonical `high`, not a new canonical tier.

## Goals and non-goals

### Goals

- Define a provider-neutral closed effort vocabulary and validity matrix.
- Preserve independent generation-policy and projection authority.
- Require exact renderer mapping and complete capability evidence before execution.
- Preserve existing omitted-request, hidden-reasoning, retry, capture, hash, replay, and mixed-version guarantees.
- Keep manual qualification evidence and support claims distinct from runtime dispatch authority.

### Non-goals

- Implement a public field, renderer mapping, protocol encoding, parser behavior, or model behavior.
- Expose arbitrary template kwargs or provider values.
- Infer mappings from a model name, publisher, template keyword, or model family.
- Make Qwen3.8 an allowlist entry, offered model, default, or general support claim.
- Change raw structured reasoning, prior-reasoning history, tool execution, or the legacy display fallback.

## Decisions

### Use a separate optional closed axis

The canonical Request adds `reasoning_effort: nil | low | medium | high` beside `generation_policy` and `projection`. It answers how much qualified reasoning the renderer asks for; it neither selects whether reasoning is generated nor selects what becomes public output.

A non-`nil` tier is valid only when all of the following hold:

- the request is negotiated rather than omitted legacy;
- `generation_policy = enabled`;
- `projection = final_only`; and
- the exact contract proves that tier.

A tier with `generation_policy = model_default` or `disabled` is contradictory and fails closed before a Request write. This preserves the accepted meaning of `model_default`: Orchard permits the template-owned generation default rather than silently altering it. It also preserves the existing `disabled` conformance rule.

Effort is optional even for `enabled + final_only`. Absence means no effort tier was selected; Orchard does not manufacture a default tier. Omitted public controls remain `model_default + legacy_blended` with `reasoning_effort = nil`, and their existing public-body bytes and hash domain remain unchanged.

### Stage public vocabulary, not a wire name

The provider-neutral vocabulary is exactly `low`, `medium`, and `high`. A later accepted issue #331 public-input contract will choose concrete field names for both endpoints. It must expose only this vocabulary, normalize it into the canonical axis, and use the existing closed `unsupported_reasoning_control` error mapping. It must not expose provider values or accept effort alone without an explicit enabled generation policy.

The prohibition on provider-specific reasoning-effort pass-through does not prohibit this provider-neutral canonical axis. Its internal name does not choose a public API field name.

That mapping now carries two distinct rows: a contradictory tier/policy combination that is never valid on any model, and an exact-tuple capability failure that another qualified model may honor. Both keep `400 invalid_request_error` and `unsupported_reasoning_control` and stay non-retryable, so the split is remediation guidance rather than a new envelope. #331 must set `param` to the concrete offending accepted public field — the reasoning-control field for a control failure and the effort field for a tier failure — while the Console, which supplies no public field, keeps `param = nil`.

This amendment therefore defines request semantics without preempting the concrete Chat Completions or Responses encoding that #331 owns.

### Bind renderer mappings to an exact tuple

The Controller selects a renderer mapping only through a closed mapping bound to the exact artifact digest, chat-template digest, render-contract name, and render-contract version. That mapping maps one canonical tier to the provider-specific key and value required by the exact renderer. Callers never supply that key or value.

`SPEC.md` §3.5 owns this render-time boundary alongside the existing typed generation-policy mapping, so a tier can never satisfy the contract by reaching the renderer as an unmapped template keyword. The tokenizer's effective render metadata must let the Controller prove the applied effort, and a metadata result that omits or contradicts the selected tier fails before dispatch.

That failure is not a caller error. The tier was accepted and qualified, so an unprovable render result is a renderer or metadata defect and maps to the existing `503 server_error` and `runtime_incompatible` row rather than `400 unsupported_reasoning_control`. No new code is introduced: that row now covers every pre-invocation failure to prove the exact negotiated tuple, whether the unproven evidence is endpoint advertisement, render metadata, or loaded-worker acceptance. A tier with no exact qualified mapping at all remains the `400` capability row, because there the caller's requested combination is the thing that cannot be honored.

The selected canonical tier is part of the complete negotiated tuple:

```text
(generation_policy, projection, reasoning_effort,
 model_artifact_digest, chat_template_digest,
 render_contract, render_contract_version,
 parser_family, parser_version,
 runtime_contract_version, event_binding_version)
```

Each advertised tuple is atomic. Independent lists of tiers, artifact digests, template digests, or mapping values cannot authorize a Cartesian product. The loaded-worker acceptance proof echoes this same complete tuple and its worker incarnation before model invocation.

The Qwen3.8 fixture proves only the exact qualified mapping `low -> low`, `medium -> medium`, and `high -> xhigh` for its exact artifact/template tuple. Missing mappings, unknown tiers, contradictory policy/tier input, stale evidence, and an incompatible loaded-worker proof all fail closed. The fixture does not infer mappings for any other artifact or template.

### Preserve post-selection boundaries

A selected tier does not change parser ordering: negotiated parsing remains before tools and caller stops, and only final answer text reaches the public final-only channel. Hidden reasoning stays ephemeral for every valid tier. Usage continues to account for exact total generated output or a validated lower bound without exposing a reasoning-token subset.

Retries pin the selected tier together with all existing negotiated identity. Hashing and idempotency serialize only what the accepted public contract actually supplied; a missing effort never becomes an injected nullable or default value. Replay returns the retained public response without rerendering or reselecting effort.

A Controller and Node Agent that lack the complete selected-effort contract exchange only legacy variants. An older or non-advertising binding never receives a selected tier or a new event variant.

### Separate four evidence boundaries

1. **Static render acceptance** proves that the exact renderer can apply one exact mapping to a rendered prompt. It proves neither generation, parser conformance, runtime negotiation, semantic effect, nor support.
2. **Runtime conformance** proves fresh complete-tuple observation for selection and dispatch to an already loaded placement, then exact loaded-worker acceptance through `PrepareInference` before invocation. The Controller validates acceptance before marking the attempt running or forwarding later events. Neither phase proves semantic quality or a support claim.
3. **Semantic tier qualification** evaluates predeclared meaningful assertions and final-only separation for each exact tuple, endpoint mode, and proposed tier envelope. A sample success is insufficient. Because a tier is valid only with `generation_policy = enabled`, this boundary must also prove valid non-empty reasoning content across the claimed envelope, including its shortest prompt classes; a tier that cannot is unsupported for that tuple rather than an offered tier that terminalizes as a conformance failure.

The enabled-conformance rule binds both owners without joining them, and the split follows what each side can actually prove. Provider-neutral conformance fixtures are model-agnostic protocol artifacts (`SPEC.md` §7.5.2a), so runtime advertisement can prove only that an exact tuple has a qualified renderer mapping and that the provider passes protocol conformance; the Controller selects and dispatches an already loaded placement on that fresh observation and required render proof, then requires `PrepareInference` to prove the current loaded binding and worker incarnation before invocation. A per-artifact semantic claim — that this exact artifact, template, and tier yield meaningful non-empty reasoning — is not something a neutral fixture can establish, so no runtime producer is defined for one.

Repository-owned qualification is therefore the only place tier semantics are evaluated, and it decides only what may be offered or represented as supported. We deliberately do not add a provider-owned semantic record or a manifest semantic assertion to close the gap: either would recreate the governance-to-runtime coupling `SPEC.md` §6.4 forbids. The residual case — an advertised tier that unexpectedly produces no reasoning — keeps the existing fail-closed `500 api_error` terminal conformance outcome rather than a relaxed rule.
4. **Approved support claim** is the separate manual-governance decision that may represent only the evidenced envelope. It is not a manifest field, scheduler gate, or execution permit.

## Alternatives considered

### Pass through template kwargs

Rejected because it exposes provider vocabulary, prevents stable validation, and lets a caller form unsupported combinations.

### Make effort another generation-policy value

Rejected because it would collapse the independent concerns accepted in PR #325. Effort only refines an explicitly enabled generation request; it cannot silently change `model_default` or `disabled`.

### Make `xhigh` canonical

Rejected because it is an exact Qwen3.8 renderer value, not a provider-neutral product term. Canonical `high` preserves a stable contract while allowing qualified mapping evidence.

### Treat qualification as dispatch proof

Rejected because static and manual evidence cannot replace fresh tuple advertisement and loaded-worker acceptance proof.
An unqualified tier lacks required technical proof at its respective validation phase: exact mapping, render proof, and fresh observation before dispatch; `PrepareInference` acceptance before invocation. Semantic qualification is not an additional admission, selection, scheduling, preparation, or dispatch gate: a technically proven but semantically unqualified tier may execute and remains subject to enabled-conformance terminal failure. This preserves `SPEC.md` §6.4 and ADR 0028.

## Sequencing and validation

Issue #326 owns canonical normalization and renderer implementation. Issue #327 owns the concrete negotiated Runtime Endpoint and Worker Runtime encoding. Issue #328 owns parser and final-only projection conformance. Issue #329 owns usage, retry, capture, hash, and replay implementation. Issue #331 owns public field names and endpoint behavior.

Each implementation must use the exact fixture matrix: Qwen3.8 `low`, `medium`, and `xhigh`, plus missing, unknown, contradictory, incompatible, stale, and mixed-version evidence. It must distinguish the four evidence boundaries above and must not convert static or semantic fixture success into a broad model support claim.
