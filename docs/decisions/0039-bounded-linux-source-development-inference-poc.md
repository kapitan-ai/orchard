# ADR: Bound Linux source-development inference to one disposable proof of concept

## Status

Proposed under KAP-112. Two explicit Repository Owner gates remain: acceptance
of this contract before implementation, then acceptance of the exact clean
implementation commit/tree and executable mutation plan before model download,
provider activation, or inference.

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
  exact revision `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, repository storage
  55,615,875,685 bytes, with 18 BF16 safetensor shards and native 262,144-token
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

The smallest adapter adds a development-only `vllm_poc` backend to the existing
Python Worker Runtime service. It preserves the Node Agent-owned Unix-socket
gRPC surface and translates `LoadModel`, `GetStatus`, `Generate`, `Cancel`, and
`UnloadModel` to one loopback vLLM server. `Generate` sends Orchard's rendered
prompt to vLLM's OpenAI-compatible completions endpoint and maps streamed text,
usage, finish, and error events back to the provider-neutral protocol. It does
not move rendering or scheduling into vLLM.

Legacy completions does not apply vLLM's Chat Completions tool or reasoning
parsers. The development adapter therefore owns one exact, artifact-bound raw
Qwen3.8 stream parser: it discards bounded `<think>...</think>` content without
retaining it, validates and normalizes complete Qwen XML tool blocks into
`ToolCallDelta` events, emits only final answer text as `OutputTextDelta`, and
fails closed on malformed, partial, unrequested, unknown, or parser-ambiguous
output. Parser identity and version are recorded in evidence. Deterministic
fake-provider tests SHALL split every control marker across stream boundaries
and cover malformed and truncated calls. This proof-only parser is not a
qualified provider parser or permission to weaken the production contract.

The request preserves Orchard's omitted `model_default` generation policy and
the exact snapshot template's default rendering. It does not inject
`enable_thinking`, add an arbitrary template keyword, or invoke an explicit
reasoning mode on the unmanaged target. Content-discarding adapter parsing is a
declared POC compatibility shortcut, not a new rendering or reasoning contract.

A bounded wrapper, not the Node Agent, starts and stops the vLLM container. That
is an explicit proof-only custody shortcut. The adapter's unload is logical,
closing a cancelled HTTP stream is not evidence of native cessation, and
stopping the container after the request is not evidence of request-slot or
capacity release. None of those observations may update production authority.

Use the accepted disposable PostgreSQL helper on loopback port 55432, Orchard
HTTP on 4000, local Node compatibility gRPC on 50071, and vLLM HTTP on
`127.0.0.1:58080`. The adapter remains on an owner-only Unix socket. The vLLM
container receives only the named GPU and a read-only verified model snapshot,
runs with concurrency one, `--dtype bfloat16`, `--max-model-len 139264`, and a
`--gpu-memory-utilization 0.80` configuration target (approximately 76,664 MiB
of the device's reported memory). This is a vLLM allocation target, not a hard
GPU-process memory ceiling; record observed peak device memory and stop if the
provider cannot start at that target. The expected incremental model download
is 55,615,875,685 bytes; the 21,417,065,539-byte runtime image is already
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

The disposable database may contain one explicitly development-only unmanaged
Runtime Endpoint target, tenant, API credential, active model and access grant.
They must be created by a narrow repeatable setup path, must not enroll or admit
a production Node, and disappear with the database. Success requires one
non-empty response to a deterministic, temperature-zero request through
`POST /v1/responses`, terminal request status, exact model identity, latency,
token/usage data where existing surfaces provide it, Worker execution events,
and corresponding Console visibility. Output quality and performance are not
acceptance criteria.

The proof also uses an exact isolated OpenCode client identity with sharing,
auto-update, and every external-provider fallback disabled. All client config,
data, state, cache, and fixture repositories are proof-owned and disposable;
tools execute in OpenCode, never in the provider. One short smoke SHALL inspect
a frozen repository fixture, reproduce a baseline failure, use genuine
structured tool calls through Orchard, edit only allowed implementation files,
run tests, inspect its diff, and summarize. Independent checks SHALL verify the
result, protected-file hashes, and edit scope. A denied tool action SHALL make
no change and an approved action SHALL execute.

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
