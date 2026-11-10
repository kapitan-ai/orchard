## ADDED Requirements

### Requirement: CPU test lanes are default-off implementation evidence

Orchard MAY provide CPU inference test lanes that run real models through the
existing local gRPC Worker service on hosts without an accelerator. Each lane
backend SHALL be separately selected and default-off. The default Worker
backend, the MLX-LM runtime and its locks SHALL remain unchanged. The
requirements in this capability specify lane A, the `llamacpp_cpu` Worker
backend.

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

The `llamacpp_cpu` lane backend SHALL run exactly one llama.cpp server child
per Worker instance from a pinned CPU-only llama.cpp release build whose
archive digest is verified before use, and SHALL load pinned GGUF files whose
digests are verified before load. The child SHALL bind to a loopback port
owned by that Worker instance, with one slot, concurrency one, a pinned
context length, a pinned thread count, no accelerator device, and the
server's own chat-template rendering and tool-call parsing disabled. Before
admission, the Worker SHALL confirm through the server that it is the child
this Worker instance started and that it serves the pinned model file.

The child SHALL stay inside the Worker's process tree and SHALL terminate when
the Worker exits, including when the Worker crashes. Unload and Worker
shutdown SHALL stop and reap the child. A child that cannot be reaped SHALL
make the Worker unhealthy and deny admission until the Worker is replaced.

The Worker's `Status` SHALL publish a truthful capability envelope for the
lane, naming its provider identity and version, the `gguf` artifact format,
CPU acceleration and concurrency one. That evidence SHALL remain
diagnostic-only under `SPEC.md` §4.10.

#### Scenario: Artifact digest differs from its pin

- **WHEN** a runtime archive or GGUF file digest differs from its pinned value
- **THEN** the Worker fails before starting the server child or loading the model

#### Scenario: Server child survives unload

- **WHEN** the Worker cannot confirm the server child exited after unload or shutdown
- **THEN** the Worker reports itself unhealthy and refuses further admission until replacement

#### Scenario: Worker crashes while its server child runs

- **WHEN** the Worker process exits abnormally while its server child is running
- **THEN** the child terminates with it, and a replacement Worker starts and verifies its own child rather than serving through the previous one

#### Scenario: Loopback port answers with another server

- **WHEN** the Worker's loopback port is answered by a server it did not start, or by one serving a different model file
- **THEN** the Worker refuses admission before provider generation

### Requirement: Lane A generates only from authoritative prompt token IDs

The Worker SHALL send Orchard's authoritative prompt token IDs to the server's
`/v1/completions` endpoint as a flat list and SHALL require their count to
equal the request's input token count. It SHALL NOT send rendered prompt text
or ask llama.cpp to render or retokenize prompts. Unlike providers that fall
back to rendered text, lane A SHALL reject a request that carries no prompt
token IDs before provider generation.

Every lane A request SHALL disable the server's prompt cache, and the Worker
SHALL fail the generation if the server reports reused prompt tokens.
Provider usage SHALL equal the Controller's input token count.

#### Scenario: Prompt token IDs are absent

- **WHEN** a lane A request carries rendered prompt text but no prompt token IDs
- **THEN** the Worker rejects it before provider generation and sends no prompt text to the server

#### Scenario: Provider usage disagrees

- **WHEN** the provider reports an input token count different from the supplied prompt IDs
- **THEN** the generation fails closed rather than reporting provider usage as authoritative

#### Scenario: Server reuses cached prompt tokens

- **WHEN** the server reports that a lane A generation reused cached prompt tokens
- **THEN** the generation fails rather than returning output produced from cached state

### Requirement: Lane A admits a model only after tokenizer parity

A GGUF model SHALL enter lane A only after parity with `orchard_tokenizer`
loaded from a pinned upstream tokenizer source: a repository revision and the
file digests of its tokenizer, tokenizer configuration and chat template.
Parity SHALL require that:

- the GGUF vocabulary maps every token ID to the same piece as the pinned
  source
- decoding each parity corpus entry's token IDs yields identical bytes under
  both tokenizers, including special and control tokens
- both define the same set of end-of-generation token IDs

The corpus SHALL cover ASCII, non-Latin scripts, emoji, whitespace runs and
every special or control token the model's template emits. The parity record
SHALL state the special-token parse mode used to encode the corpus.

#### Scenario: Embedded tokenizer disagrees

- **WHEN** any vocabulary piece, decoded corpus entry or end-of-generation ID differs between the two tokenizers
- **THEN** that model is excluded from lane A and the mismatch is reported

#### Scenario: Tokenizer source is not pinned

- **WHEN** a GGUF model has no pinned upstream tokenizer source with recorded digests
- **THEN** that model is not admitted to lane A

### Requirement: Lane A cancellation settles its reader without claiming cessation

On cancellation, lane A SHALL close the request-owned stream reader and wait
for it to settle within a fixed bound before it emits exactly one cancelled
terminal and admits the next request. It SHALL record native cessation as
unconfirmed. Server slot or process state SHALL NOT be presented as
confirmation of native cessation. A reader that does not settle within its
bound SHALL latch the Worker unhealthy and deny new admission until the Worker
is replaced, including after logical unload and reload.

#### Scenario: Cancellation mid-stream

- **WHEN** a client cancels a lane A generation after its first deltas
- **THEN** the request-owned reader settles within its bound, the Worker emits one cancelled terminal, and the next request completes without claiming confirmed native cessation

#### Scenario: Reader does not settle

- **WHEN** the request-owned reader has not settled when its bound expires
- **THEN** the Worker latches unhealthy and denies new admission until replacement, even after unload and reload

### Requirement: Lane A preflights its host before mutation

Before downloading, unpacking or starting anything, lane A SHALL check that
the host runs Linux on an architecture with a pinned CPU-only release build,
that an x86 host has AVX2, that free memory covers the model's recorded peak
plus margin, and that no accelerator is visible to the server child.

A failed preflight SHALL skip the lane with a recorded reason and SHALL NOT
report a pass.

#### Scenario: Host has no pinned CPU-only build

- **WHEN** lane A's preflight runs on a host whose operating system or architecture has no pinned CPU-only release build, such as macOS
- **THEN** the lane is skipped before mutation with the reason recorded

#### Scenario: Accelerator is visible

- **WHEN** a lane A run would make an accelerator visible to the server child
- **THEN** the lane refuses to start rather than producing CPU-labelled evidence from an accelerator

### Requirement: Lane corpus asserts protocol and semantic outcomes

Lane A SHALL run a shared lane corpus covering load, generate, streaming
deltas, exactly one terminal event, terminal usage, cancellation followed by a
successful request, unload, and client tool calls for models whose tool format
the Worker parses. JSON output cases SHALL be prompted cases whose output the
test validates. Lane A SHALL NOT claim `json_object` enforcement and SHALL NOT
simulate it through an internal provider field.

Every lane run SHALL pin its thread count. Tests SHALL assert protocol and
semantic outcomes. Exact generated text MAY be asserted only within one
runtime, host class and thread count, and SHALL NOT be compared across
runtimes or thread counts.

#### Scenario: Thread count changes generated prose

- **WHEN** a lane runs with a different thread count than a recorded run
- **THEN** semantic and protocol assertions still apply, and no exact-text comparison is made between the two runs

#### Scenario: Prompted JSON case returns invalid JSON

- **WHEN** a prompted JSON case returns text that is not the expected JSON
- **THEN** the case reports a model behaviour failure and no structured-output enforcement is claimed
