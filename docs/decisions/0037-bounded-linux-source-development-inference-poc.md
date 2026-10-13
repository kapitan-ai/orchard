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

Accept rendered prompt suffix `<think>\n` or the exact thinking-disabled suffix
`<think>\n\n</think>\n\n`, and require sampling temperature `1.0`
and top-p `0.95`; the pinned remaining sampler is top-k `20`, min-p `0`, presence
penalty `0`, repetition penalty `1`. Reject token-ID output and logprobs rather
than approximating them. When authoritative `prompt_token_ids` are present,
send that flat integer list as `prompt`; require nonnegative IDs and a length
equal to `input_tokens`. Use the rendered string only when IDs are absent.
Keep the exact provider usage equality check for both paths. vLLM 0.27.1's
[CompletionRequest schema](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/entrypoints/openai/completion/protocol.py)
accepts a flat list of nonnegative integers and a caller-supplied `request_id`.
Bound total decoded output, including reasoning, not just the final suffix.

The disabled suffix comes from the registered Qwen template fixture at
`apps/orchard_controller/test/fixtures/tokenizer/qwen3_8_effort/chat_template.jinja`.
The tokenizer's `effort_profiles.json` currently registers only enabled thinking;
accepting these already-rendered legacy bytes does not advertise a disabled
effort mapping or negotiated reasoning capability. For this suffix, the whole
generated output is eligible for tool parsing unless generated reasoning markers
make framing ambiguous. Reject all other prompt suffixes.

Preserve generated reasoning bytes as legacy-blended text under main KAP-49.
Stateful framing begins inside the prompt-opened reasoning frame and identifies
an unambiguous final suffix after its matching streamed close. Framing is only a
tool-parsing locator, not negotiated-mode fail-closed reasoning validation or a
`final_only` projection. Raw `legacy_blended` output passes through even when
thinking ends at length or reasoning framing is malformed; without an
unambiguous final suffix, do not parse tools. A required or named tool choice
instead fails with `tool_choice_not_satisfied`; raw bytes cannot satisfy it.
Parse Qwen XML tools only in that
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

Emit reasoning/raw deltas immediately. After the reasoning close, retain only
the suffix that could begin a tool control marker until it resolves. Once a
complete control marker appears, retain its output until terminal parsing and
validation; do not leak tool blocks as ordinary text. Preserve raw passthrough
if later reasoning framing becomes malformed. Terminal parsing emits only text
not already delivered and complete tool calls. The Controller's existing
`first_token_at` therefore follows the first emitted legacy text delta, not the
provider's terminal. No Worker timing or public event schema is added.

Tool structure uses monotonic delimiter scanning, not backtracking regexes.
HTTP identity checks have a wall-clock deadline. Cancellation shuts down the
retained transport socket even when the response owns it; an unsettled reader
makes the Worker unhealthy and blocks further local admission until replacement.
Each attempt has its own transport and random provider request ID. Validate
response IDs when supplied. Cancellation closes only that request's socket.

### Concurrency above one is deferred

`SPEC.md` §7.5.3 requires stream generation mode to report concurrency one at
both Node and placement levels. The Node consumes a positive Worker capacity
without a stream-mode clamp. Advertising N slots here would therefore change
that contract. Retain the single-slot gate and supervisor `--max-num-seqs 1`.
The options are to defer N-slot admission or separately approve a SPEC amendment
for provider-independent stream concurrency, followed by implementation and
qualification. This slice selects deferral and does not change SPEC.md.

### Native cessation remains unconfirmed

vLLM disconnect cancellation sends an asynchronous engine abort, not an
engine-origin cessation receipt. Read-only inspection of pinned v0.27.1 found:

- [async_llm.py:608-616](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/engine/async_llm.py#L608-L616)
  catches disconnect cancellation; [729-738](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/engine/async_llm.py#L729-L738)
  removes frontend state before sending the EngineCore abort.
- [output_processor.py:494-515](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/engine/output_processor.py#L494-L515)
  emits a local ABORT output without finished-request statistics;
  [619-629](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/engine/output_processor.py#L619-L629)
  ignores subsequent outputs for removed requests.
  [core.py:485-491](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/engine/core.py#L485-L491)
  removes the scheduler request without an ABORT completion receipt. This path
  does not increment `vllm:request_success_total{finished_reason="abort"}`.
- [loggers.py:1108-1122](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/metrics/loggers.py#L1108-L1122)
  updates running/waiting gauges before finished counters at
  [1221-1224](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/metrics/loggers.py#L1221-L1224).
  [core.py:591-594](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/engine/core.py#L591-L594)
  returns without stats when idle. Scraping does not refresh the scheduler:
  zero can predate admission, and no exported update sequence proves freshness.
- [/metrics exposure:56-82](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/entrypoints/serve/instrumentator/metrics.py#L56-L82)
  serves the registry. [loggers.py:468-474](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/metrics/loggers.py#L468-L474)
  labels metrics by served `model_name` and `engine`, not request identity.
  [scheduler.py:2341-2380](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/v1/core/sched/scheduler.py#L2341-L2380)
  separately fences block reuse while native writes remain outstanding. Queue
  counts cannot establish that this execution fence has settled.

Do not implement an affirmative confirmation path using these metrics. The
cancelled terminal retains code `cancelled` and reports `cancel accepted; native
cessation unconfirmed` in its message. Cancellation cleanup logs the same outcome
with the adapter-owned request ID; other premature stream closure logs disconnect
propagation with native cessation unconfirmed. No provider-wide abort is sent.

Najib's accepted slice-2 decision restores admission once the request-owned
socket closes and its reader settles within the existing two-second bound.
Unconfirmed native cessation alone does not make the Worker unhealthy. A reader
that fails to settle still sets the sticky `provider_reader_unsettled` latch,
denying admission even after logical unload/reload until Worker replacement.

This decision assumes exclusive ownership of the supervisor's vLLM instance,
Worker concurrency one, and `--max-num-seqs 1`. A new request waits in vLLM while
the old request occupies the scheduled slot rather than running as a second
sequence. Outstanding aborted GPU work remains subject to vLLM's execution and
block-reuse fences, not an Orchard inference from reader exit. The accepted
residual risk is additional next-request latency, not output corruption or
unsafe memory overlap. Request-owned transports and response IDs remain separate.
This is a local reuse policy, not evidence of native cessation, request-slot
release or resource release, and supplies no new Controller capacity authority.

Confirmed provider polling remains blocked. Slice 3 must revisit cessation with
a provider-side receipt before concurrency above one: a newer vLLM with suitable
evidence, a request-scoped engine-origin abort acknowledgment and execution fence,
or engine-incarnation evidence under a separately accepted lifecycle contract.
Changing the pin or claiming confirmation from aggregate metrics is not part of
this slice. No live execution or native safety qualification is claimed here.

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

The string fallback retains the live risk of Controller/provider tokenization
divergence. Authoritative IDs avoid provider retokenization, but do not establish
live compatibility, tokenizer registration authority or a new supported tuple.

## SPEC.md impact

No SPEC.md amendment is required. This default-off source-development experiment
uses the existing local Worker seam without changing Controller admission,
public APIs, or the requirements of §4.10. The support and qualification
boundaries in §1.4, §1.5, §7.2.9, Milestone 9, and ADR 0035 remain unchanged.
This decision grants no live execution authorization.
