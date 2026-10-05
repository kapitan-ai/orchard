## ADDED Requirements

### Requirement: Closed Native Bonsai Construction

Under SPEC.md §§3.4 and 6.4, the Worker SHALL reuse a pinned reviewed native implementation for the schema2 `prism_hadamard_qwen35` model beneath the existing MLX-LM generator. It MUST reject executable model declarations, unsupported pack layouts, offload/drafter overrides, invalid packed module metadata and escaping or missing declared shards before native construction. It SHALL load complete weights strictly and MUST NOT fall back to ordinary affine loading after a native failure.

Hadamard-marked configurations with an incompatible architecture label MUST fail before ordinary affine construction. Runtime load evidence SHALL record the native package version/source revision and retained generation adapter.

#### Scenario: Valid native pack

- **WHEN** an admitted immutable local bundle selects the supported schema2 architecture and explicit experimental settings
- **THEN** the Worker constructs it through the exact reviewed installed native implementation with strict weights
- **AND** bundle Python remains inert

#### Scenario: Altered or incomplete pack
- **WHEN** configuration, packed module layout, signs, shards or required weights are invalid
- **THEN** loading fails without publishing a loaded placement or substituting another implementation

### Requirement: Explicit Serial Text Evaluation Envelope

Under SPEC.md §7.2, native Bonsai evaluation SHALL retain Node Agent lifecycle ownership and client-owned tools. The initial native path MUST require stream generation, concurrency one and disabled persistent prefix reuse. It SHALL use native language logits, resolved EOS and fresh request-local cache state through the existing Worker generation and cleanup path. It MUST reject unsupported settings without silently changing requested behavior.

#### Scenario: Unsupported execution setting
- **WHEN** a native Bonsai load is requested under batch generation or persistent prefix-cache settings
- **THEN** the Worker rejects the load before native allocation

#### Scenario: Cancellation and subsequent task
- **WHEN** an evaluated request disconnects or is cancelled
- **THEN** native execution resolves through existing owned cleanup or the placement remains unavailable until Node Agent custody confirms resolution
- **AND** subsequent admission cannot infer native release from a cancel acknowledgment or public terminal alone

### Requirement: Separate Model and Workflow Evidence

Under SPEC.md §§6.4 and 7.2.9, construction and local fixtures SHALL NOT establish a model/runtime support claim. An exact client/model workflow receipt MUST identify native dependency, artifact, tokenizer/template/parser, reasoning, effective settings, Orchard revision and managed path. It MUST include real client-owned repository read/edit/test/iteration, independent checks and cancellation/reuse evidence before claiming that bounded workflow works.

#### Scenario: Unit validation completed
- **WHEN** dependency, wrapper, tokenizer and security tests pass without managed model execution
- **THEN** the result remains a local integration candidate with hardware and useful-task qualification incomplete
