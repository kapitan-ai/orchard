## ADDED Requirements

### Requirement: Linux Source-development Inference POC Uses One Immutable Tuple

After contract acceptance and implementation, the proof SHALL use only the
exact clean implementation commit/tree separately accepted by the owner before
execution, the owner-approved NVIDIA device from required `ORCHARD_KAP112_GPU_UUID`, vLLM image
digest `sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`,
and `Qwen/Qwen3.8-27B` revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, comprising the immutable
55,615,875,685-byte repository snapshot and its 18 BF16 weight shards. Every
tuple component and every downloaded file SHALL be verified against immutable
Hub metadata before activation. Drift SHALL stop the proof and SHALL NOT select
an alternative.

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
events.

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

The proof SHALL run OpenCode only through Orchard with one exact recorded client
identity, isolated proof-owned config/data/state/cache and repositories, sharing
and auto-update disabled, and no external-provider fallback. Tools SHALL run in
the OpenCode client rather than the provider.

The Worker adapter SHALL parse raw output from vLLM's legacy completions route
with one exact artifact-bound Qwen3.8 parser. It SHALL discard reasoning without
retention, normalize only complete validated Qwen XML tool blocks into
`ToolCallDelta` events, emit only final answer text, and fail closed on
malformed, partial, unknown, unrequested, or ambiguous output. Orchard SHALL
preserve omitted `model_default` template behavior without injecting
`enable_thinking` or invoking explicit reasoning negotiation on the unmanaged
target. Fake-provider tests SHALL split each control marker across stream
boundaries and exercise malformed and truncated calls.

One short frozen repair SHALL reproduce a baseline failure, execute genuine
structured tool calls, edit only allowed implementation files, run tests,
inspect the diff, and produce a summary. Independent checks SHALL verify the
result, protected-file hashes, and edit scope. One denied action SHALL make no
change and one approved action SHALL execute.

A separate frozen long-context smoke SHALL reach at least 131,072 actual
provider-tokenizer rendered input tokens, counting instructions, tool schemas,
messages, history, tool results, and repository context, while reserving 8,192
output tokens within at least 139,264 total capacity. It SHALL exercise
multi-position retrieval, a later instruction overriding an earlier conflict,
distant code dependencies, and tool-result continuity. The proof SHALL record
configured and effective capacity, actual rendered input, requested and
effective output limits, compaction and overflow behavior, parser mode, usage,
latency, and peak resources. Short repair requests need not fill the window.

Each smoke SHALL have one initial attempt and no automatic provider/model
retry. Direct API and overflow probes SHALL stop after ten minutes. The short
OpenCode smoke SHALL stop after 20 model turns, 20 tool calls, any 60-second
tool-command timeout, or 30 minutes wall clock. The long-context smoke SHALL
stop after eight model turns, eight tool calls, any 60-second tool-command
timeout, or 60 minutes wall clock. Exhaustion SHALL fail the smoke and enter
cleanup without extending a bound or silently continuing after compaction.

#### Scenario: Both OpenCode smokes pass

- **WHEN** the short repair passes independent checks and the long-context smoke returns every predeclared answer through Orchard
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
