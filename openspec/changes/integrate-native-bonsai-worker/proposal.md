## Why

The released native Bonsai implementation supports the official schema-v2 Hadamard pack, while the current Worker cannot construct that architecture. A reviewed native construction path is needed before a genuine client-owned repository edit/test workflow can be evaluated through Orchard.

## What Changes

- Reuse the exact released native implementation beneath the existing MLX-LM Worker generation path, without importing model-bundle Python or rewriting numerical transforms.
- Admit only the closed schema-v2 Bonsai architecture with strict complete-weight loading and explicit stream-only, concurrency-one, persistent-cache-disabled evaluation settings.
- Keep immutable artifact/tokenizer/parser admission, safe tool history, cancellation cleanup and Node Agent process custody intact.
- Add model-free malformed-pack, trust, wrapper, output/cache and load-failure tests, and a pinned optional native dependency environment with preserved held pins.
- Document the exact native dependency and managed source-evaluation prerequisites; keep real OpenCode edit/test and cancellation/reuse qualification as explicit incomplete acceptance work until receipts exist.

## Capabilities

### New Capabilities

- `native-bonsai-loading`: Reviewed local construction and bounded text-only execution of schema-v2 Bonsai packs behind the existing Worker.

### Modified Capabilities

None. Existing provider-neutral tool, admission, protocol and lifecycle requirements remain in force.

## Impact

SPEC.md §§3.4, 6.4 and 7.2 govern dependency identity, immutable bundles and Worker ownership. No public request schema, Runtime Endpoint, Worker protobuf, Controller scheduling, trust or qualification-authority change is intended. The existing `mlx_lm` runtime identity remains accurate for generation, with a pinned native model implementation identified separately in the exact serving tuple. SPEC documentation will explain the closed native construction path and experimental stream/cache restrictions without weakening existing safety or support gates.

Implementation is scoped to Worker loading, tests, dependency declaration/lock and README plus this change's contract artifacts. The separate tokenizer helper environment, held MLX/MLX-LM revisions, source-only distribution pause and existing collaborator work remain intact. Native package graph reuse is conditional on compatibility with Transformers5.14.1 and Safetensors0.8.0; incompatible requirements require an explicit reviewed narrower reuse decision.
