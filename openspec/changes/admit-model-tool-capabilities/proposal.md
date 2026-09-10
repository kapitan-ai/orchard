## Why

Model Hub currently replaces every downloaded Hugging Face bundle's capabilities with `chat`, even when the exact downloaded tokenizer and chat template can render function definitions, parsed function-call history, and tool results. This causes avoidable request rejection before the Worker Runtime can evaluate a tool-aware artifact. Conversely, a model name, a generic Hub tag, an arbitrary README instruction, or an unqualified runtime observation is not safe evidence for tool admission.

## What Changes

- Add a revision-bound Model Hub capability-evidence sidecar to Artifact Bundles and persist it in the Catalog without changing the closed worker manifest schema.
- Admit `tool_calling` only when the exact downloaded artifact supplies a recognized parser declaration and its exact chat template renders both a synthetic function definition and a structured function-call/result history.
- Preserve the source repository, resolved revision, tokenizer-config digest, chat-template digest, parser identity, artifact preflight result, and `runtime_qualification: not_established` in the immutable bundle manifest.
- Keep missing, unknown, conflicting, malformed, or unsupported evidence chat-only. Base-model links remain provenance only and cannot supply inherited admission evidence without checks against the converted artifact.
- Continue using the existing Catalog capability gate and Worker Runtime parser fence. A declared Catalog capability permits request-scoped client tool passthrough; it is neither runtime qualification nor a product support claim.
- Reject malformed inline function schemas before request persistence, prompt rendering, scheduling, or worker dispatch.
- Preserve the existing safe segmented rendering path that decodes assistant tool-call JSON arguments to objects and protects structured tool history before template rendering.
- Define reimport as an explicit new Catalog identity. Existing Catalog rows and Artifact Bundle digests are never mutated to repair a prior chat-only import.

## Capabilities

### New Capabilities

- `model-tool-capability-admission`: Defines revision-bound Model Hub evidence, manifest provenance, fail-closed tool admission, and explicit repair imports.

### Modified Capabilities

- `safe-tool-history`: Retains the Controller tokenizer's structured assistant tool-history safety requirements as a prerequisite for tool-capable artifact preflight.

## Impact

- Product contract: `SPEC.md` §§3.5, 6.4-6.6, 7.1, and 7.2.
- Elixir: Model Hub detail/build path, manifest parsing, import/catalog persistence, and shared tool request validation.
- Python: tokenizer-only artifact preflight and its tests; no Worker Runtime protocol or server-side execution change.
- Existing bundles remain immutable and chat-only. Operators repair one only by producing and importing a distinct, explicitly versioned bundle through the normal build/import path.
- Qualification and support claims remain governed by ADR 0028 and `docs/model-qualification.md`; this change creates no such claim.
