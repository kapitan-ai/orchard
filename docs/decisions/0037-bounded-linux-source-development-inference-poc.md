# ADR 0037: Bounded Linux source-development inference experiment

## Status

Proposed current-main reconciliation of the historical KAP-112 source experiment.
Historical acceptance and execution apply only to their original revisions, not
to this port. No current-main real API or OpenCode proof is established. Live
supervisor and download execution require separate owner approval and have not
run for this port.

## Context

The source ADR and OpenSpec package in `31ed46b5`, updated in `b66a4001`, explored
one bounded vLLM route. Their runtime registration and final-only projection do
not match main's KAP-49 rendered-effort and legacy-blended contract. Replaying
their completed tasks or execution permissions would misrepresent current truth.

This is an independent source-development experiment within the existing
support and qualification boundaries of `SPEC.md` §1.4, §1.5, §4.10 and
Milestone 9, not fulfillment of `reconcile-linux-node-source-dev-contract`.
[ADR 0035](0035-experimental-linux-node-source-development.md) remains unchanged.
The accepted Linux Node change remains untouched, with its implementation and
qualification still pending.

## Decision

### Worker seam and output

Keep `vllm_poc` separately selected and default-off behind the existing local
gRPC Worker service. The Controller does not call vLLM directly. The adapter
uses Orchard's already rendered prompt on loopback HTTP `/v1/completions`, port
58080, with logical load/unload and concurrency one. Add no Controller, shared
request or tokenizer registration contract.

Require the rendered prompt suffix `<think>\n` and sampling temperature `1.0`
and top-p `0.95`; the pinned remaining sampler is top-k `20`, min-p `0`, presence
penalty `0`, repetition penalty `1`. Reject token-ID input and logprobs rather
than approximating them. Bound total decoded output, including reasoning, not
just the final suffix.

Preserve generated reasoning bytes as legacy-blended text under main KAP-49.
Stateful framing begins inside the prompt-opened reasoning frame and identifies
an unambiguous final suffix after its matching streamed close. Framing is only a
tool-parsing locator, not negotiated-mode fail-closed reasoning validation or a
`final_only` projection. Raw `legacy_blended` output passes through even when
thinking ends at length or reasoning framing is malformed; without an
unambiguous final suffix, do not parse tools. Parse Qwen XML tools only in that
suffix, never tool-like reasoning. Preserve a text prefix exactly, then emit
complete requested tool calls in source order with UUID call IDs under KAP-116.
Only whitespace may separate or follow tool blocks. Fail closed on complete or
ambiguous tool syntax there, including malformed, unknown, unrequested,
duplicate-argument, interleaved or trailing-text cases. Truncated marker prefixes
fail closed only at length; at clean stop they remain ordinary text.

Decode parameters using `tool.parameters.properties[name].type`: declared
`string` retains raw text; `number`, `integer`, `boolean`, `object`, `array` and
`null` require JSON parsing and matching types. Absent or unknown types retain
vLLM qwen3 JSON-or-trimmed-text semantics. Non-finite values and numeric parse
failures are `tool_call_parse_failed`. This decoding is not general JSON Schema
validation of model-selected values. Total decoded-output bounds still include
reasoning and framing; pass-through does not discard bytes to fit the bound.
Deterministic coverage must split control markers across chunks and cover these
stop/length distinctions and bounded-output failures.

Tool structure uses monotonic delimiter scanning, not backtracking regexes.
HTTP identity checks have a wall-clock deadline. Cancellation shuts down the
retained transport socket even when the response owns it; an unsettled reader
makes the Worker unhealthy and blocks further local admission until replacement.
That local safeguard proves no provider-native cessation or capacity release.

### Historical reference, not a support tuple

The historical proven reference is the vLLM 0.27.1 image
`vllm/vllm-openai:v0.27.1@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`
and image ID `sha256:e0cfcfcb9b86e2c2d0d52a93689773f20f380cb8e050a24ce550c44f6f55c5eb`
with `Qwen/Qwen3.8-27B` revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, BF16 weights/KV cache and concurrency
one on an H100 NVL. Its selected 32-file snapshot is 55,586,114,863 bytes, not
Hub repository-level `used_storage`. The reference envelope was 131,072 rendered
input tokens plus 8,192 output tokens, a 139,264-token serving limit and a 0.80
GPU-memory allocation target, not a hard memory ceiling. These immutable
identities describe history; they confer no current-main model, provider,
hardware, platform, OpenCode or workload qualification or support.

### Disabled historical execution

Retain deterministic scripts and tests only. Historical smoke-runner `main` and
`execute` fail closed before mutation; historical setup is disabled. The source
bundle's effort artifact digest differs from main's source-owned effort
registry, and main does not consume the old registration environment variable.
Do not restore runtime registration, silently use template defaults, or bypass
guards to make the old fixture execute.

The supervisor requires `ORCHARD_KAP112_GPU_UUID` and
`ORCHARD_KAP112_SNAPSHOT_ROOT`; presence of those values is not authorization.
A future live plan must separately obtain owner approval of exact clean source,
tuple, bounds, mutation and cleanup. It must stop on drift or exhausted bounds,
use loopback/owner-only transports and disposable state, and restore only its
owned baseline. A wrapper-owned provider remains outside Node Agent child
custody. Logical unload, HTTP close and container stop prove neither native
cessation nor request-slot or resource release, and create no capacity authority.
OpenCode tools remain client-owned, not Orchard execution or confinement.

## Alternatives and consequences

- Rebuild the exact qualified fixture for main KAP-49 with newly reviewed
  provenance under current registration, or separately accept a new artifact
  profile. Neither path is selected or executed here.
- Restore historical `final_only`: rejected. It requires a separately accepted
  public contract, not an adapter-side reasoning-discard shortcut.
- Treat this as Linux Node qualification: rejected. ADR 0035 and M9 require
  separate lifecycle, trust, targeting and qualification evidence.

Deterministic implementation evidence can protect the seam without activating a
GPU, downloading a model or asserting current real API/OpenCode success.

The remaining live risk is exact `prompt_tokens == request.input_tokens`
validation: it may fail if Controller and vLLM tokenization diverge. This is not
current live evidence or permission to change the tokenizer contract.

## SPEC.md impact

No SPEC.md amendment is required. This default-off source-development experiment
uses the existing local Worker seam without changing Controller admission,
public APIs, or the requirements of §4.10. The support and qualification
boundaries in §1.4, §1.5, §7.2.9, Milestone 9, and ADR 0035 remain unchanged.
This decision grants no live execution authorization.
