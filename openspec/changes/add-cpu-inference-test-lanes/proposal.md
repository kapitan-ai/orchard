## Why

Orchard runs real inference only on Apple Silicon. The real MLX Worker tests
need Metal, the pinned Qwen3-0.6B smoke bundle is not a CI gate, and the
Linux Node qualification gates are model-free. Linux CI runners, orbs and
contributor machines without an accelerator therefore never push real tokens
through Orchard's Worker seam.

Bounded probes on 2026-11-09 showed that two CPU runtimes cover the
behaviours Orchard relies on:

- **llama.cpp** runs pinned 4-bit GGUF models on ordinary x86 and ARM CPUs.
  It starts in about a second, needs 1.2–4.2 GB for the candidate models,
  and decodes Qwen3-0.6B at 94–150 tok/s on four to eight threads.
- **vLLM 0.27.1's CPU build** runs the same engine as Orchard's Linux GPU path.
  On an AVX-512/AMX host it starts in about 90 s, needs about 5.2 GB, and
  decodes Qwen3-0.6B at 29–49 tok/s. Its docs give AVX2 hosts only basic
  support.

On both runtimes these passed:

- streaming with a final usage chunk and `[DONE]`
- cancellation followed by a successful next request
- tool calls and `json_object` output
- prompts supplied as token IDs on `/v1/completions`, which is how Orchard's
  Worker adapter sends them

Greedy output was not byte-identical across thread counts on a 256-token
prompt, and prefix caching changed output on both runtimes.

SGLang was considered and rejected for this purpose: its CPU backend requires
Intel AMX.

## What Changes

- Define two default-off **CPU inference test lanes**. They produce
  implementation evidence only, never qualification or support evidence:
  - **Lane A (llama.cpp, any CPU):** a separately selected `llamacpp_cpu`
    backend behind the existing local gRPC Worker service. It supervises a
    pinned CPU-only `llama-server` on loopback, with one slot and concurrency
    one, and loads a pinned GGUF artifact. It is intended for frequent checks
    on GitHub-hosted Linux runners and developer machines.
  - **Lane B (vLLM CPU, chosen AVX-512 hosts):** the existing `vllm_poc`
    adapter, generalized from its hard-wired Qwen3.8-27B tuple to a frozen
    serving profile. It adds a CPU profile pinned to the vLLM 0.27.1 CPU
    wheel and Qwen/Qwen3-0.6B in BF16. It is intended for nightly or
    on-demand runs on self-hosted hosts that pass an AVX-512 preflight.
- Pin each lane's runtime build, model revisions and file digests. Fail
  before mutation on a digest mismatch or an unmet host preflight.
- Share one lane test corpus. It asserts protocol and semantic outcomes, not
  exact prose across hosts, thread counts or runtimes. Every lane run
  disables prefix caching and pins its thread count.
- Gate lane A on **tokenizer parity**: for each pinned model, the GGUF's
  embedded tokenizer must produce the same token IDs as `orchard_tokenizer`
  on a fixed corpus. A mismatch keeps that model out of the lane.
- Assign model roles for lane A:
  - Qwen3-0.6B Q4\_K\_M: plumbing only.
  - MiniCPM5-2B Q4\_K\_M: exact-answer quick check.
  - Gemma 4 E2B Q4\_K\_M: behaviour baseline, admitted only after its
    license is confirmed.
- Slice the work:
  1. Worker-level conformance through the gRPC Worker service, with no
     Controller, catalog or bundle-format change.
  2. Worker-side tool-call parsing, starting with the Qwen3 family.
  3. End-to-end source-dev runs through the Controller and Node. These need
     an additive `gguf` artifact format and `llama_cpp` adapter under
     `SPEC.md` §6.4's migration rules, reviewed separately before
     implementation.
- Record the runtime choice in ADR 0041.

## Capabilities

### New Capabilities

- `cpu-inference-test-lanes`: default-off CPU-only Worker test lanes, their
  pins, preflights, shared corpus and evidence boundary.

### Modified Capabilities

None.

## Impact

`SPEC.md` impact: **§1.5 is amended in this change.** The amendment permits
separately selected, default-off CPU test-lane backends behind the existing
Worker contract as implementation evidence only. They are not runtime-provider
profiles and grant no runtime-provider, platform, model, acceleration or
agentic execution qualification or support. They must pin artifacts by digest,
verify the host before mutation, and keep accelerators hidden. The amendment
takes effect only when the accountable product owner merges it. Until then
this package authorizes design review only.

`SPEC.md` sections that stay unchanged and authoritative:

- §1.4 profile kinds
- §4.10 Worker contract
- §6.4 bundle format; slice 3's additive format change is reviewed separately
- §7.5.3 stream-mode concurrency one
- Milestone 9
- ADR 0035

Lane B changes ADR 0037's adapter boundary: its fixed Qwen3.8 tuple and its
pinned sampling of temperature 1.0 become one frozen profile among several.
That requires an ADR 0037 revision in the same pull request as the
generalization.

Lane A adds a pinned binary download and lane B a pinned wheel. Both fall
under the supply-chain lane when CI wiring lands.

This change grants no live host execution, self-hosted runner registration,
required-check promotion, model qualification, Linux Node qualification,
or support claim. Each requires its own approval.
