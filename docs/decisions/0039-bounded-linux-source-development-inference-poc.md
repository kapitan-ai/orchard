# ADR: Bound Linux source-development inference to one disposable proof of concept

## Status

Accepted for adapter/setup source implementation under KAP-112 by the Repository
Owner on 2026-09-21 at exact contract commit
`23395a3b06b144f76b1a11397c3d7ebe23c114b0`. The remaining Repository Owner gate
must accept the exact clean implementation commit/tree and executable mutation
plan before model download, provider activation, GPU use, live database setup,
or inference.

The Repository Owner separately authorized source-only implementation of the
deterministic smoke runner and frozen fixture unit on 2026-09-21. That
authorization does not satisfy the remaining mutation gate. The runner must
first derive and receipt the exact 131,072/131,073-token adjacent fixtures
offline through the pinned OpenCode request shape and snapshot tokenizer while
all proof service ports remain clear; live execution must reproduce those
identities rather than accept an operator-supplied token count.

The runner binds `tokenizer.json`, `tokenizer_config.json`, and
`chat_template.jinja` hashes into that receipt and recounts both adjacent
fixtures before live Orchard startup. It pins the installed OpenCode 1.18.31
binary and dependency-tree identities and supplies disposable provider/config,
data, state, cache and workspace paths so the proof does not mutate persistent
OpenCode configuration. OpenCode otherwise runs as the ordinary installed host
client; the proof does not sandbox, enumerate or authorize its client-side tool
surface. Typed event evidence proves that OpenCode consumed Orchard's API and
received terminal assistant output, usage, finish and structured tool protocol
data. An owned loopback API compatibility proxy measures client requests and
exact refusal status, type and code; a durable Request-count delta measures
persistence without claiming that transient dispatch absence has been
established.

On 2026-09-22 the Repository Owner authorized one final corrected experiment
from source commit `b0991cb8ade8dc0c6130f89ee1e2183a6925ed6e` and tree
`7d6eefa2c0713ca9aac466c4a0e74ba780dfb09c`. Prior live evidence showed that an
omitted reasoning policy let the immutable template select its `xhigh` default.
The correction changes only that axis: the exact artifact is registered at
runtime for explicit `enabled + final_only + medium` reasoning, and every proof
request selects it. Missing, mismatched, or defaulted registration stops the
proof. All other tuple elements, prompts, limits, deadlines, and cleanup remain
unchanged, and no further live retry is authorized.

The Repository Owner later clarified the proof boundary: OpenCode is the
external client under test, not a workload Orchard confines. The POC therefore
runs the pinned installed client normally from the disposable proof workspace
and judges Orchard API/protocol compatibility plus the independently checked
workspace outcome. OpenCode may choose any installed client-side tool or command;
those choices are neither enumerated nor treated as Orchard acceptance evidence.
Controller, Node, Worker and provider processes remain tool-neutral. This source
correction does not itself authorize another live attempt.

The next owner-authorized live attempt reached successful direct, short-client
stream and 131,072-token long-context assertions, then stopped before overflow
because Ecto debug logging preceded the untagged durable Request count on
stdout. The owner authorized source-only correction of that evidence boundary:
durable counts use one exact tagged non-negative integer, and each stage writes
an atomic mode-0600 closed-field receipt containing typed timing, usage, route,
tool-protocol and outcome evidence or only a failure type/hash/length. Receipt
files never contain prompts, model output, tool input/output, file content,
credentials or sensitive paths and survive runner-state cleanup for private
evidence capture. This is not authorization for another live attempt.

## Context

KAP-110 established an unsupported, unqualified Ubuntu 24.04 source-development
workflow on `kapitan`, but its accepted smoke is deliberately model-free. The
near-term question is narrower than Linux provider qualification: can real API
and OpenCode requests traverse Orchard's API, scheduler, Runtime Endpoint, and
Worker Runtime boundaries and return generated text or bounded client-side tool
use on this host?

The host has four idle NVIDIA H100 NVL devices. The accepted provider-neutral
Worker Runtime is local gRPC over an owner-only Unix socket, while vLLM exposes
an HTTP service. Orchard's current worker executable accepts only `mlx` and
`stub`. A small development-only adapter is therefore required; direct calls
from the Controller to vLLM would bypass the path being tested.

KAP-18, KAP-26, and KAP-85 remain production gates for native cessation,
request-slot and Resource Allocation release, durable Worker identity, and
runtime qualification. This proof cannot settle or weaken them.

## Decision

Propose exactly this immutable proof-of-concept tuple:

- host: Ubuntu 24.04.4 LTS x86_64 on `kapitan`, kernel 6.8.0-139;
- accelerator: only the owner-approved `ORCHARD_KAP112_GPU_UUID`, an NVIDIA H100
  NVL with 95,830 MiB, compute capability 9.0, driver 580.173.02;
- runtime: cached image
  `vllm/vllm-openai:v0.27.1@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`,
  image ID
  `sha256:e0cfcfcb9b86e2c2d0d52a93689773f20f380cb8e050a24ce550c44f6f55c5eb`,
  build commit `6e448d0ea9bf3d88d898b65449ca6dc2aec170ac`, Apache-2.0;
- model, tokenizer, processor, and template: `Qwen/Qwen3.8-27B`, Apache-2.0,
  exact revision `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, selected snapshot
  55,586,114,863 bytes, with 18 BF16 safetensor shards and native 262,144-token
  context; and
- execution scope: text-only, concurrency one, BF16 weights and KV cache,
  native context only, no YaRN, quantization, speculative decoding, multimodal
  input, alternate tokenizer, adapter weights, or sibling model.

Tokenizer, processor, template, config, index, and shard provenance all come
from that immutable revision. Before execution, the proof SHALL obtain the
complete Hub manifest and verify every local file against immutable Hub/Xet/LFS
metadata; the repository byte total is provenance metadata, not a substitute
for the local manifest. The snapshot's own chat template is authoritative. No
floating branch, remote code, alternate tokenizer, quantization, adapter, or
sibling model is allowed.

The prior 55,615,875,685-byte figure was the Hub `used_storage` field, not the
selected revision's file sum. It consists of 55,575,816,096 bytes of selected
LFS objects plus a 40,059,589-byte `R.Basca_Tr2.geojson` LFS object reachable
only from pull-request refs 117 and 118. The selected revision additionally has
10,298,767 bytes of ordinary Git objects. Therefore
55,575,816,096 + 10,298,767 = 55,586,114,863 selected bytes, and
40,059,589 - 10,298,767 = the exact 29,760,822-byte overstatement. The canonical
32-file path/size/blob/LFS/ETag manifest is
`scripts/fixtures/kap112/qwen-snapshot-manifest.json`.
The immutable download container runs as the invoking numeric UID:GID, and the
handoff fails unless both the snapshot and mode-0600 evidence remain owned and
readable by that identity. Its Hub/Xet cache is confined to the same owner-only
proof root rather than the image user's default home.
Offline OpenCode calibration applies the same bounded `input_text` to `text`
normalization as the Responses API before invoking the exact tokenizer and
rejects every unsupported content-part shape.
The long and adjacent-overflow messages are supplied through OpenCode stdin so
the complete frozen context reaches the API request without file-tool display
truncation; the exact captured request is passed to the tokenizer over stdin
and recounted before live execution, avoiding host argument-size truncation.

The smallest adapter adds a development-only `vllm_poc` backend to the existing
Python Worker Runtime service. It preserves the Node Agent-owned Unix-socket
gRPC surface and translates `LoadModel`, `GetStatus`, `Generate`, `Cancel`, and
`UnloadModel` to one loopback vLLM server. `Generate` sends Orchard's rendered
prompt to vLLM's OpenAI-compatible completions endpoint and maps streamed text,
usage, finish, and error events back to the provider-neutral protocol. It does
not move rendering or scheduling into vLLM.

Legacy completions does not apply vLLM's Chat Completions tool or reasoning
parsers. The development adapter therefore owns one exact, artifact-bound raw
Qwen3.8 stream parser. The pinned template opens `<think>` in the rendered
prompt, so the parser starts inside reasoning, discards content through the
matching streamed `</think>` without retaining it, validates and normalizes
complete Qwen XML tool blocks into `ToolCallDelta` events, emits only final
answer text as `OutputTextDelta`, and fails closed on malformed, partial,
unrequested, unknown, or parser-ambiguous output. Parser identity and version
are recorded in evidence. Deterministic fake-provider tests SHALL split every
streamed control marker across stream boundaries and cover malformed and
truncated calls. This proof-only parser is not a qualified provider parser or
permission to weaken the production contract.

The owner-authorized mixed-output amendment permits exactly one additional
post-reasoning shape: a nonempty public-text prefix followed by one or more
complete, structurally valid, requested Qwen XML tool blocks. The adapter
preserves the prefix byte-for-byte as public assistant text and emits the blocks
as typed tool calls in order. Only whitespace may separate blocks or follow the
final block. Text between or after blocks remains ambiguous and fails closed,
as do malformed markers, unknown tools, structurally invalid or duplicate
arguments and every existing reasoning-policy failure. This rule neither drops
narration nor reclassifies it as hidden reasoning, and it remains proof-only
rather than a provider support or qualification decision. It does not add JSON
Schema validation of model-selected argument values.

Each request explicitly selects the proof-only `medium` policy. The disposable
setup writes a mode-0600, proof-root-contained registration bound to the imported
artifact digest and exact chat-template digest. Orchard resolves only that
registration to `enable_thinking = true` and `reasoning_effort = medium`; absent,
altered, implicit, and `xhigh` paths fail closed before dispatch. The adapter
uses the official thinking sampler: temperature `1.0`, top-p `0.95`, top-k `20`,
min-p `0`, presence penalty `0`, and repetition penalty `1`. The runner records
the requested controls, effective registration, sampler, and registration hash.
This is an exact POC registration, not a production tuple or general public
reasoning contract.

A bounded wrapper, not the Node Agent, starts and stops the vLLM container. That
is an explicit proof-only custody shortcut. The adapter's unload is logical,
closing a cancelled HTTP stream is not evidence of native cessation, and
stopping the container after the request is not evidence of request-slot or
capacity release. None of those observations may update production authority.
The wrapper creates the owned container before attachment, captures bounded
startup output privately, and fails immediately with that output if the
provider exits before readiness instead of waiting out the readiness deadline.

Use the accepted disposable PostgreSQL helper on loopback port 55432, Orchard
HTTP on 4000, local Node compatibility gRPC on 50071, and vLLM HTTP on
`127.0.0.1:58080`. The adapter remains on an owner-only Unix socket. The vLLM
container receives only the named GPU and a read-only verified model snapshot,
runs with concurrency one, `--dtype bfloat16`, `--max-model-len 139264`, and a
`--gpu-memory-utilization 0.80` configuration target (approximately 76,664 MiB
of the device's reported memory). This is a vLLM allocation target, not a hard
GPU-process memory ceiling; record observed peak device memory and stop if the
provider cannot start at that target. The expected incremental model download
is 55,586,114,863 bytes; the 21,417,065,539-byte runtime image is already
cached. Allow 8 GiB of temporary disk beyond the snapshot and 64 GiB host RAM
for the provider process and loading path. A need to raise any configured bound
stops the proof rather than broadening it.

The provider invocation SHALL be equivalent to `docker run --pull=never --rm`
with the exact image, `--network host`, only the selected GPU, private 1 GiB
shared memory, and the verified snapshot mounted read-only at `/model`. vLLM
SHALL use `/model`, served name `orchard-qwen3.8-27b-poc`, host `127.0.0.1`,
port 58080, BF16, maximum model length 139,264, maximum one sequence, GPU-memory
utilization 0.80, and default-disabled remote code. Tagged vLLM 0.27.1 source
registers the Qwen3.8 architecture and requires Transformers 5.10.4 or newer,
but the cached image SHALL still report its actual installed identities before
model download. Missing architecture or completions support is a stop
condition, not permission to install into or replace the image. No
Docker-published or bridge-reachable provider port is permitted.
The pinned vLLM build defaults `enable_log_requests` to false; the wrapper does
not pass the removed `--disable-log-requests` flag.

The disposable database may contain one explicitly development-only unmanaged
Runtime Endpoint target, tenant, API credential, active model and access grant.
They must be created by a narrow repeatable setup path, must not enroll or admit
a production Node, and disappear with the database. Success requires one exact
frozen marker response using the artifact-bound medium policy and official
thinking sampler with a 128-token output limit through `POST /v1/responses`,
terminal request status,
exact model identity, latency, token/usage data where existing surfaces provide
it, Worker execution events, and corresponding Console visibility. The exact
marker is fixture-conformance evidence only; output quality and performance are
not acceptance criteria.

The proof also uses an exact OpenCode client identity with sharing, auto-update,
prompt-cache-key emission, and every external-provider fallback disabled so the
observed model requests target Orchard. Offline request capture SHALL reject the
cache-key field before live execution. Client config, data, state, cache and the
fixture repository are proof-owned and disposable cleanup surfaces, not a
client sandbox. OpenCode runs as the normal installed host client. Its tools
execute client-side, never in Controller, Node, Worker or provider processes.
The proof-only loopback proxy SHALL translate only OpenCode 1.18.31's exact
flattened Responses function-tool objects into Orchard's canonical nested
function-tool shape, apply the same translation before offline token counting,
record every translated request, and fail on any schema drift. This does not
expand Orchard's public API contract. Because pinned OpenCode 1.18.31 omits
reasoning and sampling controls, the proof-only proxy SHALL require that omission
and add exactly `reasoning: {effort: medium}`, `temperature: 1.0`, and
`top_p: 0.95` during both offline capture and live forwarding. The exact adapter
supplies the remaining official sampler fields. Any implicit template default,
including `xhigh`, is a hard failure.
Because Orchard's accepted streaming contract intentionally carries assembled
function calls only in its terminal event, the proof proxy SHALL synthesize the
pinned OpenCode client's exact `response.output_item.added` and
`response.output_item.done` compatibility events from completed terminal
function-call items. It SHALL preserve Orchard's terminal event, count every
synthesized call, and fail closed on response drift. This proof-only translation
SHALL also assign one proof-local message identity, surround Orchard text deltas
with the pinned client's message-item events, and translate `response_id` to the
required `item_id`. Proof-local function identities SHALL be unique per response.
On later turns, the proxy SHALL correlate those exact identities and flatten each
function-call/result block into proof-only role-bearing text messages because
Orchard does not accept Responses tool-history input items. It does not change
Orchard's streaming or input API contracts. Correlation SHALL compare decoded
JSON argument values without conflating booleans and numbers, accept the pinned
client's call-block/result-block ordering, and prove that every synthesized call
identity had a result forwarded at least once. Each block SHALL reproduce the
pinned Qwen chat template's assistant `<tool_call>` transcript followed by its
user `<tool_response>` envelope so the provider retains multi-step tool semantics
rather than interpreting a tool result as a new ordinary user request.
One short smoke SHALL run the pinned installed OpenCode client against Orchard
from a frozen disposable repository fixture. OpenCode may use its installed
client-side tools and choose its own commands and order. Acceptance SHALL depend
on Orchard request/stream/tool-call/result evidence, a nonempty terminal answer,
the exact repaired fixture diff, protected-file hashes, edit scope and an
independent passing test—not an expected action transcript or tool allowlist.

A separate OpenCode long-context smoke SHALL exercise at least 131,072 actual
rendered input tokens while reserving 8,192 output tokens, requiring 139,264
total capacity. Instructions, tool schemas, messages, history, tool results,
and repository context all count. The frozen fixture SHALL test multi-position
retrieval, a later instruction overriding an earlier conflict, distant code
dependencies, and tool-result continuity. Record configured and effective
capacity, actual provider-tokenizer rendered input, requested and effective
output limits, compaction, overflow, exact provider/parser mode, latency, usage,
and peak resources. An over-window input SHALL fail before generation without
silent truncation. The short smoke need not fill the window, and neither smoke
constitutes OpenCode or coding-agent qualification.

Each smoke has one initial attempt and zero automatic provider/model retries.
The direct API and overflow probes each have a ten-minute wall-clock limit. The
short OpenCode smoke has at most 20 model turns, 20 tool calls, 60 seconds per
tool command, and 30 minutes wall clock. The long-context smoke has at most
eight model turns, eight tool calls, 60 seconds per tool command, and 60 minutes
wall clock. Any bound exhaustion fails that smoke and enters cleanup; it does
not continue, retry, compact past the measured gate, or broaden the limit.

The run stops before mutation on source, image, model, tokenizer, GPU, driver,
port, listener, or pre-state drift; a busy selected GPU; external exposure;
insufficient disk or memory; an unreviewed dependency or privilege request; or
any requirement for production admission, Peer Grants, systemd, cgroups, or
host-service mutation. During execution it stops on hash mismatch, unexpected
authority/capacity publication, path bypass, cleanup uncertainty, or a need to
raise a declared resource bound.

Cleanup gracefully stops Orchard and the adapter, removes the auto-removing
vLLM and PostgreSQL containers, deletes the verified model snapshot and only
newly created credentials and temporary state, and proves ports, sockets,
containers, volumes, selected-GPU processes, and Git state returned to their
recorded baseline. Model download uses an owner-only proof-specific Hugging Face
home/cache; partial blobs and cache metadata are proof-owned and removed too.
If cleanup cannot be proved, retain only secret-redacted diagnostics needed to
classify the residue and report the proof incomplete.

## Consequences

Passing proves viability of one exact developer experiment only. It does not
qualify Linux, CUDA, H100, vLLM, Qwen, the Worker provider, cancellation,
capacity release, security, reliability, performance, KAP-103, KAP-105,
packaging, support, or any production topology.

After contract acceptance, implementation is limited to the thin adapter,
deterministic tests using a fake loopback vLLM service, and disposable
setup/cleanup wiring. The completed implementation commit/tree, exact commands,
pre-state plan, and unchanged tuple return for the second owner gate before any
download or run. Any tuple or bound change returns to contract review.

The model provenance is published at
<https://huggingface.co/Qwen/Qwen3.8-27B/tree/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0>.
The vLLM Qwen3.8 recipe documents vLLM 0.17.0 or newer, Transformers 5.8.0 or
newer, native 262,144 context, and Qwen3 reasoning/tool parsers at
<https://recipes.vllm.ai/Qwen/Qwen3.8-27B>.

## SPEC.md impact

Clarify §1.4 so a separately authorized disposable inference proof may extend
the model-free KAP-110 workflow without changing its unsupported, unqualified
status or any production authority boundary.
