## Why

The MLX worker currently emits model-native tool block text as public function arguments before the pinned MLX-LM parser validates or normalizes it.
For JSON tool wrappers this exposes the function envelope instead of its arguments, and existing fake-parser tests do not establish a usable client tool round trip.

## What Changes

- Normalize complete MLX-LM parser results at the Worker Runtime boundary before emitting tool-call events.
- Preserve request-local stable call IDs, zero-based indexes, ordered calls, and existing client execution ownership.
- Fail closed for malformed, unrequested, incomplete, or cancelled unvalidated calls without emitting their raw contents.
- Add pinned-parser regression coverage and a repeatable real-model tool-result round-trip qualification path.
- Document verified model bundle prerequisites and the scope of client compatibility evidence.
- Normalize JSON-string tool history into argument objects for contract-v3 segmented rendering, recursively protect caller strings, and preserve exactly empty strings without markers.
- Accept valid assistant function-call history with absent content, preserve whitespace provenance through trimming, and keep request failures out of the artifact incompatibility cache.

## Capabilities

### New Capabilities

- `safe-tool-history`: Protect tool-result continuation through Controller-side safe rendering.

### Modified Capabilities

- `worker-runtime-providers`: Require provider-normalized tool arguments and qualification at the parser and client round-trip boundaries.

## Impact

`SPEC.md` §7.5.2 internal tool-call semantics will explicitly allow one complete parsed call per delta and prohibit raw model wrappers as function arguments.
The legacy byte-preservation wording will be clarified to preserve normalized function arguments rather than unvalidated model framing.
The public request schemas, Worker Runtime protobuf, Node Agent transport, client-owned execution, and MLX-LM dependency pin remain unchanged.
Implementation covers `native/orchard_worker_mlx`, `native/orchard_tokenizer`, and Controller tokenizer cache admission, with repository qualification tooling and documentation.
`SPEC.md` §3.5 gains the segmented tool-history normalization and zero-byte tagging rules.
Responses API interoperability and future worker transport/backend redesign are separate workstreams.
