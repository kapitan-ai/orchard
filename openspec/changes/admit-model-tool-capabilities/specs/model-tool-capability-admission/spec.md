## ADDED Requirements

### Requirement: Revision-bound Model Hub tool admission

For a Model Hub bundle, Orchard SHALL derive `tool_calling` only from a complete capability-evidence tuple bound to the exact downloaded Hugging Face repository and resolved revision, exact tokenizer-config digest, exact chat-template digest, and a recognized parser identity. The tuple SHALL include a tokenizer-only preflight that verifies the exact template carries a synthetic function definition and a synthetic structured assistant-call plus tool-result continuation. The resolver SHALL not use a model/family name, a generic Hub tag, arbitrary README prose, or a base-model link alone as positive evidence.

The Artifact Bundle SHALL retain a closed `tool_capability_evidence.json` sidecar containing source provenance, artifact digests, parser identity, preflight result, and `runtime_qualification`; the importer SHALL copy it to the immutable Catalog model record. The closed worker manifest SHALL not gain a top-level evidence key, preserving N-1 Worker Runtime compatibility. `runtime_qualification` SHALL be `not_established` after import unless a separately accepted runtime evidence contract changes it.

#### Scenario: Complete recognized artifact tuple declares tool calling

- **WHEN** Model Hub downloads one resolved revision whose tokenizer parser identity is recognized and whose exact template preflight carries both synthetic tool definition and structured history
- **THEN** BundleBuilder writes `tool_calling` with a `declared` evidence result and the importer persists `tool_calling` in that new Catalog model's capabilities
- **AND THEN** the sidecar and Catalog record retain `runtime_qualification: not_established`

#### Scenario: Unknown evidence remains chat-only

- **WHEN** a downloaded artifact lacks a recognized parser, a required exact asset digest, or a successful template preflight
- **THEN** BundleBuilder writes `unknown` or `conflicted` evidence as applicable
- **AND THEN** the generated manifest and imported Catalog model remain chat-only
- **AND THEN** a preflight helper failure is `unknown`, while a successful partially positive preflight is `conflicted`

#### Scenario: Base-model link does not prove converted artifact capability

- **WHEN** Model Hub detail identifies a base model but the downloaded converted tokenizer/template does not satisfy the complete evidence tuple
- **THEN** Orchard retains the base-model reference only as provenance
- **AND THEN** it does not admit `tool_calling`

### Requirement: Manifest capabilities alone never admit tool calling

Manifest `capabilities` SHALL NOT admit `tool_calling` for any Model Bundle, including an offline-authored bundle that never passed through Model Hub. Manifest parsing SHALL drop a `tool_calling` entry unless the same bundle carries a capability-evidence sidecar whose result is `declared`, and SHALL leave every other capability unchanged. A `declared` sidecar whose manifest omits `tool_calling`, or whose preflight booleans are not all true, SHALL fail manifest validation rather than admit a partial tuple.

#### Scenario: Offline-authored bundle without a sidecar stays chat-only

- **WHEN** a Model Bundle declares `tool_calling` in `capabilities` and carries no `tool_capability_evidence.json` sidecar
- **THEN** manifest parsing drops `tool_calling` and preserves the remaining capabilities
- **AND THEN** the imported Catalog model is chat-only

#### Scenario: Partial declared tuple is rejected

- **WHEN** a sidecar reports `declared` but the manifest omits `tool_calling`, or any preflight boolean is false
- **THEN** manifest validation rejects the bundle instead of admitting the partial tuple

#### Scenario: Offline positive claims require artifact verification

- **WHEN** any bundle supplies a `declared` sidecar
- **THEN** parsing SHALL verify the recorded digests and parser against the manifest-selected config and template and rerun bounded tool preflight
- **AND THEN** missing assets or digests, mismatches, failed renders, or unavailable preflight SHALL reject the bundle

### Requirement: Tool capability is not qualification or server execution authority

A Catalog `tool_calling` capability permits only the existing request-scoped function-tool passthrough gate. It SHALL NOT establish Worker Runtime support, manual qualification, a product support claim, a hosted-tool eligibility fact, or controller-side execution.

#### Scenario: Imported declaration has no support claim

- **WHEN** a tool-aware artifact imports with `runtime_qualification: not_established`
- **THEN** a request may pass the Catalog capability gate
- **AND THEN** the Worker Runtime retains its independent parser fence and no support claim is created

### Requirement: Explicit immutable repair import

Orchard SHALL NOT silently change an existing Catalog model's capabilities, Artifact Bundle, or authoritative digest to repair an earlier chat-only import. The Console Model Hub SHALL offer an operator repair action that builds and imports a new bundle with an explicit distinct Catalog version through the normal build/import path. The resulting Artifact Bundle digest SHALL be distinct from the prior import because the new manifest records the distinct Catalog version.

#### Scenario: Console repair is explicit

- **WHEN** an operator submits a repair version through Console Model Hub
- **THEN** Console forwards only the selected server-side source revision and the distinct Catalog version to the normal import coordinator
- **AND THEN** a blank, source-revision-matching, over-long, or path-unsafe Catalog version is rejected before any provider or transfer work
- **AND THEN** no existing Catalog row is mutated

#### Scenario: Duplicate identity is not repaired in place

- **WHEN** an operator attempts to import evidence under an existing `model_id@version`
- **THEN** the importer rejects the duplicate
- **AND THEN** the existing Catalog row and final Artifact Bundle remain unchanged

#### Scenario: Distinct identities cannot overlap artifact directories

- **WHEN** a repair version contains a separator, or a namespaced model ID places the destination inside an existing bundle
- **THEN** Orchard SHALL reject the import without changing the existing bundle or Catalog digest
- **AND THEN** Console SHALL reject separator-bearing versions before transfer

### Requirement: Inline function schemas fail before dispatch

For both `/v1/chat/completions` and `/v1/responses`, an inline function tool SHALL have a non-empty name. If present, `parameters` SHALL be a JSON object. Invalid values SHALL return the existing invalid-request validation error before request persistence, prompt rendering, scheduling, or Worker Runtime dispatch. This requirement validates shape only and does not evaluate JSON Schema semantics.

#### Scenario: Non-object parameters are rejected

- **WHEN** a tool function supplies `parameters` as a string, array, scalar, or null
- **THEN** request validation rejects `tools` as invalid
- **AND THEN** no request reaches model dispatch

### Requirement: Structured tool history remains safe

The synthetic template preflight and request rendering SHALL use structured assistant function-call arguments. Contract-v3 rendering SHALL decode public JSON argument strings into objects and reject malformed, duplicate-key, non-object, or non-finite values before inference. It SHALL preserve recursive caller-string protection; no artifact preflight may bypass this request-time boundary.

#### Scenario: Malformed history cannot be rendered

- **WHEN** assistant tool-call history contains malformed or non-object arguments
- **THEN** request rendering rejects the request before inference
- **AND THEN** no bundle-wide incompatibility cache entry is created
