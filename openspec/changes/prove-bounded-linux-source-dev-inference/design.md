## Context

Orchard's Node Agent already supervises a provider-neutral Worker Runtime over
gRPC on a Unix socket. The current Python implementation offers `mlx` and
`stub`; vLLM exposes an OpenAI-compatible HTTP server. Bypassing the Worker
Runtime would not test Orchard's scheduling/runtime path.

`kapitan` has four H100 NVL devices, abundant RAM and disk, the NVIDIA container
runtime, and the exact vLLM 0.27.1 image already cached. No Qwen snapshot is
cached. KAP-18, KAP-26, and KAP-85 remain unresolved production gates but need
not block a proof that makes no cessation, capacity-release, or qualification
claim.

## Goals / Non-Goals

**Goals:** prove exact real direct-API and OpenCode requests through Orchard;
preserve the provider-neutral Worker gRPC seam; capture existing
request/model/latency/usage evidence; verify the 131,072-rendered-input coding
agent envelope; make every mutation disposable and bounded.

**Non-goals:** provider qualification, production custody or trust, performance
benchmarking, cancellation or resource-release proof, broader model/runtime/GPU
support, appliance work, packaging, or retained host state.

## Decisions

### Exact tuple

Use the owner-approved GPU UUID from required `ORCHARD_KAP112_GPU_UUID`, cached vLLM image digest
`sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`,
and `Qwen/Qwen3.8-27B` revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`. Use BF16 at concurrency one
with 139,264 total tokens: 131,072 rendered input plus an 8,192-token output
reservation. ADR 0039 records complete provenance and resource bounds. Tuple
drift is a stop, not a substitution.

### Thin adapter, not a Controller shortcut

Add a `vllm_poc` backend behind the existing Worker Runtime service. Use the
rendered prompt and generation parameters Orchard already sends. Translate
vLLM stream chunks into accepted/text/usage/completed-or-failed Worker events.
Unit tests use a fake loopback HTTP server and require no GPU, image, or model.

Because the legacy completions endpoint does not apply vLLM's chat tool or
reasoning parsers, the adapter owns an exact Qwen3.8 raw-stream parser. It
discards reasoning without retention, converts validated complete Qwen XML tool
blocks into Worker `ToolCallDelta` events, emits only final answer text, and
fails closed on malformed, partial, unknown, or unrequested output. Tests split
all markers across stream chunks. Orchard keeps omitted `model_default`
rendering with the exact snapshot template; the POC neither injects
`enable_thinking` nor invokes production reasoning negotiation on an unmanaged
target.

The provider runs separately under the bounded proof wrapper. This keeps the
implementation small but does not satisfy Node Agent child custody. Logical
load/unload and stream closure are not cessation or capacity-release evidence.
The proof-only SPEC exception permits this split solely for an owner-invoked,
disposable, non-authoritative run; it does not change ADR 0025 custody for any
production or qualified provider.

### Development-only scheduling setup

Use the existing unmanaged source-development Runtime Endpoint classification.
Create one tenant, ephemeral API key, active model record, model access grant,
and exact local artifact fixture only in disposable PostgreSQL. Do not invoke
production enrollment, admission, certificate, or Peer Grant paths. The fixture
must be repeatable and scoped so production configuration cannot enable it.

### Direct API and OpenCode evidence

Submit a temperature-zero `/v1/responses` request asking for the literal phrase
`Orchard Linux inference POC`, with at most 32 output tokens. Success is a
non-empty real generated response, not exact wording; the request configuration
is deterministic but model output need not be. Record the existing
request terminal state, exact model identity, elapsed latency, usage where
reported, Worker event path, and Console request/model visibility.

Run two isolated OpenCode smokes through Orchard with sharing, auto-update, and
external-provider fallback disabled. The short smoke performs one frozen
repair with real client-side tool calls, an independently checked result,
protected hashes and edit-scope enforcement, plus one denied/no-change and one
approved/executed action. The long-context smoke exercises at least 131,072
actual provider-tokenizer rendered input tokens plus the separate 8,192-token
output reservation. Its frozen fixture covers multi-position retrieval, later
instruction precedence, distant code dependencies, and tool-result continuity.
Record client/provider identities, rendered counts, requested/effective output,
compaction/overflow, parser mode, usage, latency and resources. Prove an
oversized input is rejected without silent truncation. These are POC smokes,
not coding-agent qualification.

Use one attempt and no automatic provider/model retries. Direct and overflow
probes each stop at ten minutes. The short smoke stops at 20 model turns, 20
tool calls, 60 seconds per tool command, or 30 minutes wall time. The
long-context smoke stops at eight model turns, eight tool calls, 60 seconds per
tool command, or 60 minutes wall time. Reaching any bound fails that smoke and
starts cleanup.

### Network and cleanup

PostgreSQL uses `127.0.0.1:55432`, Orchard uses loopback 4000 and 50071, and
vLLM uses `127.0.0.1:58080`; the adapter uses an owner-only Unix socket. Capture
pre-state and refuse collisions. Traps stop child processes and remove only
proof-owned containers, database, model snapshot, credentials, sockets, and
temporary files. Verify listener/container/volume/GPU-process/Git equivalence
afterward.

## Risks / Trade-offs

- External container supervision bypasses production provider custody. This is
  explicit and prevents any custody or reliability claim.
- HTTP stream closure may or may not stop native execution immediately. No
  cancellation or resource-release scenario is accepted by this proof.
- A development database fixture can resemble production records. It is allowed
  only with the unmanaged classification and disposable database, and may not
  enroll or admit a Node.
- A tiny model on an H100 proves connectivity more than practical serving. That
  is intentional; performance and model quality are outside the question.

## Execution Gate

Gate one accepts this contract, including the tuple, 55,615,875,685-byte
Hugging Face snapshot, Apache-2.0 license, cached 21,417,065,539-byte image,
selected GPU, 0.80 vLLM GPU-memory target, 139,264-token minimum total envelope,
ports, adapter/setup design, direct and OpenCode smokes, stop conditions, and
cleanup plan, before implementation.

Gate two, after implementation and validation, accepts the exact clean source
commit/tree, exact provider/download/Orchard commands, captured pre-state plan,
and unchanged tuple before any model download, provider activation, or
inference. Either gate rejects drift rather than silently substituting. This POC
is not the Milestone 9 provider pilot or qualification and cannot satisfy
KAP-103 or KAP-105.
