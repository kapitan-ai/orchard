## Context

Orchard's only real-inference path is the MLX-LM Worker on Apple Silicon and
Metal (`SPEC.md` §1.5). The Linux GPU direction is the default-off `vllm_poc`
adapter (ADR 0037) and the Milestone 9 one-H100 pilot. Neither runs without
an accelerator, so Linux CI runners, orbs and contributor machines exercise
the Worker seam only with the `stub` backend.

This design covers test lanes that run real models on CPU. It does not choose
a production runtime for any platform. Its requirements specify lane A only;
lane B is design direction for a later change.

## Evidence

Bounded probes ran on 2026-11-09 against each runtime's own OpenAI-compatible
server, not through Orchard's Worker. Two hosts were used:

- **orb:** an 8-vCPU x86 Xeon at 2.6 GHz with 15 GB RAM, AVX-512F and VNNI,
  no AMX and no GPU. llama.cpp only.
- **Xeon AMX host:** a 32-vCPU Intel Xeon Platinum 8592+ under KVM with
  251 GiB RAM, AVX2, AVX-512 and AMX. Each run was pinned to 8 or 4 CPUs with
  the GPU hidden. llama.cpp and vLLM.

Qwen3-0.6B on the Xeon AMX host, 8 / 4 threads:

| | llama.cpp b12211, Q4\_K\_M | vLLM 0.27.1+cpu, BF16 |
|---|---|---|
| Runtime install | 23 MB archive, 55.7 MiB unpacked | 2.95 GiB with CPU PyTorch |
| Cold start to healthy | 0.8 / 0.9 s | 91 / 96 s, including JIT compile |
| Peak RSS summed over the process tree | 1.41–1.46 GiB | 5.17–5.20 GiB |
| Decode, prefix caching off | 150 / 94 tok/s | 49 / 29 tok/s |
| Streaming, usage chunk, `[DONE]` (`/v1/chat/completions`) | pass | pass |
| Cancel, then next request (`/v1/chat/completions`) | pass; host CPU idle after 0.4 s | pass; host CPU idle after 1.4 s |
| Tool call (`/v1/chat/completions`, server parser) | pass, `--jinja` | pass, `hermes`; forced choice returned `finish_reason: "stop"` |
| `json_object` (`/v1/chat/completions`, runtime enforcement) | pass | pass, vLLM structured outputs |
| Token-ID prompt, non-streamed `/v1/completions` | pass | pass |

Summed RSS may count shared pages twice. The idle times come from watching
host CPU use outside the runtime. They are probe observations, not evidence
of native cessation, which stays unconfirmed. The token-ID check's summary
script asserted `prompt_tokens == 24` in none of its 8 configurations; the
count was printed and checked by hand in 4 of them.

The Worker's actual path combines a streamed `/v1/completions` request with
token IDs, a usage trailer and cancellation. That combination was not run on
either runtime, so slice 1 runs it first. Tool calls and `json_object` passed
only through each server's own parser or enforcement, which lane A does not
use.

On the orb, llama.cpp decoded at 8 / 4 threads:

| | Qwen3-0.6B | MiniCPM5-2B | Gemma 4 E2B |
|---|---|---|---|
| Peak RSS | 1.2 GB | 2.7 GB | 4.2 GB |
| Decode | 78 / 48 tok/s | 28 / 17 tok/s | 21 / 16 tok/s |

All three passed streaming, cancellation, server-parsed tool calls and
`json_object` on `/v1/chat/completions`. Only Qwen3-0.6B ran a token-ID
prompt. MiniCPM5-2B and Gemma 4 E2B followed exact answer-format
instructions, which Qwen3-0.6B did not.

Two observations shape the corpus:

- Greedy output for a 200-token prompt with 256 generated tokens differed
  between 4 and 8 threads on both runtimes.
- With prefix caching on, repeated greedy runs differed on llama.cpp at both
  thread counts and on vLLM at 8 threads.

SGLang's CPU backend requires Intel AMX and supports 4-bit checkpoints only
on AMX, so it cannot serve a lane meant for commodity CPUs.

## Goals and non-goals

Goals:

- Exercise the Worker seam with real tokens on hosts without an accelerator:
  load, generate, stream, usage, cancel, unload and tool calls.
- Keep each lane cheap enough for its trigger. Lane A should fit a 4-vCPU
  GitHub-hosted runner within minutes.
- Run the provider-neutral Worker contract (ADR 0025) against a second real
  provider, including a truthful diagnostic-only capability envelope.

Non-goals:

- A runtime-provider, platform, model or acceleration profile, qualification
  or support claim.
- Performance claims. Lane timings are diagnostic.
- Replacing the MLX-LM lane on Apple Silicon, or covering Metal kernels.
  macOS hosts are out of lane A.
- Concurrency above one (`SPEC.md` §7.5.3).
- Structured-output enforcement. `GenerationParams` carries no
  `response_format`, so `json_object` is not observable at the Worker seam,
  and `SPEC.md` §7.2.4 leaves `json_schema` unsupported.

## Decisions

### Two lanes, not one runtime

Lane A gives breadth: any Linux CPU, frequent runs, low cost. Lane B gives
fidelity to the production Linux engine, but at roughly 90 s of startup and
5 GiB of memory per model it suits nightly or on-demand runs on chosen hosts.

Choosing only llama.cpp would leave vLLM's scheduler and cancellation
unexercised without a GPU. Lane B sends `/v1/completions` and parses output
in the Worker, so vLLM's own tool and reasoning parsers stay unexercised
either way. Choosing only vLLM CPU would exclude AVX2-only hosts and make
every run slow.

### Lane A runs llama-server as a Worker-owned child

`vllm_poc` launches nothing: it is a loopback client of a server that a
wrapper outside Node Agent child custody owns. Lane A instead introduces a
Worker-owned grandchild, which is a new custody boundary under `SPEC.md`
§4.10 and ADR 0025, where the Node Agent owns subprocess cleanup. The Node
Agent's tree kill runs only after its SIGTERM timeout, so the Worker must not
rely on it:

- The child starts in the Worker's process tree and dies with the Worker. On
  Linux it sets `PR_SET_PDEATHSIG`. That signal fires when the parent
  *thread* exits, so the Worker spawns the child from a thread that lives as
  long as the Worker, and the child checks `getppid()` after `prctl` to close
  the startup race. The child also gets its own process group, which the
  Worker signals on unload and shutdown.
- Each launch gets a per-launch nonce passed as `--alias` and a per-launch
  `--api-key-file`. Before admission, the Worker reads `/props` with that key
  and checks `model_alias`, `model_path` and `total_slots == 1`. A stale
  server left by a previous Worker on the same model path cannot pass, and
  other local users cannot drive the server.
- Unload and shutdown stop and reap the child. A child that cannot be reaped
  marks the Worker unhealthy and blocks admission until replacement.
- These are Worker-side measures on top of the existing custody. The Node
  Agent stays the lifecycle and cleanup owner of the Worker process tree, so
  `SPEC.md` §4.10 and ADR 0025 are unchanged.

At b12211, `llama-server` enables its Jinja renderer by default, keeps an
8192 MiB host-memory prompt cache that saves and restores independently of
the per-request `cache_prompt` flag, and starts in router mode when given no
model. Before the environment and argv, it applies `/etc/llama.cpp/config.ini`
and `${XDG_CONFIG_HOME:-~/.config}/llama.cpp/config.ini`, with no opt-out, and
it reads `LLAMA_ARG_*`, `LLAMA_API_KEY` and `HF_TOKEN` from the environment.
ggml loads backends from the executable directory, the working directory and
`GGML_BACKEND_PATH`. The Worker therefore launches the pinned CPU-only archive
with an explicit argument list:

```text
-m <digest-verified GGUF path>
--no-jinja --special -np 1 --no-cache-prompt --cache-ram 0 --no-slots
--device none -ngl 0 -c <pinned context> -t <pinned threads>
--host 127.0.0.1 --port <per-instance port>
--alias <launch nonce> --api-key-file <per-launch key file>
```

The list never carries `-hf`, `-mu` or `-dr`. `--no-jinja` disables Jinja
rendering only; the legacy template path behind `/v1/chat/completions` is
unused because lane A calls only `/v1/completions`. `--special` makes the
server emit control-type pieces such as MiniCPM5's `<tool_call>`, matching
`orchard_tokenizer` and MLX, which decode with `skip_special_tokens=False`.

The child's environment is an allowlist: `PATH`, `LANG=C`, and `HOME` and
`XDG_CONFIG_HOME` pointing at an empty per-launch directory. It runs in a
working directory with no ggml libraries. Preflight fails when
`/etc/llama.cpp/config.ini` exists, and the Worker refuses admission when the
startup log contains a "using config file" line. The API key file is
owner-only. `/health`, `/v1/health` and static UI assets skip the API key at
b12211, so the identity and admission checks never rely on them.

Before admission, the Worker reads `/props` and checks `model_alias`,
`model_path`, `total_slots == 1`, `default_generation_settings.n_ctx` against
the pinned context, and that the default sampler carries nothing a GGUF's
`general.sampling.*` keys could add beyond what each request overrides.
`/props` names no backend, and backend loading is silent in release builds,
so the Worker reads the child's `/proc/<pid>/maps`. CPU-only means no ggml
library is mapped other than `libggml-base`, `libggml`, one
`libggml-cpu-<variant>` and `libggml-rpc`, which both pinned archives ship
and ggml loads from the executable directory. The mapped CPU variant is
recorded in the host class.

Embedding llama.cpp through Python bindings was rejected. It would add a
native build to the Worker environment, and the bindings lag upstream
releases.

### Lane A sends only authoritative token IDs

The Worker sends Orchard's `prompt_token_ids` to `/v1/completions`. MLX and
`vllm_poc` fall back to rendered text when IDs are absent. Lane A does not
fall back: a request without IDs is rejected before generation. The
Controller's default `tokenizer_safe_mode` is `off`, and in that mode it
strips `prompt_token_ids` before dispatch, so slice 3's end-to-end runs must
set `ORCHARD_TOKENIZER_SAFE_MODE=reject`.

llama-server fills every omitted sampler field with its own defaults, which
include top-k 40, min-p 0.05, temperature 0.8 and a random seed. Each request
therefore carries a complete sampler:

- `temperature` from `GenerationParams`, where 0 means greedy
- `top_p` from `GenerationParams` when it lies strictly between 0 and 1, and
  1 otherwise. `GenerationParams` uses proto3 doubles, so 0 means unset, and
  the MLX sampler applies top-p only inside that range. llama-server accepts
  top-p 0 and keeps a single token, so passing it through would make an unset
  value greedy.
- `top_k` 0, `min_p` 0, neutral repetition, presence and frequency
  penalties, and every other sampler at its neutral value
- a pinned `seed`
- `stop` from `stop_sequences`, and `n_predict` set to `max_output_tokens`

A request whose `max_output_tokens` is 0, or whose input plus
`max_output_tokens` exceeds the pinned context, is rejected before
generation, as `vllm_poc` checks its own limit. Token-ID output, logprobs and
any control the Worker does not map are also rejected before generation.

Prompt caching is disabled at launch (`--no-cache-prompt`, `--cache-ram 0`)
and again per request (`cache_prompt: false`). On a streamed
`/v1/completions` request, `usage.prompt_tokens_details.cached_tokens`
arrives only in the final chunk. With `timings_per_token` set, every chunk
carries `timings.cache_n`, and the first chunk also carries the first
generated text. The Worker therefore reads `timings.cache_n` from that chunk
before forwarding its text, and fails the generation without emitting a delta
when the count is above zero or absent. In the
probes, cache-on runs both reused tokens and changed output.

### Lane A serves thinking-disabled prompts only

Qwen3-0.6B and MiniCPM5-2B emit `<think>…</think>` when thinking is on.
`vllm_poc` handles that framing itself, and the MLX path has a
provider-neutral `reasoning.py`. Lane A takes neither path in slice 1. It
returns all generated text as answer content and publishes no reasoning
evidence (`WorkerCapabilities` fields 8 and 9 omitted, so no `SPEC.md`
§7.5.3a evidence). Corpus prompts are rendered with thinking disabled, and a
case whose output contains the reasoning-open marker fails rather than
grading reasoning text as the answer. Routing lane A through `reasoning.py`
is later work.

### Lane A checks tokenizer parity against a pinned source

Because the Worker sends IDs, llama.cpp's encoder is never used. What can
corrupt output is decoding: the GGUF's vocabulary turns generated IDs into
bytes, and its end-of-generation IDs decide when generation stops. Parity
therefore requires:

- the same ID-to-piece mapping for every ID the pinned tokenizer defines,
  including added tokens, and only unused or padding tokens above that range
- identical decoded bytes for every corpus entry, including special and
  control tokens
- the pinned `generation_config.json` end-of-sequence IDs contained in the
  GGUF's end-of-generation set
- each extra GGUF end-of-generation ID classified by its class in the pinned
  tokenizer

Exact-set and full-range comparisons would reject every candidate. llama.cpp
pads the GGUF vocabulary beyond the IDs `tokenizer.json` defines, and it adds
fill-in-the-middle and text-matched tokens to the GGUF's end-of-generation
set. `orchard_tokenizer` has no end-of-generation concept, and the tokenizer
configuration names only one end-of-sequence token, so the generation
configuration is the reference.

Containment alone is not enough. llama.cpp adds any token whose text is
`</s>` to the end-of-generation set and forces it to control type. The pinned
Qwen3 GGUF's set includes 128247 (`</s>`), an ordinary vocabulary entry in
the pinned `tokenizer.json`, and the Gemma 4 GGUF's set includes `</s>` (ID
212, normal type). Lane A would stop where MLX continues if the model wrote
that text. The parity record therefore lists an ordinary-text extra as a
divergence, and no corpus case may depend on generating it.

`orchard_tokenizer` needs `tokenizer.json`, its configuration and the chat
template, which the GGUF repositories do not ship. Each model therefore pins
its upstream tokenizer source by revision and file digest, and the parity
record states the special-token parse mode used to encode the corpus. The
corpus covers ASCII, Malay, CJK, emoji, whitespace runs and every special or
control token the template emits.

### Lane A cancellation follows the reader-settlement rule

On cancel, the Worker closes the request-owned stream reader and waits for it
to settle within a fixed bound, then emits one cancelled terminal and admits
the next request. Native cessation stays unconfirmed: llama-server's
`/slots` state is not presented as confirmation. A reader that does not
settle latches the Worker unhealthy until replacement, including after
logical unload and reload, matching ADR 0037's rule for `vllm_poc`.

### Lane A publishes a diagnostic capability envelope

The Worker's `Status` carries a complete `WorkerCapabilities` envelope, where
every required scalar is non-empty:

- `provider_id`, `provider_version` (the llama.cpp build),
  `implementation_version` and `service_incarnation`
- one profile with `profile_id`, `artifact_format` `gguf`, `acceleration`
  `cpu`, `device_binding`, `memory_semantics`, `runtime_features`,
  `max_concurrency` 1, and an empty `cache_capabilities` set because prompt
  caching is off
- no `loaded_binding` and no `reasoning_evidence` (fields 8 and 9)

Under `SPEC.md` §4.10 this evidence stays diagnostic-only and changes no
admission or scheduling behaviour.

### Hosts pass a preflight before mutation

Lane A checks before downloading or starting anything:

- Linux on an architecture with a pinned CPU-only build (x86-64 or arm64);
  macOS is out, because the macOS release build includes Metal
- AVX2 on x86
- free memory against the model's recorded peak plus margin
- accelerator isolation defined by backend availability, not device nodes:
  the verified archive ships no accelerator backend, `GGML_BACKEND_PATH` is
  unset, the working directory is empty and the child gets `--device none`.
  A `/dev/dri` node on a developer laptop does not by itself skip the lane.
- no `/etc/llama.cpp/config.ini`

A failed preflight skips the lane with a recorded reason. It is never a
silent pass.

The AVX2 floor is a lane policy, not a requirement of the build. The x64
archive ships CPU backend variants from SSE4.2 to Sapphire Rapids and picks
one per host. The variant mapped by the child, read from its
`/proc/<pid>/maps`, is recorded as part of the host class, because it can
change generated text.

### The corpus asserts outcomes, not prose

Lane tests assert protocol behaviour (event order, one terminal, usage
totals, cancellation outcome, tool-call shape) and semantic results (a
one-word answer containing "Paris", an exact "42" from the quick-check model,
exact values in prompted JSON). JSON cases are prompted and validated by the
test; they test instruction-following, not enforcement. The plumbing model
gets only loose semantic checks.

Exact-answer and golden-text cases run at temperature 0 with the pinned seed.
Golden text is allowed only within one runtime, one pinned host class
(including the mapped CPU variant) and one thread count, with prefix caching
off. It is never compared across runtimes
or thread counts.

### Model roles and pins

| Model | Lane A role | Lane B |
|---|---|---|
| Qwen3-0.6B | plumbing: load, stream, cancel, usage | the only model |
| MiniCPM5-2B | exact-answer and prompted-JSON quick check | not used |
| Gemma 4 E2B | behaviour baseline | not used |

The Hugging Face cards for all three upstream models and their GGUF builds
list Apache-2.0. Each is admitted only after the same publisher license check.

Lane A runtime pins, llama.cpp `b12211` (commit
`7d7f0287530bc8981690f361d8c1627dbae1c99a`):

- `llama-b12211-bin-ubuntu-x64.tar.gz`, SHA-256
  `962924b5431bc1237a9e5d26ba072d37b6fe05f79b495206e7ff6134887624c5`; probed
- `llama-b12211-bin-ubuntu-arm64.tar.gz`, SHA-256
  `6eed2da01c098f814170e941e11a8d91eed200a9a2923eac805fe116b14aff30`; pinned,
  not yet probed

Lane A model pins:

- `unsloth/Qwen3-0.6B-GGUF` revision `50968a4468ef4233ed78cd7c3de230dd1d61a56b`,
  `Qwen3-0.6B-Q4_K_M.gguf`, SHA-256
  `ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a`
- `openbmb/MiniCPM5-2B-GGUF` revision `2079a22f3beaa4e306449978533478fe0522f4b3`,
  `MiniCPM5-2B-Q4_K_M.gguf`, SHA-256
  `ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`
- `unsloth/gemma-4-E2B-it-GGUF` revision `0314792d7f1f7e229411f620751375812bb9faf2`,
  `gemma-4-E2B-it-Q4_K_M.gguf`, SHA-256
  `740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8`

Tokenizer source for Qwen3-0.6B: `Qwen/Qwen3-0.6B` revision
`c1899de289a04d12100db370d81485cdf75e47ca`, `tokenizer.json` SHA-256
`aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4`,
`tokenizer_config.json` (which carries the chat template) SHA-256
`d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101`,
`generation_config.json` SHA-256
`2325da0f15bb848e018c5ae071b7943332e9f871d6b60e2ed22ca97d4cb993d2`
(end-of-sequence IDs 151645 and 151643). The
MiniCPM5-2B and Gemma 4 E2B tokenizer sources are pinned the same way when
their parity runs.

### Tool calls are parsed in the Worker

No provider-neutral Worker tool-call parser exists today. The MLX path takes
its parser from mlx-lm's tokenizer wrapper in the `mlx` optional extra, and
`vllm_poc` has its own parser for Qwen3.8's `<function=…>` XML blocks. Qwen3
emits Hermes JSON inside `<tool_call>`, which neither parses for lane A.

Slice 2 therefore adds a provider-neutral Worker tool-call parser, starting
with Hermes JSON for the Qwen3 family. Until it lands, lane A runs no
tool-call cases. A model whose tool format the parser does not cover is
excluded from tool-call cases; on MLX, MiniCPM5-2B's XML tool calls were not
parsed.

### Lane B direction: a harness-launched vLLM CPU profile

Lane B is not specified here. The `linux-source-dev-inference-poc`
capability in the pending change `prove-bounded-linux-source-dev-inference`
and ADR 0037 pin `vllm_poc` to temperature 1.0 and top-p 0.95, two thinking
prompt suffixes, port 58080 and a supervisor that requires a GPU identity. A
greedy CPU profile contradicts those pins, so lane B's change modifies that
capability and revises ADR 0037 in the same pull request.

Its expected shape:

- The adapter's model identity, served name, sampling, token limits, prompt
  framing, reasoning framing and tool-parser family move into frozen serving
  profiles. The Qwen3.8-27B tuple becomes the first, selected when no
  profile selector is given, with unchanged behaviour and tests. A
  thinking-enabled Qwen3-0.6B prompt does not end in `<think>\n`, so prompt
  framing must be profile data.
- `vllm_poc` stays a loopback client. A lane B harness launches the pinned
  server, records its argv and environment, and enforces what the Worker
  cannot see: the pinned wheel, `--max-num-seqs 1`, prefix caching off, the
  thread count, `CUDA_VISIBLE_DEVICES=` and the AVX-512F preflight before
  mutation. The Worker checks what it can see: the served name, `/version`
  and `max_model_len`.
- Lane B runs no tool-call cases until the slice 2 parser covers Qwen3.

Pins recorded for lane B:

- vLLM `0.27.1+cpu` wheel, build commit
  `6e448d0ea9bf3d88d898b65449ca6dc2aec170ac`, URL
  `https://wheels.vllm.ai/6e448d0ea9bf3d88d898b65449ca6dc2aec170ac/vllm-0.27.1%2Bcpu-cp38-abi3-manylinux_2_34_x86_64.whl`,
  127,738,428 bytes, SHA-256
  `36f0e7b2031233ff09e521716723b0e05ab62054c9a9a05d873af43052140f33`
- `Qwen/Qwen3-0.6B` revision `c1899de289a04d12100db370d81485cdf75e47ca`,
  `model.safetensors` 1,503,300,328 bytes, SHA-256
  `f47f71177f32bcd101b7573ec9171e6a57f4f4d31148d38e382306f42996874b`

The lane B change verifies both before use and records the full Python lock.

## Risks and trade-offs

- **CPU passes say nothing about Metal or GPU kernels.** The lanes complement
  the MLX and GPU lanes; they don't replace them.
- **llama.cpp is not production code.** Lane A covers Orchard's Worker seam,
  not vLLM or MLX-LM behaviour.
- **A new custody boundary.** Lane A's Worker-owned child is the first
  provider subprocess a Worker owns, so its death-with-Worker and identity
  checks need direct tests.
- **GitHub-hosted runner CPUs vary.** Whether they expose AVX-512 is unknown,
  so lane B starts on self-hosted hosts only.
- **Supply chain.** Both lanes download pinned binaries or wheels. Digests are
  checked before use, and CI wiring falls under the supply-chain lane.
- **Memory on 4-vCPU runners.** Gemma 4 E2B's 4.2 GB peak fits a 16 GB
  runner, but lane A may start with only Qwen3-0.6B and MiniCPM5-2B.

## Migration

Slices 1 and 2 add Worker-only code behind a new, default-off selector. Model
bundles, the catalog and the Controller are unchanged; the existing `mlx`,
`stub` and `vllm_poc` backends keep their behaviour.

Slice 3 needs an additive artifact format and adapter for GGUF. Under
`SPEC.md` §6.4, current `format`, `adapter` and `min_agent_capability`
values stay valid and authoritative until additive replacements pass separate
review. Slice 3 is therefore its own reviewed design before implementation.

## Open questions

- Do GitHub-hosted Linux runners reliably expose AVX-512? This decides
  whether lane B can ever run there.
- Should lane A run on every pull request or only when Worker, tokenizer or
  dispatch paths change?
- Which self-hosted hosts run lane B, and who approves registering them?
