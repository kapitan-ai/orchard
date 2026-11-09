## 1. Contract

- [x] 1.1 Amend `SPEC.md` §1.5 so default-off CPU test-lane backends may exist as implementation evidence without a runtime-provider profile or support claim.
- [ ] 1.2 Get accountable product owner approval of the §1.5 amendment and accept ADR 0040; the decision index already lists it as proposed.
- [ ] 1.3 Confirm the Gemma 4 E2B license for the pinned GGUF build from the publisher before it enters any automated lane.
- [x] 1.4 Validate this change and all OpenSpec packages strictly.

## 2. Slice 1: lane A Worker conformance

- [ ] 2.1 Add the default-off `llamacpp_cpu` Worker backend that supervises one pinned, digest-checked CPU-only `llama-server` child on loopback with one slot and no GPU offload.
- [ ] 2.2 Send authoritative prompt token IDs to `/v1/completions`, require provider usage to equal the input count, and map streaming, terminal usage and cancellation onto existing Worker events.
- [ ] 2.3 Stop and reap the child on unload and shutdown; mark the Worker unhealthy when reaping is uncertain.
- [ ] 2.4 Add the host preflight (OS, architecture, AVX2 on x86, free memory, accelerator isolation) that runs before mutation.
- [ ] 2.5 Add the tokenizer parity check and record results for Qwen3-0.6B, MiniCPM5-2B and Gemma 4 E2B.
- [ ] 2.6 Add the shared lane corpus with prefix caching off and pinned threads, asserting protocol and semantic outcomes.
- [ ] 2.7 Cover every new branch with model-free fake-provider tests, then run the corpus against real pinned models on a Linux host.

## 3. Slice 2: Worker-side tool calls

- [ ] 3.1 Disable llama-server tool parsing and parse tool calls with Orchard's Worker parser, starting with the Qwen3 family.
- [ ] 3.2 Exclude models whose tool format Orchard cannot parse from tool-call cases and record why.

## 4. Lane B: vLLM CPU profile

- [ ] 4.1 Move `vllm_poc` model identity, sampling and limits into frozen serving profiles; keep the Qwen3.8-27B profile's behaviour and tests unchanged.
- [ ] 4.2 Revise ADR 0037 in the same pull request to describe the profile boundary.
- [ ] 4.3 Add the CPU profile pinning the vLLM 0.27.1 CPU wheel and Qwen/Qwen3-0.6B BF16 with `--max-num-seqs 1`, prefix caching off and greedy sampling.
- [ ] 4.4 Add the AVX-512F preflight and run the shared corpus on an approved self-hosted host.

## 5. CI wiring (separately approved)

- [ ] 5.1 Wire lane A as a non-required GitHub-hosted Linux job after `make supply-chain` passes for the new pins.
- [ ] 5.2 Decide lane A's trigger: every pull request or only Worker, tokenizer and dispatch changes.
- [ ] 5.3 Register self-hosted hosts for lane B only with owner approval; keep it nightly or on demand.

## 6. Slice 3: end-to-end source dev (separate design)

- [ ] 6.1 Design an additive `gguf` artifact format and `llama_cpp` adapter under `SPEC.md` §6.4 migration rules, reviewed before implementation.
- [ ] 6.2 Only after that review, run the lane corpus through the Controller and Node in source development.
