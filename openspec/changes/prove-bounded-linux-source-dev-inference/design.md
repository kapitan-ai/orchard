## Context and scope

ADR 0037 records the historical reference and source-development boundary. No
SPEC.md amendment is required. This experiment is independent of ADR 0035's
Linux Node candidate; it supplies no platform, production trust, lifecycle or
M9 qualification evidence. Historical vLLM 0.27.1 image/model identities remain
immutable reference metadata, not current support or authorization.

## Worker boundary

Selection is explicit and default-off. Existing local gRPC remains the Worker
surface; only the adapter calls loopback HTTP `/v1/completions` on port 58080.
Load/unload is logical and concurrency is one. No Controller/shared request or
tokenizer registration changes are needed. The Worker consumes already rendered
prompt bytes for framing, sends authoritative prompt IDs when supplied and the
rendered string otherwise, and rejects token-ID output/logprobs and unsupported
controls. It accepts `<think>\n` or `<think>\n\n</think>\n\n` at the prompt end,
requires temperature `1.0`/top-p `0.95`, and pins top-k
`20`, min-p `0`, presence penalty `0` and repetition penalty `1`.

The closed-empty-think suffix is the disabled branch of the source-owned Qwen
effort template fixture. The tokenizer effort registry still enables thinking;
this adapter does not advertise a disabled effort mapping or negotiated mode.
vLLM 0.27.1 accepts nonnegative flat integer prompt lists. Require ID count equal
to `input_tokens`, retain strict provider usage equality and reject other framing.

Each attempt owns a socket and random provider request ID; response IDs, when
present, must match. No shared stream or cross-request cancellation is introduced.

N-slot admission and a matching supervisor change are deferred. `SPEC.md` §7.5.3
requires stream-mode Node and placement concurrency one, and the Node forwards
positive Worker capacity without clamping it. Keep the existing single-slot gate
and `--max-num-seqs 1`; a provider-independent stream-concurrency amendment needs
separate approval. This slice does not change SPEC.md.

## Stateful output framing

Start inside the prompt-opened reasoning frame. Preserve generated reasoning
bytes as legacy-blended text under KAP-49 while tracking the streamed closing
marker across arbitrary chunk boundaries. Only an unambiguous final suffix is
eligible for tool parsing; tool-like bytes inside reasoning are never calls.
This is not negotiated-mode fail-closed reasoning validation or a `final_only`
projection. Raw `legacy_blended` output passes through when thinking ends at
length or reasoning framing is malformed. If framing cannot identify an
unambiguous suffix, preserve raw output without parsing tools for auto/none;
required/named choices fail with `tool_choice_not_satisfied`. For the recognized
disabled prompt, tool parsing starts at output offset zero.

Stream reasoning/raw text immediately. After the reasoning close, retain only
the minimal possible tool-marker suffix; release it when continuation rules it
out. A complete tool control marker withholds subsequent output until terminal
validation. Preserve the same raw bytes if later reasoning markers invalidate
framing. Terminal delivery excludes already-emitted text. First-token timing
uses the existing first public legacy-text delta boundary, with no new schema.

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

String-fallback `prompt_tokens == request.input_tokens` validation may fail if
Controller and vLLM tokenization diverge. Authoritative IDs avoid retokenization,
not the strict check or the requirement for separately approved live evidence.

## Cessation evidence limitation

Disconnect remains the cancel mechanism. Pinned vLLM's aggregate running/waiting
gauges can predate admission and have no request-scoped freshness barrier or
execution fence. The disconnect-abort path removes frontend state without
incrementing the abort success counter. ADR 0037 cites the inspected v0.27.1
source. Do not add a fake affirmative receipt unsupported by that source.
Report `cancel accepted; native cessation unconfirmed` in the cancelled terminal
and cancellation cleanup telemetry; other premature-stream cleanup also reports
unconfirmed cessation. Keep local reader settlement bounded at two seconds.
Only an unsettled reader sets the sticky unhealthy latch and denies admission,
including after logical reload. Settled disconnect cleanup permits reuse without
a provider-wide abort. Cancel acceptance is not native cessation, and reader exit
is not capacity release.

The accepted slice-2 policy assumes exclusive provider ownership, Worker
concurrency one and supervisor `--max-num-seqs 1`. vLLM queues the next request
while the prior request occupies its scheduled slot and owns the execution and
block-reuse fences for outstanding aborted work. The accepted residual risk is
next-request latency, not output corruption or unsafe memory overlap. This is
not a live native-safety qualification or new Controller capacity authority.

Confirmed polling remains blocked. Slice 3 must revisit a provider-side receipt
before concurrency above one, through a suitable newer vLLM, request-scoped abort
acknowledgment and execution fence, or separately accepted engine-incarnation
evidence. There is no provider pin change, fabricated confirmation or live claim
here.

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
