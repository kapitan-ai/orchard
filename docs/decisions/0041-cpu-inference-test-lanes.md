# ADR 0041: CPU inference test lanes use llama.cpp and vLLM's CPU build

## Status

Proposed on 2026-11-09 under the OpenSpec change `add-cpu-inference-test-lanes`.
It chooses test-lane runtimes only. It is not a runtime-provider profile, a qualification record or a support claim under `SPEC.md` §1.4 and §1.5.

## Context

Orchard runs real inference only through the MLX-LM Worker on Apple Silicon and Metal.
Linux CI runners, orbs and contributor machines without an accelerator exercise the Worker seam only with the `stub` backend.
The Linux GPU direction is the default-off `vllm_poc` adapter ([ADR 0037](0037-bounded-linux-source-development-inference-poc.md)) and the Milestone 9 one-H100 pilot.

Three Linux runtimes were compared for a CPU-only lane: llama.cpp, vLLM's CPU build and SGLang.
Bounded probes on 2026-11-09, run against each runtime's own server, found:

- llama.cpp b12211 ran pinned Q4\_K\_M GGUF models on ordinary x86 CPUs, starting in about a second with 1.2–4.2 GB of memory.
- vLLM 0.27.1's CPU build ran Qwen3-0.6B in BF16 on an AVX-512/AMX host, starting in about 90 s with about 5.2 GB. Its docs give AVX2 hosts only basic support.
- Both passed streaming, cancellation, tool calls, `json_object` output and token-ID prompts.
- Greedy output changed with thread count and with prefix caching on both.
- SGLang's CPU backend requires Intel AMX, so it cannot serve commodity CPUs.

## Decision

Use two default-off CPU test lanes:

- **Lane A, llama.cpp:** a separately selected `llamacpp_cpu` Worker backend for any AVX2 or ARM CPU, run frequently.
- **Lane B, vLLM CPU:** the `vllm_poc` adapter generalized to frozen serving profiles, with a CPU profile for chosen AVX-512 hosts, run nightly or on demand.

Do not use SGLang for CPU lanes.
Lane tests assert protocol and semantic outcomes with prefix caching off and pinned thread counts, not exact prose across hosts or runtimes.

## Consequences

Orchard gets real-token coverage of the Worker seam without an accelerator, and a second real provider tests the provider-neutral contract in [ADR 0025](0025-provider-neutral-worker-runtime-contract.md).
Lane A does not exercise vLLM or MLX-LM behaviour, and neither lane covers Metal or GPU kernels.
GGUF needs tokenizer parity checks against `orchard_tokenizer`, and an end-to-end path needs an additive artifact format under `SPEC.md` §6.4, reviewed separately.
Lane B makes ADR 0037's fixed tuple one profile among several, so ADR 0037 must be revised with that change.
Both lanes add pinned downloads to the supply-chain surface.

## SPEC.md impact

§1.5 is amended in the same change to permit default-off CPU test-lane backends as implementation evidence without a runtime-provider profile or support claim.
§1.4, §4.10, §6.4, §7.5.3, Milestone 9 and ADR 0035 remain unchanged.
