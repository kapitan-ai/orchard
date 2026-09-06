## Context

See proposal.md for the observed failure.
The pinned MLX-LM tokenizer exposes a complete-block parser, tool start/end markers, and a parser identity.
Its parsed function object separates the name from the arguments.
Orchard's existing Worker Runtime event already carries normalized function names and argument fragments independently of the public API serializer.

## Goals / Non-Goals

The goal is a trustworthy MLX-to-Worker Runtime tool boundary and a real client-owned tool round trip.
The change does not add server-side execution, another backend, another parser implementation, a dependency upgrade, or a new transport.
It does not claim OpenCode Responses compatibility.

## Decisions

### Publish complete parsed calls

Buffer each model-native tool block until its end marker, then delegate interpretation to the loaded MLX-LM parser.
Validate all parser results from that block before publishing any of them.
Emit one normalized delta per parsed call containing a request-local generated ID, monotonically increasing index, requested function name, and JSON-serialized argument object.
The existing append-only contract permits a single complete argument fragment.
The alternative of forwarding raw model fragments is invalid for wrapper formats.
Implementing another incremental model-specific parser would duplicate upstream semantics without improving correctness.

### Fail closed at incomplete or invalid calls

Cancelled calls are discarded before parsing.
An explicit end-marker format that reaches termination without its closing marker fails as incomplete.
A delimiter-free format is parsed only after a clean generation stop, never after length exhaustion or cancellation.
Parser exceptions, empty results, unknown function names, invalid argument objects, and named-choice mismatches fail without publishing the block.
Error text identifies the category without echoing generated tool content.
Already published valid calls retain their stable identity if a later block fails.

### Preserve execution ownership and truthful capability declarations

The Controller continues to gate the imported model capability, and the worker independently checks the loaded parser.
The qualification bundle must be separately identified and verified before declaring tool capability.
Do not change every smoke bundle to tool-capable or infer capability from a model family name.
OpenCode executes the local tool and returns the result; the worker never opens the requested file.

### Normalize tool history before template rendering

The selected Qwen3-Coder template iterates argument mappings, whereas public Chat Completions history carries JSON strings.
Decode history arguments into objects before baseline rendering and caller-string tagging.
Protect recursive argument keys and string values with the existing segmentation machinery, retain scalar types, and preserve the fail-closed dual-render check.
Malformed or non-object arguments fail as invalid input without exposing their contents.
This normalization belongs to the Controller-side tokenizer, independently of the worker's model-output parser.
Legacy non-segmented rendering is unchanged.
Exactly empty strings remain unmarked because they carry zero caller bytes; every nonempty string remains tagged.
The generic preflight uses complete synthetic function schemas but does not require tool-result history from chat-only templates.
Tool-capable profiles must additionally pass the real-template continuation regression and the client round trip.

## Risks / Trade-offs

- Later first tool delta: complete-block parsing defers output commitment until the call is validated; ordinary text can still stream.
- Model-native marker ambiguity: retain upstream marker semantics and fail closed; test split markers and malformed blocks.
- Parser drift: exercise the pinned parser alongside deterministic protocol fixtures and real-model qualification.
- Model reliability: use exact artifact identity, repeat the synthetic tool-result loop, and distinguish wire correctness from model choice quality.

## Migration Plan

No database or wire migration is required.
Deploy the worker correction with matching contract and regression updates through the normal contribution workflow.
Older workers remain wire-compatible but are not covered by the corrected tool qualification.
