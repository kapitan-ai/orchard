## Why

Orchard runs real inference only on Apple Silicon. The real MLX Worker tests
need Metal, the pinned Qwen3-0.6B smoke bundle is not a CI gate, and the
Linux Node qualification gates are model-free. Linux CI runners, orbs and
contributor machines without an accelerator therefore never push real tokens
through Orchard's Worker seam.

Bounded probes on 2026-11-09 ran two CPU runtimes against their own servers,
not through Orchard's Worker:

- **llama.cpp** ran pinned 4-bit GGUF models on x86 CPUs and started in about
  a second. On an 8-vCPU x86 orb it decoded Qwen3-0.6B at 78 / 48 tok/s on
  8 / 4 threads, with peaks of 1.2–4.2 GB across the candidate models. On a
  32-vCPU Xeon Platinum 8592+ host with AMX, pinned to 8 / 4 CPUs, it decoded
  Qwen3-0.6B at 150 / 94 tok/s with a 1.41–1.46 GiB peak.
- **vLLM 0.27.1's CPU build** runs the same engine as Orchard's Linux GPU path.
  On the same Xeon host it started in about 90 s, peaked at 5.17–5.20 GiB, and
  decoded Qwen3-0.6B at 49 / 29 tok/s. Its docs give AVX2 hosts only basic
  support.

On both runtimes these passed, all on `/v1/chat/completions` unless noted:

- streaming with a final usage chunk and `[DONE]`
- cancellation followed by a successful next request
- tool calls through each server's own parser, and `json_object` output
  through each runtime's own enforcement
- a non-streamed token-ID prompt on `/v1/completions`

The Worker's actual path, a streamed `/v1/completions` request with token IDs,
a usage trailer and cancellation, was not run on either runtime. It is slice
1's first check.

Greedy output was not byte-identical across thread counts for a 200-token
prompt with 256 generated tokens. With prefix caching on, repeated greedy
runs differed on llama.cpp at both thread counts and on vLLM at 8 threads.

SGLang was considered and rejected for this purpose: its CPU backend requires
Intel AMX.

## What Changes

- Define two default-off **CPU inference test lanes**. They produce
  implementation evidence only, never qualification or support evidence:
  - **Lane A (llama.cpp, Linux CPU):** a separately selected `llamacpp_cpu`
    backend behind the existing local gRPC Worker service. It runs a pinned
    CPU-only `llama-server` child on a Worker-owned loopback port, with one
    slot and concurrency one, and loads a pinned GGUF artifact. It is intended
    for frequent checks on GitHub-hosted Linux runners and Linux developer
    machines. This change specifies lane A.
  - **Lane B (vLLM CPU, chosen AVX-512 hosts):** design direction only. A
    later change generalizes the `vllm_poc` adapter to frozen serving
    profiles, with a CPU profile for the vLLM 0.27.1 CPU wheel and
    Qwen/Qwen3-0.6B in BF16, run by a lane harness on self-hosted hosts that
    pass an AVX-512 preflight.
- Pin lane A's runtime build, model revisions, file digests and upstream
  tokenizer sources. Fail before mutation on a digest mismatch or an unmet
  host preflight.
- Launch the llama-server child with an explicit argument list (no template
  renderer, no prompt or host-memory cache, one slot, no offload device) from
  a scrubbed environment. Keep it inside the Worker's process tree, give each
  launch its own alias nonce and API key, verify both before admission, and
  stop it with the Worker.
- Send only authoritative prompt token IDs with a complete sampler and the
  prompt cache off. Reject requests without IDs and unmapped controls, and
  fail before the first delta if the server reports reused prompt tokens.
- Serve thinking-disabled prompts only, with no reasoning evidence.
- Settle cancellation through the request-owned reader with native cessation
  unconfirmed, and latch the Worker unhealthy when the reader does not settle.
- Run one lane test corpus. It asserts protocol and semantic outcomes, not
  exact prose across hosts, thread counts or runtimes. JSON cases are prompted
  and validated, not enforced.
- Gate lane A on **tokenizer parity** between each GGUF and `orchard_tokenizer`
  from a pinned upstream tokenizer source: identical pieces over the pinned
  tokenizer's ID range, decode parity on a fixed corpus, and the generation
  configuration's end-of-sequence IDs contained in the GGUF's set. A mismatch
  keeps that model out of the lane.
- Assign model roles for lane A:
  - Qwen3-0.6B Q4\_K\_M: plumbing only.
  - MiniCPM5-2B Q4\_K\_M: exact-answer quick check.
  - Gemma 4 E2B Q4\_K\_M: behaviour baseline.
  Each model is admitted only after its license is confirmed from the
  publisher.
- Slice the work:
  1. Worker-level conformance through the gRPC Worker service, with no
     Controller, catalog or bundle-format change.
  2. A provider-neutral Worker tool-call parser, starting with Qwen3's Hermes
     JSON format.
  3. End-to-end source-dev runs through the Controller and Node. These need
     an additive `gguf` artifact format and `llama_cpp` adapter under
     `SPEC.md` §6.4's migration rules, reviewed separately before
     implementation.
- Record the runtime choice in ADR 0041.

## Capabilities

### New Capabilities

- `cpu-inference-test-lanes`: default-off CPU-only Worker test lanes; this
  change specifies lane A's pins, custody, preflight, tokenizer parity,
  cancellation, shared corpus and evidence boundary.

### Modified Capabilities

None. Lane B will modify `linux-source-dev-inference-poc`, which the pending
change `prove-bounded-linux-source-dev-inference` defines, in its own change.

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
- §7.2.4 structured output; lane JSON cases claim no enforcement
- §7.5.3 stream-mode concurrency one
- Milestone 9
- ADR 0035

Lane B is out of this change's requirements. The `linux-source-dev-inference-poc`
capability and ADR 0037 pin `vllm_poc` to temperature 1.0 and top-p 0.95, two
thinking prompt suffixes, port 58080 and a supervisor that requires a GPU
identity. A greedy CPU profile contradicts those pins, so the lane B change
must modify that capability and revise ADR 0037 in the same pull request.

Lane A adds a pinned binary download, and lane B will add a pinned wheel. Both
fall under the supply-chain lane when CI wiring lands.

This change grants no live host execution, self-hosted runner registration,
required-check promotion, model qualification, Linux Node qualification,
or support claim. Each requires its own approval.
