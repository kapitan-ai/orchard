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

### Requirement: Lane A launches a pinned CPU-only llama.cpp server

The `llamacpp_cpu` lane backend SHALL run exactly one llama.cpp server child
per Worker instance from a pinned CPU-only llama.cpp release build whose
archive digest is verified before use, and SHALL load pinned GGUF files whose
digests are verified before load.

The Worker SHALL launch the child with an explicit argument list that sets
one slot, a pinned context length, a pinned thread count and no offload
device, and that disables the server's chat-template renderer, its prompt
cache and its host-memory prompt cache. The child SHALL start from an
environment with no llama.cpp argument, ggml or accelerator variables, in a
working directory that contains no runtime libraries.

#### Scenario: Artifact digest differs from its pin

- **WHEN** a runtime archive or GGUF file digest differs from its pinned value
- **THEN** the Worker fails before starting the server child or loading the model

#### Scenario: Launch environment would override the pinned arguments

- **WHEN** the Worker's environment carries a llama.cpp argument, ggml or accelerator variable
- **THEN** the child starts without it, and its effective settings match the pinned argument list

### Requirement: Lane A owns and verifies its server child

The child SHALL bind to a loopback port owned by that Worker instance and
SHALL require a per-launch credential on every request. Its slot inspection
endpoint SHALL be disabled. Before admission, the Worker SHALL confirm through
the server's properties that it serves the per-launch identity this Worker
instance assigned, the pinned model file and exactly one slot, and SHALL
confirm that only the CPU backend loaded.

The child SHALL stay inside the Worker's process tree and SHALL terminate when
the Worker exits, including when the Worker crashes. Unload and Worker
shutdown SHALL stop and reap the child. A child that cannot be reaped SHALL
make the Worker unhealthy and deny admission until the Worker is replaced.
The Node Agent SHALL remain the lifecycle and cleanup owner of the Worker
process tree under `SPEC.md` §4.10.

#### Scenario: Server child survives unload

- **WHEN** the Worker cannot confirm the server child exited after unload or shutdown
- **THEN** the Worker reports itself unhealthy and refuses further admission until replacement

#### Scenario: Worker crashes while its server child runs

- **WHEN** the Worker process exits abnormally while its server child is running
- **THEN** the child terminates with it, and a replacement Worker starts and verifies its own child rather than serving through the previous one

#### Scenario: Loopback port answers with another server

- **WHEN** the Worker's loopback port is answered by a server without this launch's identity, or by one serving a different model file, more than one slot or a non-CPU backend
- **THEN** the Worker refuses admission before provider generation

### Requirement: Lane A publishes a diagnostic capability envelope

The Worker's `Status` SHALL publish a complete capability envelope for lane A
under `SPEC.md` §4.10: provider identity and version, implementation version,
service incarnation, and one profile with its profile ID, the `gguf` artifact
format, CPU acceleration, device binding, memory semantics, runtime features,
an empty cache capability set and concurrency one. Lane A SHALL publish no
loaded-binding or reasoning evidence. The envelope SHALL remain
diagnostic-only.

#### Scenario: Status reports lane A capabilities

- **WHEN** the Node Agent reads `Status` from a lane A Worker
- **THEN** the envelope carries every required field with no cache capability and no reasoning evidence, and admission is unchanged by it

### Requirement: Lane A generates only from authoritative prompt token IDs

The Worker SHALL send Orchard's authoritative prompt token IDs to the server's
`/v1/completions` endpoint as a flat list and SHALL require their count to
equal the request's input token count. It SHALL NOT send rendered prompt text
or ask llama.cpp to render or retokenize prompts. Unlike providers that fall
back to rendered text, lane A SHALL reject a request that carries no prompt
token IDs before provider generation.

Every request SHALL carry a complete sampler: temperature and top-p from the
request, top-k, min-p and repetition penalties set to neutral values, and a
pinned seed. The Worker SHALL map stop sequences, SHALL bound output tokens by
the pinned context, and SHALL reject token-ID output, logprobs and any other
control it does not map before provider generation.

Every request SHALL also disable the prompt cache and request per-token
timings. The Worker SHALL fail the generation before emitting its first delta
when the first chunk reports reused prompt tokens or omits the cached-token
count. Provider usage SHALL equal the Controller's input token count.

#### Scenario: Prompt token IDs are absent

- **WHEN** a lane A request carries rendered prompt text but no prompt token IDs
- **THEN** the Worker rejects it before provider generation and sends no prompt text to the server

#### Scenario: Request carries an unmapped control

- **WHEN** a lane A request asks for token-ID output, logprobs or another control the Worker does not map
- **THEN** the Worker rejects it before provider generation

#### Scenario: Provider usage disagrees

- **WHEN** the provider reports an input token count different from the supplied prompt IDs
- **THEN** the generation fails closed rather than reporting provider usage as authoritative

#### Scenario: Server reuses cached prompt tokens

- **WHEN** the first chunk of a lane A generation reports reused prompt tokens or carries no cached-token count
- **THEN** the Worker fails the generation before emitting any delta

### Requirement: Lane A serves thinking-disabled prompts only

Lane A SHALL return generated text as answer content without reasoning
separation and SHALL publish no reasoning evidence. Corpus cases SHALL render
their prompts with thinking disabled. A case whose output contains the
model's reasoning-open marker SHALL fail rather than be graded on that text.

#### Scenario: Model emits reasoning despite a thinking-disabled prompt

- **WHEN** a lane A corpus case's output contains the model's reasoning-open marker
- **THEN** the case fails as a model behaviour failure and its answer is not graded

### Requirement: Lane A admits a model only after tokenizer parity

A GGUF model SHALL enter lane A only after parity with `orchard_tokenizer`
loaded from a pinned upstream tokenizer source: a repository revision and the
file digests of its tokenizer, tokenizer configuration, chat template and
generation configuration. The reference ID range is every ID the pinned
tokenizer defines, including added tokens; the reference end-of-generation
set is the generation configuration's end-of-sequence IDs. Parity SHALL
require that:

- every ID in the reference range maps to the same piece in the GGUF
  vocabulary, and every GGUF ID above that range is an unused or padding
  token
- decoding each parity corpus entry's token IDs yields identical bytes under
  both tokenizers, including special and control tokens
- the reference end-of-generation set is contained in the GGUF's
  end-of-generation set, and the parity record lists any extra GGUF IDs

The corpus SHALL cover ASCII, non-Latin scripts, emoji, whitespace runs and
every special or control token the model's template emits. The parity record
SHALL state the special-token parse mode used to encode the corpus.

#### Scenario: Embedded tokenizer disagrees

- **WHEN** a reference-range piece or decoded corpus entry differs, a GGUF ID above the reference range is a used token, or a reference end-of-generation ID is missing from the GGUF
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

Every lane run SHALL pin its thread count and record the CPU backend variant
the runtime loaded as part of its host class. Tests SHALL assert protocol and
semantic outcomes. Exact-answer and exact-text cases SHALL use temperature 0
with the pinned seed. Exact generated text MAY be asserted only within one
runtime, host class and thread count, and SHALL NOT be compared across
runtimes or thread counts.

#### Scenario: Thread count changes generated prose

- **WHEN** a lane runs with a different thread count than a recorded run
- **THEN** semantic and protocol assertions still apply, and no exact-text comparison is made between the two runs

#### Scenario: Prompted JSON case returns invalid JSON

- **WHEN** a prompted JSON case returns text that is not the expected JSON
- **THEN** the case reports a model behaviour failure and no structured-output enforcement is claimed
