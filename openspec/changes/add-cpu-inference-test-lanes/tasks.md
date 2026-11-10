## 1. Contract

- [x] 1.1 Amend `SPEC.md` §1.5 so default-off CPU test-lane backends may exist as implementation evidence without a runtime-provider profile or support claim.
- [ ] 1.2 Get accountable product owner approval of the §1.5 amendment and accept ADR 0041; the decision index already lists it as proposed.
- [ ] 1.3 Confirm the license of Qwen3-0.6B, MiniCPM5-2B and Gemma 4 E2B, and of each pinned GGUF build, from the publisher before it enters any automated lane.
- [x] 1.4 Validate this change and all OpenSpec packages strictly.

## 2. Slice 1: lane A Worker conformance

- [ ] 2.1 First, run a streamed `/v1/completions` request with token IDs, a usage trailer and cancellation against the pinned `llama-server` on a Linux host, the combination the probes did not cover.
- [ ] 2.2 Add the default-off `llamacpp_cpu` Worker backend that runs one pinned, digest-checked CPU-only `llama-server` child per Worker instance on its own loopback port, with one slot, no offload device and no `--jinja`.
- [ ] 2.3 Keep the child in the Worker's process tree with death-with-Worker on Linux, verify its identity and model path through `/props` before admission, and stop and reap it on unload and shutdown; mark the Worker unhealthy when reaping is uncertain.
- [ ] 2.4 Send only authoritative prompt token IDs with `cache_prompt: false`, reject requests without IDs, fail on reported cached prompt tokens, require provider usage to equal the input count, and map streaming and terminal usage onto existing Worker events.
- [ ] 2.5 Implement cancellation through request-owned reader settlement within a bound, with native cessation unconfirmed and a sticky unhealthy latch for an unsettled reader.
- [ ] 2.6 Publish the diagnostic-only capability envelope on `Status`.
- [ ] 2.7 Add the host preflight (Linux, pinned architecture, AVX2 on x86, free memory, accelerator isolation) that runs before mutation.
- [ ] 2.8 Pin each model's upstream tokenizer source, add the vocabulary, decode and end-of-generation parity check, and record results and the special-token parse mode for Qwen3-0.6B, MiniCPM5-2B and Gemma 4 E2B.
- [ ] 2.9 Add the lane corpus with pinned threads, asserting protocol and semantic outcomes and treating JSON as prompted cases.
- [ ] 2.10 Cover every new branch, including a Worker crash and a stale server on the port, with model-free fake-provider tests, then run the corpus against real pinned models on a Linux host.

## 3. Slice 2: Worker-side tool calls

- [ ] 3.1 Add a provider-neutral Worker tool-call parser, starting with Hermes JSON for the Qwen3 family, and enable lane A tool-call cases for models it covers.
- [ ] 3.2 Exclude models whose tool format the parser does not cover from tool-call cases and record why.

## 4. Lane B: vLLM CPU profile (separate change)

- [ ] 4.1 Propose a change that modifies `linux-source-dev-inference-poc` and revises ADR 0037 in the same pull request, moving `vllm_poc` model identity, sampling, limits, prompt framing, reasoning framing and tool-parser family into frozen serving profiles, with the Qwen3.8-27B profile as the default.
- [ ] 4.2 Specify a lane B harness that launches the pinned vLLM CPU server, verifies the wheel and weights digests, enforces and records its argv and environment, and runs the AVX-512F preflight before mutation.

## 5. CI wiring (separately approved)

- [ ] 5.1 Wire lane A as a non-required GitHub-hosted Linux job after `make supply-chain` passes for the new pins.
- [ ] 5.2 Decide lane A's trigger: every pull request or only Worker, tokenizer and dispatch changes.
- [ ] 5.3 Register self-hosted hosts for lane B only with owner approval; keep it nightly or on demand.

## 6. Slice 3: end-to-end source dev (separate design)

- [ ] 6.1 Design an additive `gguf` artifact format and `llama_cpp` adapter under `SPEC.md` §6.4 migration rules, reviewed before implementation.
- [ ] 6.2 Only after that review, run the lane corpus through the Controller and Node in source development.
