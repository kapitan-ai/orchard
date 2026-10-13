## ADDED Requirements

### Requirement: Linux Source-development Inference POC Uses One Immutable Tuple

After contract acceptance and implementation, the proof SHALL use only the
exact clean implementation commit/tree separately accepted by the owner before
execution, the owner-approved NVIDIA device from required `ORCHARD_KAP112_GPU_UUID`, vLLM image
digest `sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`,
and `Qwen/Qwen3.8-27B` revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, comprising the immutable
55,586,114,863-byte, 32-file selected snapshot and its 18 BF16 weight shards. Every
tuple component and every downloaded file SHALL be verified against immutable
Hub path, size, blob identity, LFS SHA-256, and ETag metadata before activation.
Repository-level `used_storage` SHALL NOT substitute for the selected revision's
file sum. Drift SHALL stop the proof and SHALL NOT select an alternative.

#### Scenario: Tuple identity differs

- **WHEN** source, GPU, driver, image, model, tokenizer, or weight identity differs from the approved tuple
- **THEN** no provider or model is activated
- **AND** a new owner decision is required

### Requirement: The POC Preserves Orchard's Scheduling And Runtime Path

The proof SHALL submit one authenticated request to Orchard's canonical
`/v1/responses` API and route it through the existing scheduler, unmanaged local
Runtime Endpoint, provider-neutral Worker Runtime, and development-only vLLM
adapter. The Controller MUST NOT call vLLM directly. Prompt rendering SHALL
remain in Orchard and provider output SHALL return as ordered Worker Runtime
events. The direct proof fixture SHALL request and require the frozen literal
marker `ORCHARD_KAP112_DIRECT_OK` under the exact artifact-bound explicit
`medium` policy, official thinking sampler, and a 128-token output limit; that
assertion is fixture-conformance evidence, not a model-quality claim.

The disposable setup MAY create one development tenant, API key, model, access
grant, and unmanaged target. It MUST NOT enroll or admit a production Node,
issue a certificate or Peer Grant, or publish production scheduling or capacity
authority.

#### Scenario: One real response completes

- **WHEN** the exact tuple returns non-empty generated text through `/v1/responses`
- **THEN** the proof records terminal request status, exact model identity, elapsed latency, usage where existing surfaces provide it, Worker execution events, and corresponding Console visibility
- **AND** output quality or throughput is not inferred from the result

#### Scenario: Path bypass is detected

- **WHEN** a request reaches vLLM without traversing the scheduler, Runtime Endpoint, and Worker Runtime boundaries
- **THEN** the proof fails even if vLLM generated text

### Requirement: OpenCode Smokes Exercise Tools And The 128K Input Envelope

The proof SHALL configure one exact recorded installed OpenCode client identity
to consume Orchard's API, with proof-owned disposable config/data/state/cache and
workspace paths, sharing and auto-update disabled, prompt-cache-key emission
explicitly disabled and rejected during offline capture, and no external-model
fallback. These disposable paths protect cleanup and persistent configuration;
they SHALL NOT be described or enforced as an OpenCode sandbox. OpenCode MAY use
any installed client-side tool and choose its commands and ordering. The proof
MUST NOT enumerate, restrict, or qualify that tool surface. Tools SHALL run in
the OpenCode host client rather than Controller, Node, Worker, or provider.

The proof-only loopback proxy MAY translate the pinned client's exact flattened
Responses function-tool objects into Orchard's canonical nested function-tool
shape. Offline token calibration SHALL apply the identical translation, every
live translation SHALL be counted, and any extra field, invalid type, or request
count mismatch SHALL fail the proof. This compatibility translation SHALL NOT
expand Orchard's public API contract.

Because the Orchard stream carries assembled function calls in its terminal
event, the proof-only loopback proxy MAY synthesize the pinned OpenCode client's
exact output-item-added and output-item-done events from completed terminal
function-call items. It SHALL preserve the terminal event, count every
synthesized call, and fail closed on response drift. This SHALL NOT change
Orchard's streaming API contract. For terminal message text, the proxy MAY assign
one proof-local message identity, surround Orchard text deltas with the pinned
client's message-item events, and translate `response_id` to the required
`item_id`, while preserving text and the terminal event exactly. It MAY assign
unique proof-local function identities and, on later turns, correlate and flatten
each exact function-call/result pair into one role-bearing proof-only text message
because Orchard does not accept Responses tool-history input items. This SHALL
NOT change Orchard's input API contract. Correlation SHALL compare decoded JSON
argument values without conflating booleans and numbers, accept the pinned
client's call-block/result-block ordering, and prove every synthesized call
identity had a result forwarded at least once.

The Worker adapter SHALL parse raw output from vLLM's legacy completions route
with one exact artifact-bound Qwen3.8 parser. It SHALL discard reasoning without
retention from the pinned template's prompt-opened `<think>` frame through its
streamed closing marker, normalize only complete validated Qwen XML tool blocks
into `ToolCallDelta` events, emit only final answer text, and fail closed on
malformed, partial, unknown, unrequested, or ambiguous output. Orchard SHALL
resolve only an owner-only disposable registration bound to the exact artifact
and chat-template digests for `enabled + final_only + medium`, with template
arguments `enable_thinking = true` and `reasoning_effort = medium`. The sampler
SHALL be temperature `1.0`, top-p `0.95`, top-k `20`, min-p `0`, presence
penalty `0`, and repetition penalty `1`. Missing or mismatched registration,
implicit/default or `xhigh` selection, malformed or unclosed reasoning, empty
final output, and a mismatch between raw post-think output and public text or
typed tool calls SHALL fail closed. Fake-provider tests SHALL split each
streamed control marker across stream boundaries and exercise malformed and
truncated calls.

For this exact POC tuple, raw post-think output MAY contain one nonempty public
text prefix followed by one or more complete, structurally valid, requested
Qwen XML tool blocks. The adapter SHALL preserve that prefix exactly as public
assistant text and emit each block as a typed tool call in source order. Only
whitespace MAY occur between tool blocks or after the final block. Text between
or after tool blocks, malformed or partial blocks, unknown or unrequested functions,
structurally invalid or duplicate arguments, and reasoning-boundary failures
SHALL fail closed. The adapter SHALL NOT discard the prefix or reclassify it as
reasoning. This proof-only parser does not add JSON Schema validation of
model-selected argument values.

One short frozen repair SHALL reproduce a baseline failure, execute genuine
structured tool calls, edit only allowed implementation files, run tests,
inspect the diff, and produce a summary. Independent checks SHALL verify the
complete file set, result, protected-file hashes, edit scope, exact final diff,
and passing test without prescribing the client's actions or command sequence.

A separate frozen long-context smoke SHALL reach at least 131,072 actual
provider-tokenizer rendered input tokens, counting instructions, tool schemas,
messages, history, tool results, and repository context, while reserving 8,192
output tokens within at least 139,264 total capacity. It SHALL exercise
multi-position retrieval, a later instruction overriding an earlier conflict,
distant code dependencies, and tool-result continuity. The proof SHALL record
configured and effective capacity, actual rendered input, requested and
effective output limits, compaction and overflow behavior, parser mode, usage,
latency, and peak resources. Short repair requests need not fill the window.

Before provider activation, the exact runner SHALL capture the pinned OpenCode
request shape through a temporary loopback-only fake endpoint and use the exact
snapshot tokenizer and template to deterministically derive adjacent
131,072-input-token and 131,073-input-token fixtures. The resulting owner-only
receipt SHALL bind source commit/tree, fixture-manifest hash, OpenCode binary,
OpenCode plugin dependency-tree hash, model revision, tokenizer,
tokenizer-configuration and chat-template hashes, generator, materialized
fixture hash, and padding count. The live phase SHALL reconstruct and recount
both fixtures, reject a missing or drifted receipt, and SHALL NOT accept an
operator-asserted token count. Offline calibration MUST NOT start the provider,
use the GPU, create a database, or contact an external model endpoint. The
runner SHALL accept only the canonical manifest blob from the accepted source
tree and SHALL run the tokenizer through its frozen, offline dependency
environment without inherited credentials.

OpenCode evidence SHALL be parsed by documented event type. Terminal answer,
usage, finish, reasoning, and tool assertions MUST NOT search arbitrary
serialized events or accept values merely echoed from input. Acceptance SHALL
require Orchard API request/stream/tool-call/result compatibility, at least one
completed client-side tool event, a nonempty terminal answer, the exact repaired
fixture diff, protected hashes, edit scope, and an independent passing test. It
MUST NOT require an expected action sequence, command spelling, denial, or tool
allowlist. The runner SHALL strip unrelated credentials, disable external model
providers and use disposable client state, but SHALL NOT proxy, sandbox or
otherwise confine the installed OpenCode client. The runner SHALL measure
OpenCode API attempts and compare
the exact overflow HTTP status, type, and code plus durable Request state across
the overflow probe. Zero durable state change SHALL NOT be reported as proof
that no transient dispatch occurred. Every OpenCode process and its descendants
SHALL be terminated through an owned process group on timeout, interruption,
and cleanup.

After request probes, the runner SHALL request logical unload over the local
Runtime Endpoint and require an acknowledgement plus status evidence that the
exact model is no longer loaded. That evidence remains subject to the explicit
non-claims for native cessation and capacity release.

Each smoke SHALL have one initial attempt and no automatic provider/model
retry. Direct API and overflow probes SHALL stop after ten minutes. The short
OpenCode smoke SHALL stop after 20 model turns, 20 tool calls, any 60-second
tool-command timeout, or 30 minutes wall clock. The long-context smoke SHALL
stop after eight model turns, eight tool calls, any 60-second tool-command
timeout, or 60 minutes wall clock. Exhaustion SHALL fail the smoke and enter
cleanup without extending a bound or silently continuing after compaction.

Every durable proof query SHALL emit exactly one typed tagged value and reject
missing, duplicate, malformed, negative, or ambiguous values while tolerating
unrelated runtime logging. Before each live stage and immediately after its
validated completion, the runner SHALL atomically persist a mode-0600 receipt
under the proof root. Receipt fields SHALL use a closed per-stage schema and
contain only typed timing, usage, route, event-count, checksum, terminal-reason,
fixture-outcome, refusal, load/unload, or protocol-translation evidence. Failure
receipts SHALL identify the active stage and retain only error type, length and
digest. Receipts MUST NOT contain prompts, model or tool output, tool input,
file content, credentials, sensitive paths, or unbounded diagnostics, and SHALL
survive runner-state cleanup until the proof root is explicitly removed.

#### Scenario: Both OpenCode smokes pass

- **WHEN** the installed OpenCode client consumes Orchard's API, the short repair passes independent outcome checks, and the long-context smoke returns every predeclared answer through Orchard
- **THEN** the proof records POC evidence for that exact tuple, client, route, and rendered envelope
- **AND** it does not claim OpenCode, coding-agent, provider, model, or platform qualification

#### Scenario: Input exceeds the effective envelope

- **WHEN** rendered input exceeds the accepted capacity after the output reservation
- **THEN** the request is rejected before generation
- **AND** no layer silently truncates input or substitutes compaction for the rejection test

### Requirement: POC Provider Custody And Resources Are Explicitly Non-production

The bounded proof wrapper SHALL supervise the loopback vLLM container while the
Node Agent supervises the Unix-socket adapter. vLLM SHALL bind only to
`127.0.0.1:58080`, receive only the selected GPU and read-only verified model,
run at concurrency one with `--gpu-memory-utilization 0.80`, BF16 weights and
KV cache, a 139,264-token maximum model length, native context only, and use no
production service, cgroup, identity, credential, or admission path. The
utilization setting is a configuration target rather than a hard process-memory
ceiling; observed peak memory SHALL be recorded, and failure to start at the
target SHALL stop rather than raise it.

The exact installed vLLM and Transformers identities SHALL be recorded before
model download. Incompatibility with the pinned model or legacy completions
route SHALL stop rather than mutate or replace the cached image. Server-side
Chat Completions parser flags SHALL NOT be represented as parsing the raw
completions stream.

The container SHALL use the exact cached image with `--pull=never --rm`, host
networking, private shared memory, no remote code, and vLLM bound explicitly to
loopback. It MUST NOT publish a Docker port or expose the provider on a bridge,
LAN, or WAN.

Logical unload, stream closure, and container stop SHALL NOT be represented as
native cessation, request-slot release, Resource Allocation release, production
custody, or qualification evidence.

#### Scenario: A declared bound would be exceeded

- **WHEN** the provider requires another GPU, external listener, more GPU memory, another model/runtime, elevated host mutation, or production authority
- **THEN** the proof stops rather than broadening the tuple

### Requirement: POC State Is Disposable And Cleanup Is Proven

The proof SHALL record source, listeners, processes, containers, volumes, GPU
processes, development artifacts, and Git state before mutation. It SHALL use
disposable PostgreSQL, owner-only temporary credentials and sockets, and a
verified temporary model snapshot in a proof-specific owner-only download home
and cache. Cleanup SHALL stop every proof process, remove every proof-owned
container, database, credential, model, partial download, cache, socket, and
temporary path, and prove the recorded listener, container, volume, GPU-process,
development-artifact, and Git baselines are restored.

#### Scenario: Cleanup cannot be proved

- **WHEN** any proof-owned process or state cannot be classified or removed without touching pre-existing state
- **THEN** execution stops and the proof remains incomplete
- **AND** no qualification, capacity, reliability, or support conclusion is recorded
