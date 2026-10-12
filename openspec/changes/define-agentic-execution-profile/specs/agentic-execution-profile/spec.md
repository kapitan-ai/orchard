## ADDED Requirements

### Requirement: Agentic execution preserves client ownership

The Agentic Execution Profile SHALL remain provider- and agent-client-neutral. Orchard SHALL return typed tool calls and accept correlated tool results, while the agent client owns loop control, tool authorization, semantic argument validation, execution, result continuation, and loop limits. A named conformance client SHALL NOT define the protocol or imply conformance by another client. The profile SHALL NOT enable `parallel_tool_calls=true`, a server-owned agent loop, or Orchard execution of client tools.

#### Scenario: Client completes a tool round trip

- **WHEN** Orchard returns a valid typed function call from the deterministic corpus
- **THEN** the client validates and executes the synthetic tool and returns a correlated result
- **AND** Orchard returns the expected typed final response on continuation
- **AND** the side-effect trace proves Orchard did not execute the tool

#### Scenario: Generated arguments violate the caller schema

- **WHEN** a generated function-call argument object violates the caller-supplied schema
- **THEN** the client rejects it before tool execution
- **AND** no tool side effect occurs
- **AND** Orchard does not reinterpret the invalid call as final text

#### Scenario: Parallel tool calls are requested

- **WHEN** a request supplies `parallel_tool_calls=true`
- **THEN** Orchard rejects it before dispatch under the existing unsupported-parameter contract
- **AND** the profile records no positive parallel-tool capability

### Requirement: Protocol conformance uses a deterministic reusable corpus

Protocol conformance SHALL begin with a versioned deterministic corpus and scripted provider-neutral inference fixture before any model, hardware, or runtime-provider qualification. Every case SHALL declare its endpoint, streaming mode, applicable output contract, request input, ordered API and runtime events, expected terminal outcome, usage, client decisions, and tool side effects. Every executable assertion SHALL produce pass or fail. A contractually expected rejection, failure, cancellation, or quarantine SHALL pass its negative assertion without creating a positive capability result. A positive assertion whose public input contract is not accepted SHALL remain `dependency_blocked`, SHALL NOT be simulated through internal canonical fields, and SHALL NOT count as a conformance pass. A deterministic pass SHALL NOT establish model qualification, production activation, or a broad client support claim.

The corpus SHALL cover typed final text; accepted and rejected reasoning behavior; single and multiple tool calls plus continuation; currently accepted structured output; request-shape validation for client-generated and directly caller-supplied tool schemas plus client validation of generated arguments against the effective caller schema; attempt-scoped usage evidence; scoped logical, public, and runtime terminal outcomes; disconnect cancellation with native drain before observed capacity reuse; bounded cache identity and affinity; retry and errors; and rejection of `parallel_tool_calls=true`.

#### Scenario: Corpus is implemented before hardware qualification

- **WHEN** implementation of this profile begins
- **THEN** the reusable corpus format, scripted fixture, assertions, and sanitized result format are the first implementation deliverable
- **AND** named-client and real-hardware qualification consume that corpus only after its deterministic lane passes

#### Scenario: Typed output case completes

- **WHEN** a corpus case emits final text, reasoning, tool calls, or structured output
- **THEN** every value appears only in its accepted typed channel with the expected identity and order
- **AND** the admitted logical Request has exactly one durable terminal outcome
- **AND** each conforming Runtime Endpoint execution stream that began has exactly one terminal
- **AND** the public request has at most one deliverable terminal when its connection remains available
- **AND** no text, tool call, usage update, or other event follows the relevant terminal

#### Scenario: A case has no runtime terminal to count

- **WHEN** a request is rejected before dispatch
- **THEN** the expected Runtime Endpoint terminal count is zero
- **AND** the rejection may pass its negative assertion without fabricating a runtime terminal

#### Scenario: Runtime stream loses its terminal

- **WHEN** a begun Runtime Endpoint execution stream closes without its terminal
- **THEN** the case expects failure rather than synthesized success
- **AND** Controller-synthesized usage is checked as a validated cumulative lower bound when exact terminal usage cannot be proved

#### Scenario: Automatic retry begins a second attempt

- **WHEN** one admitted logical Request starts two Inference Attempts under the bounded retry contract
- **THEN** the logical Request still has exactly one durable terminal outcome
- **AND** each begun attempt stream is evaluated independently for its own terminal and usage evidence

#### Scenario: Unsupported structured reasoning is exercised

- **WHEN** the current public contract does not expose structured reasoning
- **THEN** the corpus expects fail-closed request rejection
- **AND** that negative pass is not recorded as positive structured-reasoning support

#### Scenario: Omitted reasoning remains legacy blended

- **WHEN** a tested public request omits reasoning control
- **THEN** the case expects the endpoint's existing `model_default + legacy_blended` behavior
- **AND** delimiter-like legacy text is not reclassified through the negotiated typed-separation assertion

#### Scenario: Explicit final-only has no accepted public field

- **WHEN** the concrete public input contract for explicit `final_only` has not been accepted
- **THEN** its positive public-client case remains `dependency_blocked`
- **AND** an internal canonical fixture cannot count as public protocol conformance

#### Scenario: Structured output is malformed

- **WHEN** the accepted JSON-object output mode produces malformed JSON or a value different from the predeclared expected object
- **THEN** the case fails
- **AND** the profile does not infer `json_schema` support

#### Scenario: Responses requests a structured-output selector

- **WHEN** a current Responses request supplies a structured-output selector that its supported-field contract does not define
- **THEN** the case expects unsupported-field rejection
- **AND** Chat Completions `json_object` support is not projected onto Responses

### Requirement: Disconnect cancellation proves native drain before capacity release

A disconnect-cancellation case SHALL pass only when evidence proves that the runtime provider's native generation operation stopped and drained before Controller allocation or Node/placement capacity was released. Transport closure or cancel acknowledgement alone SHALL NOT prove native drain. Unresolved execution SHALL retain the existing quarantine, unresolved occupancy, and no-redispatch behavior.

This native-drain requirement is additional Agentic Execution Profile acceptance evidence. The base product MAY satisfy `SPEC.md` §4.6.2's transport-level resolution contract without thereby passing this profile gate. This change does not replace that global capacity authority; it prevents exact-tuple profile qualification when native termination evidence is absent.

#### Scenario: Native generation drains

- **WHEN** the caller disconnects during active generation
- **THEN** the Request terminalizes once as cancelled and is not retried
- **AND** provider-native stop and drain evidence precedes capacity release
- **AND** only then may another request consume the released capacity

#### Scenario: Base resolution is proved without native-drain evidence

- **WHEN** §4.6.2 accepts affirmative runtime-stream closure as base execution-resolution evidence
- **AND** native execution termination cannot be independently proven within the profile's drain bound
- **THEN** the case fails
- **AND** the exact tuple cannot qualify for the Agentic Execution Profile
- **AND** capacity release and quarantine remain governed by §4.6.2 without a stronger restriction from this profile

#### Scenario: Base execution remains unresolved

- **WHEN** execution remains unresolved under §4.6.2 after the cancel-drain bound
- **THEN** the case fails
- **AND** Orchard does not represent the unresolved occupancy as released
- **AND** the existing quarantine contract prevents redispatch to that unresolved capacity

### Requirement: Cache and retry cases preserve existing authority boundaries

Under one fixed Controller key scope and fingerprint configuration, the corpus SHALL prove that identical canonical prefixes covered by the configured fingerprint domain produce the same opaque Controller-derived cache-affinity identity. Changing an instruction, message, tool definition, call, or tool result SHALL change that identity only when the changed canonical bytes fall within the covered prefix; a change outside that bounded prefix MAY retain the same identity. `prompt_cache_key` SHALL NOT control the identity. The profile SHALL NOT infer a separate full-input identity. Cache affinity SHALL remain a bounded non-authoritative ranking hint and SHALL NOT prove correctness, residency, authorization, or dispatch eligibility.

Retry cases SHALL prove the one-automatic-retry bound, exact negotiated and model identity pinning, stable public error mapping, no retry after caller disconnect or Output Commitment, no duplicate client tool execution, and no alternate-capacity acquisition before prior execution resolution and capacity release are proved.

#### Scenario: Continuation changes cache identity

- **WHEN** two requests under the same key scope and fingerprint configuration differ only by one correlated tool result whose changed canonical bytes fall inside the covered prefix
- **THEN** their opaque canonical cache-affinity identities differ
- **AND** a caller-supplied `prompt_cache_key` cannot force equality

#### Scenario: Continuation changes bytes outside the fingerprint domain

- **WHEN** two requests differ only after the configured covered prefix
- **THEN** their opaque cache-affinity identities may remain equal
- **AND** that equality does not prove full-request identity, correctness, residency, authorization, or eligibility

#### Scenario: Failure occurs after tool execution

- **WHEN** a continuation fails after the client has executed a tool
- **THEN** automatic inference retry does not cause the client tool to execute again
- **AND** any client retry follows the client's own idempotency and loop policy

### Requirement: Qualification and activation remain separate exact decisions

Exact-tuple workload qualification SHALL identify the immutable model checkpoint/revision, quantization, Artifact Bundle digest, tokenizer and template digests, renderer and parser identities, Worker Runtime provider and dependencies, Runtime Endpoint contract and transport, Orchard revision, endpoint and stream mode, client version and configuration, operating system, hardware, topology, and material request/runtime settings. A changed identity field SHALL require a new qualification identity and review.

Production activation SHALL additionally require an approved exact-tuple qualification record, active scoped support claim, every applicable profile gate, and an explicit operator product decision. Protocol conformance or qualification SHALL NOT publish, default, preload, advertise, or activate a model or client profile.

#### Scenario: OpenCode is the first conformance client

- **WHEN** one exact OpenCode version and configuration passes the corpus
- **THEN** the result applies only to that client identity and tested endpoint modes
- **AND** it does not claim general OpenCode, other-client, model-family, or runtime-provider support

#### Scenario: Exact qualification passes

- **WHEN** one immutable model/runtime/client tuple passes deterministic and real-workload gates
- **THEN** the tuple may enter repository qualification review
- **AND** no production activation follows without the separate support, profile, and operator gates
- **AND** the result does not activate Qwen3.8 or adopt TensorFold as an Orchard runtime foundation
