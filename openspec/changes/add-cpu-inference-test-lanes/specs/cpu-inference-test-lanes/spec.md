## ADDED Requirements

### Requirement: CPU test lanes are default-off implementation evidence

Orchard MAY provide CPU inference test lanes that run real models through the
existing local gRPC Worker service on hosts without an accelerator. Each lane
backend SHALL be separately selected and default-off. The default Worker
backend, the MLX-LM runtime and its locks SHALL remain unchanged.

Lane results SHALL be implementation evidence only. They SHALL NOT establish a
runtime-provider profile, platform, model, acceleration or agentic execution
qualification, production activation or support claim under `SPEC.md` §1.4
and §1.5.

#### Scenario: Worker starts without a lane selector

- **WHEN** a Worker starts without explicitly selecting a CPU lane backend
- **THEN** it uses its existing backend selection and starts no CPU lane runtime

#### Scenario: Lane results are cited as support

- **WHEN** documentation, diagnostics or a qualification record cites a passing CPU lane
- **THEN** it describes the result as implementation evidence and makes no runtime-provider, platform or model support claim

### Requirement: Lane A runs pinned GGUF models through llama.cpp on CPU

The `llamacpp_cpu` lane backend SHALL supervise exactly one CPU-only
llama.cpp server child per Worker, bound to loopback, with one slot,
concurrency one, a pinned context length, a pinned thread count and no GPU
offload. It SHALL use a pinned llama.cpp release whose archive digest is
verified before use, and pinned GGUF files whose digests are verified before
load.

The Worker SHALL send Orchard's authoritative prompt token IDs and SHALL NOT
ask llama.cpp to render or retokenize prompts. Provider usage SHALL equal the
Controller's input token count. Unload and Worker shutdown SHALL stop and reap
the child. A child that cannot be reaped SHALL make the Worker unhealthy and
deny admission until the Worker is replaced.

#### Scenario: Artifact digest differs from its pin

- **WHEN** a runtime archive or GGUF file digest differs from its pinned value
- **THEN** the Worker fails before starting the server child or loading the model

#### Scenario: Provider usage disagrees

- **WHEN** the provider reports an input token count different from the supplied prompt IDs
- **THEN** the generation fails closed rather than reporting provider usage as authoritative

#### Scenario: Server child survives unload

- **WHEN** the Worker cannot confirm the server child exited after unload or shutdown
- **THEN** the Worker reports itself unhealthy and refuses further admission until replacement

### Requirement: Lane A admits a model only after tokenizer parity

A GGUF model SHALL enter lane A only after its embedded tokenizer produces the
same token IDs as `orchard_tokenizer` for every entry in a fixed parity corpus.
The corpus SHALL cover ASCII, non-Latin scripts, emoji, whitespace runs and
every special or control token the model's template emits.

#### Scenario: Embedded tokenizer disagrees

- **WHEN** any parity corpus entry encodes to different IDs under the two tokenizers
- **THEN** that model is excluded from lane A and the mismatch is reported

### Requirement: Lane B runs vLLM's CPU build through a frozen serving profile

The `vllm_poc` adapter SHALL take its model identity, served name, sampling
controls and token limits from a frozen serving profile rather than module
constants. The existing Qwen3.8-27B profile SHALL keep its current behaviour.
A CPU profile SHALL pin the vLLM 0.27.1 CPU build and Qwen/Qwen3-0.6B in BF16,
with `--max-num-seqs 1`, prefix caching disabled and greedy sampling.

Lane B SHALL keep ADR 0037's cancellation boundary: native cessation remains
unconfirmed, and admission resumes only after the request-owned reader
settles within its bound.

#### Scenario: Existing tuple after generalization

- **WHEN** the adapter runs with the Qwen3.8-27B profile
- **THEN** its validation, sampling, tool parsing and cancellation behaviour match the behaviour before generalization

#### Scenario: Request does not match the loaded profile

- **WHEN** a request's model, sampling controls or token limits fall outside the loaded frozen profile
- **THEN** the Worker rejects it before provider generation

### Requirement: Lanes preflight their host before mutation

Before downloading, unpacking or starting anything, each lane SHALL check the
host's operating system, architecture, required CPU features, free memory
against the profile's recorded peak plus margin, and accelerator isolation.
Lane A on x86 SHALL require AVX2. Lane B SHALL require AVX-512F.

A failed preflight SHALL skip the lane with a recorded reason and SHALL NOT
report a pass.

#### Scenario: Host lacks AVX-512 for lane B

- **WHEN** lane B's preflight runs on a host without AVX-512F
- **THEN** the lane is skipped before mutation with the missing feature recorded

#### Scenario: Accelerator is visible

- **WHEN** a lane run would make a GPU visible to the runtime
- **THEN** the lane refuses to start rather than producing CPU-labelled evidence from an accelerator

### Requirement: Lane corpus asserts protocol and semantic outcomes

Both lanes SHALL share one test corpus covering load, generate, streaming
deltas, exactly one terminal event, terminal usage, cancellation followed by a
successful request, unload, client tool calls and `json_object` output where
the model and parser support them.

Every lane run SHALL disable prefix caching and pin its thread count. Tests
SHALL assert protocol and semantic outcomes. Exact generated text MAY be
asserted only within one runtime, host class and thread count, and SHALL NOT be
compared across runtimes or thread counts.

#### Scenario: Thread count changes generated prose

- **WHEN** a lane runs with a different thread count than a recorded run
- **THEN** semantic and protocol assertions still apply, and no exact-text comparison is made between the two runs

#### Scenario: Cancellation mid-stream

- **WHEN** a client cancels a lane generation after its first deltas
- **THEN** the request-owned reader settles within its bound, the Worker emits one cancelled terminal, and the next request completes without claiming confirmed native cessation
