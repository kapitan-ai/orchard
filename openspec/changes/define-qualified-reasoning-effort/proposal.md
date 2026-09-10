# Define qualified reasoning-effort tiers

## Why

The accepted reasoning contract deliberately separates generation policy from public projection, but it has no provider-neutral way to select a qualified reasoning effort. Template controls and their values vary by exact artifact and chat template. Passing those values through would make provider vocabulary public policy, while inferring support from a model family or a successful sample would authorize unproven behavior.

Issue #398 adds only the contract needed to select a bounded effort tier after the existing negotiated reasoning path is implemented. It preserves every omitted request and leaves concrete public fields, renderer implementation, runtime encoding, parser work, and support claims to their existing follow-on work.

## What changes

- Add `reasoning_effort` as a separate optional canonical axis with the provider-neutral closed vocabulary `low | medium | high`.
- Permit a non-`nil` effort only for a negotiated `generation_policy = enabled` and `projection = final_only` request. Effort with `model_default` or `disabled` fails closed before the first Request write, scheduling, dispatch, or model invocation.
- Preserve the existing generation-policy semantics when effort is omitted. Neither normalization nor serialization may synthesize a default tier or change an omitted-request hash domain.
- Require the exact artifact/template renderer to map a canonical tier through a closed qualified mapping bound to the exact artifact digest, chat-template digest, render contract, and render-contract version, and require render metadata to prove that the applied effort equals the selected tier before dispatch, mapping an unprovable render result to the existing `503 server_error` and `runtime_incompatible` row rather than a caller error. Public callers cannot pass arbitrary template keywords or provider values.
- Extend exact manifest, capability, and loaded-worker acceptance tuples to include the selected canonical tier when present, while preserving legacy-only behavior when no complete tuple is negotiated.
- Separate the closed `unsupported_reasoning_control` mapping into a contradictory-combination row and an exact-tuple capability row, keeping identical statuses, codes, and retry semantics while fixing `param` to the concrete offending accepted public field and `nil` for the Console.
- Gate any future Console effort selection behind `enabled + final_only` and exact-tuple proof, with no effort selector until that contract is accepted.
- Preserve PR #325's enabled-conformance rule for every tier: a tier that cannot prove valid non-empty reasoning for its exact tuple is unsupported. Runtime advertisement proves only the exact renderer mapping and provider-neutral protocol conformance and asserts no per-artifact semantics; repository-owned qualification owns what may be offered or represented as supported; and an advertised tier that unexpectedly produces no reasoning keeps the existing fail-closed `500 api_error` terminal conformance outcome. No provider-owned semantic record or manifest semantic assertion is added, so `SPEC.md` §6.4 independence is preserved.
- Pin a selected tier and the exact mapping-bearing contract across retries, capture, hashing, idempotency, replay, rolling upgrades, and `N`/`N-1` compatibility.
- Define the qualification boundary between static render acceptance, runtime conformance, semantic effort evidence, and an approved scoped support claim.

## Capabilities

### Modified capabilities

- `reasoning-output`: Adds the canonical effort axis, validity matrix, provider-neutral vocabulary, staged public-control rule, and exact renderer-mapping boundary.
- `runtime-endpoints`: Adds the selected tier to complete capability and loaded-worker acceptance tuples without defining a wire encoding.
- `worker-runtime-providers`: Requires provider conformance fixtures to preserve selected-tier identity and to reject mismatched execution evidence before invocation.
- `automatic-attempt-retry`: Pins selected effort and the exact mapping-bearing negotiated contract across retries.
- `inference-capture`: Preserves hash, idempotency, replay, capture, and hidden-reasoning boundaries for every valid tier.
- `model-qualification-governance`: Distinguishes static mapping, runtime conformance, semantic tier qualification, and an approved support claim.

## SPEC.md impact

This change amends `SPEC.md` sections 3.4, 3.5, 6.4, 7.2.1, 7.2.7, 7.2.8, 7.3.4, 7.5.3a, 10.10, and 13.1. `SPEC.md` remains the normative contract; this package is a focused implementation and review guide.

## Dependencies and sequencing

This is a contract-only child of issue #190 and PR #325. It preserves PR #325's independent generation-policy and projection axes.

Every capability this change touches must already exist in the main specs before these additive effort requirements are merged into them. The `define-reasoning-output-contract` change SHALL be archived into the main `reasoning-output` capability, the `enforce-inference-capture-modes` change SHALL be archived into the main `inference-capture` capability, and the `establish-model-qualification-governance` change SHALL be archived into the main `model-qualification-governance` capability before this change is archived, so the effort requirements cannot generate an incomplete capability or placeholder purpose prose on their own. The `runtime-endpoints`, `worker-runtime-providers`, and `automatic-attempt-retry` capabilities already exist in the main specs, but their reasoning requirements arrive with `define-reasoning-output-contract`, which SHALL therefore also be archived before this change.

Implementation remains sequenced through issue #326 for canonical normalization and exact rendering, #327 for concrete Runtime Endpoint and Worker Runtime encoding, #328 for parser and final-only projection conformance, #329 for usage, retry, and capture implementation, and #331 for concrete public Chat Completions and Responses fields. This change does not create a parallel render, runtime, parser, capture, or public-control path.

The exact `mlx-community/Qwen3.8-27B-4bit` fixture is limited to its qualified renderer evidence: canonical `low`, `medium`, and `high` may map to that exact template's `low`, `medium`, and `xhigh` values. Those provider values are not canonical vocabulary, a model allowlist, or support evidence for another tuple.

## Out of scope

- Product code, database migrations, protocol fields, generated bindings, or public API behavior.
- A concrete Chat Completions or Responses field name; issue #331 owns that later accepted public-input contract.
- Arbitrary `chat_template_kwargs` or provider-value pass-through.
- Model-family, publisher, or template-keyword inference in canonical policy.
- Raw structured reasoning, typed prior-reasoning history, pilot-default selection, general Qwen3.8 support claims, or server-side tool execution.
- Treating static render success, a sample response, a manual qualification record, or a support claim as Runtime Endpoint dispatch authority.
