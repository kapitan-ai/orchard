## Context

Orchard's only real-inference path is the MLX-LM Worker on Apple Silicon and
Metal (`SPEC.md` §1.5). The Linux GPU direction is the default-off `vllm_poc`
adapter (ADR 0037) and the Milestone 9 one-H100 pilot. Neither runs without
an accelerator, so Linux CI runners, orbs and contributor machines exercise
the Worker seam only with the `stub` backend.

This design covers a test lane that runs real models on CPU. It does not
choose a production runtime for any platform.

## Evidence

Bounded probes ran on 2026-11-09 against each runtime's own OpenAI-compatible
server, not through Orchard's Worker. Model pins appear under Decisions.

| | llama.cpp b12211, Q4\_K\_M | vLLM 0.27.1+cpu, BF16 |
|---|---|---|
| Host CPU features needed | AVX2 or ARM NEON | AVX-512 recommended; AVX2 has basic support only |
| Runtime install | 23 MB archive, 56 MB unpacked | about 3 GB with CPU PyTorch |
| Qwen3-0.6B cold start | about 1 s | about 90 s, including JIT compile |
| Qwen3-0.6B peak memory | 1.2–1.4 GB | 5.2 GB |
| Qwen3-0.6B decode, 8 / 4 threads | 150 / 94 tok/s | 49 / 29 tok/s |
| Streaming, usage chunk, `[DONE]` | pass | pass |
| Cancel, then next request | pass; host CPU idle after 0.4 s | pass; host CPU idle after 1.4 s |
| Tool call, `json_object` | pass | pass |
| Token-ID prompt on `/v1/completions` | pass | pass |

The idle times come from watching host CPU use outside the runtime. They are
probe observations, not evidence of native cessation, which stays unconfirmed
for lane B under ADR 0037.

On an 8-vCPU x86 host, llama.cpp also ran MiniCPM5-2B (2.7 GB, 28 tok/s) and
Gemma 4 E2B (4.2 GB, 21 tok/s). Both passed the same checks, and both
followed exact answer-format instructions, which Qwen3-0.6B did not.

Two observations shape the corpus:

- Greedy output on a 256-token prompt differed between 4 and 8 threads on
  both runtimes.
- Enabling prefix caching changed generated text on both runtimes.

SGLang's CPU backend requires Intel AMX and supports 4-bit checkpoints only
on AMX, so it cannot serve a lane meant for commodity CPUs.

## Goals and non-goals

Goals:

- Exercise the Worker seam with real tokens on hosts without an accelerator:
  load, generate, stream, usage, cancel, unload, tool calls and structured
  output.
- Keep each lane cheap enough for its trigger. Lane A should fit a 4-vCPU
  GitHub-hosted runner within minutes.
- Exercise the provider-neutral Worker contract (ADR 0025) with a second real
  provider.

Non-goals:

- A runtime-provider, platform, model or acceleration profile, qualification
  or support claim.
- Performance claims. Lane timings are diagnostic.
- Replacing the MLX-LM lane on Apple Silicon, or covering Metal kernels.
- Concurrency above one (`SPEC.md` §7.5.3).
- Grammar-constrained or `json_schema` output, which `SPEC.md` §7.2.4 leaves
  unsupported.

## Decisions

### Two lanes, not one runtime

Lane A gives breadth: any CPU, frequent runs, low cost. Lane B gives fidelity
to the production Linux engine, but at roughly 90 s of startup and 5 GB of
memory per model it suits nightly or on-demand runs on chosen hosts.

Choosing only llama.cpp would leave vLLM's scheduler, cancellation and parsers
unexercised without a GPU. Choosing only vLLM CPU would exclude AVX2-only
hosts and make every run slow.

### Lane A runs llama-server as a supervised child

The `llamacpp_cpu` backend supervises one CPU-only `llama-server` child on a
loopback port, the same shape as `vllm_poc`'s local HTTP provider. Flags:
`--jinja`, one slot, a pinned context, a pinned thread count, and no GPU
layers.

Embedding llama.cpp through Python bindings was rejected. It would add a
native build to the Worker environment, and the bindings lag upstream
releases.

The Worker owns the child's lifecycle. Unload and Worker shutdown stop and
reap it. A child that cannot be reaped marks the Worker unhealthy and blocks
further admission until replacement.

### Lane A sends authoritative token IDs

The Worker sends Orchard's `prompt_token_ids` to `/v1/completions` and never
asks llama.cpp to render or retokenize. Rendering stays with
`orchard_tokenizer`, as for every other provider.

The GGUF's embedded tokenizer must still agree with `orchard_tokenizer`.
llama.cpp detokenizes output with it, and a vocabulary mismatch would
silently corrupt text. A per-model parity check encodes a fixed corpus with
both tokenizers and requires identical IDs. The corpus covers ASCII, Malay,
CJK, emoji, whitespace runs and every special or control token the template
emits. A model that fails is excluded from the lane.

### Lane B generalizes `vllm_poc` behind frozen profiles

The adapter's model ID, revision, served name, sampling controls and token
limits move from module constants into a frozen serving profile. The existing
Qwen3.8-27B tuple becomes the first profile, with unchanged behaviour and
tests. A second profile pins:

- the vLLM 0.27.1 CPU wheel
- Qwen/Qwen3-0.6B in BF16 at a fixed revision
- `--max-num-seqs 1`
- prefix caching disabled
- greedy sampling

ADR 0037's cancellation finding still applies: native cessation stays
unconfirmed, and admission resumes only after the request-owned reader
settles.

### Hosts pass a preflight before mutation

Each lane checks before downloading or starting anything:

- operating system and architecture
- required CPU flags: AVX2 for lane A on x86; AVX-512F for lane B
- free memory against the profile's recorded peak plus margin
- no visible accelerator: lane runs hide GPUs, and lane A passes zero GPU layers

A failed preflight skips the lane with a recorded reason. It is never a
silent pass.

### The corpus asserts outcomes, not prose

Lane tests assert protocol behaviour (event order, one terminal, usage
totals, cancellation outcome, tool-call shape) and semantic results
(a one-word answer containing "Paris", an exact "42" from the quick-check
model, exact JSON values). The plumbing model gets only loose semantic checks.

Golden text is allowed only within one runtime, one pinned host class, one
thread count, and prefix caching off. It is never compared across runtimes or
thread counts.

### Model roles

| Model | Lane A role | Lane B |
|---|---|---|
| Qwen3-0.6B | plumbing: load, stream, cancel, usage | the only model |
| MiniCPM5-2B | exact-answer and JSON quick check | not used |
| Gemma 4 E2B | behaviour baseline, after license confirmation | not used |

Pins for lane A, recorded from the probe:

- `unsloth/Qwen3-0.6B-GGUF` revision `50968a4468ef4233ed78cd7c3de230dd1d61a56b`,
  `Qwen3-0.6B-Q4_K_M.gguf`, SHA-256
  `ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a`
- `openbmb/MiniCPM5-2B-GGUF` revision `2079a22f3beaa4e306449978533478fe0522f4b3`,
  `MiniCPM5-2B-Q4_K_M.gguf`, SHA-256
  `ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`
- `unsloth/gemma-4-E2B-it-GGUF` revision `0314792d7f1f7e229411f620751375812bb9faf2`,
  `gemma-4-E2B-it-Q4_K_M.gguf`, SHA-256
  `740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8`
- llama.cpp `b12211` (commit `7d7f02875`),
  `llama-b12211-bin-ubuntu-x64.tar.gz`, SHA-256
  `962924b5431bc1237a9e5d26ba072d37b6fe05f79b495206e7ff6134887624c5`

Pins for lane B:

- vLLM `0.27.1+cpu` wheel, cp38-abi3 manylinux\_2\_34 x86\_64
- `Qwen/Qwen3-0.6B` revision `c1899de289a04d12100db370d81485cdf75e47ca`

Lane B's weights digest and full lock are recorded when the profile lands.

### Tool calls are parsed in the Worker

Lane A disables llama-server's own tool-call parsing and returns raw text.
The Worker parses tool calls with Orchard's existing parser path, so lane
results reflect Orchard's parsing, not llama.cpp's. Slice 2 starts with the
Qwen3 family. A model whose tool format Orchard does not parse is excluded
from tool-call cases; on MLX, MiniCPM5-2B's XML tool calls were not parsed.

## Risks and trade-offs

- **CPU passes say nothing about Metal or GPU kernels.** The lanes complement
  the MLX and GPU lanes; they don't replace them.
- **llama.cpp is not production code.** Lane A covers Orchard's Worker seam
  and Controller path, not vLLM or MLX-LM behaviour.
- **GitHub-hosted runner CPUs vary.** Whether they expose AVX-512 is unknown,
  so lane B starts on self-hosted hosts only.
- **Supply chain.** Both lanes download pinned binaries or wheels. Digests are
  checked before use, and CI wiring falls under the supply-chain lane.
- **Model licenses.** Gemma 4's license must be confirmed from the publisher
  before its weights enter any automated lane.
- **Memory on 4-vCPU runners.** Gemma 4 E2B's 4.2 GB peak fits a 16 GB
  runner, but lane A may start with only Qwen3-0.6B and MiniCPM5-2B.

## Migration

Slices 1 and 2 add Worker-only code behind new, default-off selectors. Model
bundles, the catalog and the Controller are unchanged; the existing `mlx`,
`stub` and `vllm_poc` backends keep their behaviour.

Slice 3 needs an additive artifact format and adapter for GGUF. Under
`SPEC.md` §6.4, current `format`, `adapter` and `min_agent_capability`
values stay valid and authoritative until additive replacements pass separate
review. Slice 3 is therefore its own reviewed design before implementation.

## Open questions

- Do GitHub-hosted Linux runners reliably expose AVX-512? This decides
  whether lane B can ever run there.
- Is Gemma 4 E2B's license Apache-2.0 for the pinned GGUF build?
- Should lane A run on every pull request or only when Worker, tokenizer or
  dispatch paths change?
- Which self-hosted hosts run lane B, and who approves registering them?
