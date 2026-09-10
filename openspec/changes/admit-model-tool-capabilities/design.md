## Context

The Model Hub already receives a resolved Hugging Face revision and downloads the converted artifact before `BundleBuilder` writes `manifest.json`. The Catalog persists only the generated capability list, while the final immutable Artifact Bundle retains the manifest and becomes the authoritative Catalog digest. Existing request preparation gates enabled tools on `model.capabilities`, and the Worker Runtime independently refuses a tokenizer without a callable parser and tool-call start marker.

## Goals / Non-Goals

The goal is conservative admission of tool-aware artifacts through the normal Model Hub/import path. The change does not execute tools, infer capability from a model or family name, import a support claim, query a running Worker Runtime during import, mutate existing Catalog rows, upgrade MLX-LM, or broaden Responses API continuation behavior.

## Decisions

### Bind evidence to the downloaded artifact

`BundleBuilder` records one `tool_capability_evidence.json` sidecar in every generated Model Hub Artifact Bundle. It identifies the downloaded Hugging Face repository and resolved revision, any unpinned base-model references for provenance only, the final tokenizer-config and chat-template digests, parser identity, exact template preflight result, and `runtime_qualification: not_established`. The closed worker manifest does not gain a top-level evidence key, so an N-1 Worker Runtime can load the bundle unchanged; the importer validates the sidecar and copies it to the Catalog record.

The generated Catalog capability is `tool_calling` only when all positive artifact checks pass. The result is `unknown` when the artifact offers no tool evidence, `conflicted` when partially positive evidence disagrees, and `declared` only for the complete recognized tuple. Any helper failure, malformed metadata, unknown parser, missing asset, or mismatched digest remains chat-only. The resolver never uses repository/model names as a decision rule and treats missing generic Hub tags as unknown, not negative evidence.

Bundle parsing does not trust producer-supplied positive booleans. Every declared sidecar must match the manifest-selected config/template bytes and config parser declaration, and pass a fresh bounded tool preflight. An invalid or unverifiable positive claim rejects the bundle rather than persisting a misleading declaration. This applies equally to offline bundles and Model Hub output.

### Prove template carriage without executing a tool

The tokenizer helper renders a fixed synthetic function definition and a fixed structured assistant-call plus tool-result continuation with the downloaded template. It reports only bounded booleans and parser identity; it does not return prompts or generated content. A declaration requires that the template preserve both synthetic values and that the parser identity is recognized by the pinned tokenizer capability table. This is static artifact compatibility only. Runtime load and parser behavior remain independently checked by the Worker Runtime and manual qualification.

### Keep repair explicit and immutable

The importer continues to reject a duplicate `model_id@version`. To repair an existing chat-only entry, the operator uses the Console Model Hub repair action to build and import a new bundle under an explicitly different Catalog version. The original artifact directory, `models.artifact_sha256`, Catalog record, grants, and state are unchanged. The new bundle receives its own final digest because its `manifest.json` records the distinct Catalog version; the sidecar bytes additionally differ whenever the new preflight reaches a different evidence result.

Versions are single path components. Namespaced model IDs remain valid, but finalization rejects destinations beneath an existing bundle as well as existing destinations, preventing distinct identities from mutating an immutable ancestor.

### Validate inline schemas before any request work

An inline `function` tool must have a non-empty name; optional `parameters` must be a JSON object. Invalid shape fails the shared validation used by Chat Completions and Responses before model capability checks, persistence, prompt rendering, scheduling, or dispatch. JSON Schema semantics are not evaluated in this slice.

### Preserve structured history safety

The existing contract-v3 tokenizer path remains the only safe path for structured tool history. It decodes public assistant function argument JSON to an object, rejects malformed, duplicate-key, non-object, or non-finite values, and tags recursive caller strings before rendering. The artifact preflight verifies its synthetic continuation against that representation; it does not relax historical request validation.

## Risks / Trade-offs

- Artifact checks cannot prove semantic model behavior or runtime parser availability. `runtime_qualification: not_established` makes that boundary explicit, and no support claim follows.
- A converted artifact can diverge from a base-model card. Base-model links are retained only as provenance; the converted tokenizer/template must pass its own preflight.
- Reimport creates a new Catalog identity and needs deliberate publication/grants. This preserves auditability and avoids a silent change to a live model.
- The static preflight uses fixed non-sensitive values and reports booleans only, preventing Model Hub logs or manifests from carrying user prompts or tool results.
