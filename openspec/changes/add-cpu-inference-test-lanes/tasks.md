## 1. Contract

- [x] 1.1 Amend `SPEC.md` §1.5 so default-off CPU test-lane backends may exist as implementation evidence without a runtime-provider profile or support claim.
- [x] 1.2 Get accountable product owner approval of the §1.5 amendment and accept ADR 0041; the product owner accepted both on 2026-11-13, and the decision index lists ADR 0041 as accepted.
- [ ] 1.3 Confirm the license of Qwen3-0.6B, MiniCPM5-2B and Gemma 4 E2B, and of each pinned GGUF build, from the publisher before it enters any automated lane.
- [x] 1.4 Validate this change and all OpenSpec packages strictly.

## 2. Slice 1: lane A Worker conformance

- [ ] 2.1 First, run a streamed `/v1/completions` request with token IDs, a usage trailer and cancellation against the pinned `llama-server` on a Linux host, the combination the probes did not cover.
- [ ] 2.2 Add the default-off `llamacpp_cpu` Worker backend that runs one pinned, digest-checked CPU-only `llama-server` child per Worker instance on its own loopback port, launched with `-m <verified GGUF> --no-jinja --special -np 1 --no-cache-prompt --cache-ram 0 --no-slots --device none -ngl 0`, a pinned context and thread count, never `-hf`, `-mu` or `-dr`, an allowlisted environment with `HOME` and `XDG_CONFIG_HOME` on an empty per-launch directory, an owner-only key file, and a working directory with no ggml libraries; refuse admission on a "using config file" startup line.
- [ ] 2.3 Keep the child in the Worker's process tree with `PR_SET_PDEATHSIG` from a Worker-lifetime thread plus a `getppid()` check, give each launch a nonce `--alias` and an `--api-key-file`, verify `model_alias`, `model_path`, `total_slots == 1`, the pinned `n_ctx` and neutral default samplers through `/props`, and a CPU-only mapped backend set through `/proc/<pid>/maps` before admission, and stop and reap the child on unload and shutdown; mark the Worker unhealthy when reaping is uncertain.
- [ ] 2.4 Send only authoritative prompt token IDs with `cache_prompt: false` and `timings_per_token`, reject requests without IDs, send a complete sampler (request temperature, request top-p only inside (0, 1) and 1 otherwise, neutral top-k, min-p, penalties and other samplers, a pinned seed), map stop sequences, set `n_predict` to `max_output_tokens` and reject 0 or input plus output above the context, reject token-ID output, logprobs and unmapped controls, read `timings.cache_n` from the first chunk before forwarding its text and fail when it is above zero or missing, require provider usage to equal the input count, and map streaming and terminal usage onto existing Worker events.
- [ ] 2.5 Return generated text as answer content with no reasoning evidence, render corpus prompts with thinking disabled, and fail cases whose output contains the reasoning-open marker.
- [ ] 2.6 Implement cancellation through request-owned reader settlement within a bound, with native cessation unconfirmed and a sticky unhealthy latch for an unsettled reader.
- [ ] 2.7 Publish the complete diagnostic-only capability envelope on `Status`, with an empty cache capability set and no loaded-binding or reasoning evidence.
- [ ] 2.8 Add the host preflight (Linux, pinned architecture, AVX2 on x86, free memory, backend-availability accelerator isolation, no `/etc/llama.cpp/config.ini`) that runs before mutation.
- [ ] 2.9 Pin each model's upstream tokenizer source including `generation_config.json`, add the reference-range vocabulary, decode and end-of-generation containment checks, and record results, extra GGUF end-of-generation IDs classified by reference token class (ordinary-text extras as divergences no corpus case depends on) and the special-token parse mode for Qwen3-0.6B, MiniCPM5-2B and Gemma 4 E2B.
- [ ] 2.10 Add the lane corpus with pinned threads and the mapped CPU variant recorded, asserting protocol and semantic outcomes, running exact cases at temperature 0 with the pinned seed, and treating JSON as prompted cases.
- [ ] 2.11 Cover every new branch, including a Worker crash, a stale server on the port, an overriding launch environment or configuration file, an unset top-p and an oversized output budget, with model-free fake-provider tests, then run the corpus against real pinned models on a Linux host.

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

- [ ] 6.1 Design an additive `gguf` artifact format and `llama_cpp` adapter under `SPEC.md` §6.4 migration rules, reviewed before implementation. End-to-end runs need `ORCHARD_TOKENIZER_SAFE_MODE=reject`, because the default `off` mode strips prompt token IDs.
- [ ] 6.2 Only after that review, run the lane corpus through the Controller and Node in source development.
