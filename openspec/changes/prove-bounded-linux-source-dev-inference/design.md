## Context and scope

ADR 0037 records the historical reference and exact SPEC impact. This experiment
is independent of ADR 0035's Linux Node candidate; it supplies no platform,
production trust, lifecycle or M9 qualification evidence. Historical vLLM
0.27.1 image/model identities remain immutable reference metadata, not current
support or authorization.

## Worker boundary

Selection is explicit and default-off. Existing local gRPC remains the Worker
surface; only the adapter calls loopback HTTP `/v1/completions` on port 58080.
Load/unload is logical and concurrency is one. No Controller/shared request or
tokenizer registration changes are needed. The Worker consumes already rendered
prompt bytes, rejects token IDs/logprobs and unsupported controls, requires
`<think>\n` at the prompt end and temperature `1.0`/top-p `0.95`, and pins top-k
`20`, min-p `0`, presence penalty `0` and repetition penalty `1`.

## Stateful output framing

Start inside the prompt-opened reasoning frame. Preserve generated reasoning
bytes as legacy-blended text under KAP-49 while tracking the streamed closing
marker across arbitrary chunk boundaries. Only an unambiguous final suffix is
eligible for tool parsing; tool-like bytes inside reasoning are never calls.
This is not negotiated-mode fail-closed reasoning validation or a `final_only`
projection. Raw `legacy_blended` output passes through when thinking ends at
length or reasoning framing is malformed. If framing cannot identify an
unambiguous suffix, preserve raw output without parsing tools.

Allow exact text followed by complete requested Qwen XML calls in source order.
Only whitespace may separate or follow calls. In the identified suffix, fail
closed on complete or ambiguous tool syntax, including malformed,
unknown/unrequested calls, duplicate arguments and interleaved/trailing text.
Truncated marker prefixes fail closed only at length; at clean stop they remain
ordinary text. Tool identities are UUIDs under KAP-116.

Parameter decoding reads `tool.parameters.properties[name].type`: `string`
retains raw text; `number`, `integer`, `boolean`, `object`, `array` and `null`
require JSON parsing and matching types. Absent or unknown types use vLLM qwen3
JSON-or-trimmed-text semantics. Non-finite values and numeric parse failures are
`tool_call_parse_failed`. This does not add general JSON Schema validation.
Total decoded-output bounds remain, including reasoning and framing; raw
pass-through never discards bytes to fit the bound. Fake-provider tests must
exercise chunk splits, ambiguity, stop/length distinctions, parameter decoding,
limits, cancellation and logical status without real inference.

## Live risk

Exact `prompt_tokens == request.input_tokens` validation may fail if Controller
and vLLM tokenization diverge. This remains a live risk, not current live proof
or a reason to widen the shared request or tokenizer contract.

## Historical fixture incompatibility and gates

The historical bundle's effort artifact digest differs from main's source-owned
registry; the old registration environment variable is not consumed. Historical
setup is disabled, and smoke-runner `main`/`execute` fail before mutation. Keep
only deterministic scripts/tests; there is no current real API/OpenCode proof.

Future work may rebuild the exact qualified fixture for KAP-49 with new reviewed
provenance under current registration, or separately accept a new artifact
profile. Final-only needs its own accepted public contract. Neither option may
silently revive historical permissions or bypass execution guards.

The supervisor requires `ORCHARD_KAP112_GPU_UUID` and
`ORCHARD_KAP112_SNAPSHOT_ROOT`. Live supervisor/download has not run for this
port and requires separate owner approval of exact source and mutation/cleanup
plan. Future evidence must bind a clean source commit/tree, locks, tuple,
render/count identities and bounds, stop on drift, and restore proof-owned
baseline without touching unrelated state. Provider wrapper custody, HTTP
closure and logical unload are not native cessation or resource release.
OpenCode remains an external tool-owning client; historical compatibility
translations do not expand Orchard's public API.
