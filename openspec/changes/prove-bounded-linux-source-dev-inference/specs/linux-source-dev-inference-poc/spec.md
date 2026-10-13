## ADDED Requirements

### Requirement: Default-off Worker experiment uses existing local seams

The separately selected `vllm_poc` source-development experiment SHALL remain
default-off behind existing local gRPC. It SHALL consume existing rendered
prompts through loopback HTTP `/v1/completions` on port 58080, use logical
load/unload and concurrency one, and introduce no Controller, shared request
or tokenizer registration contract. It SHALL reject token-ID inputs, logprobs
and unsupported controls, require prompt suffix `<think>\n` and temperature
`1.0`/top-p `0.95`, and pin top-k `20`, min-p `0`, presence penalty `0` and
repetition penalty `1`.

#### Scenario: Request does not match the bounded seam

- **WHEN** a selected request supplies token IDs, logprobs, an incompatible prompt suffix or sampling controls
- **THEN** the Worker rejects it before provider generation rather than approximating or rerendering it

### Requirement: Stateful framing preserves legacy-blended reasoning

The Worker SHALL preserve generated reasoning bytes as legacy-blended text
under KAP-49, not project `final_only`. Raw `legacy_blended` output SHALL pass
through even when thinking ends at length or reasoning framing is malformed.
Stateful framing SHALL start inside the prompt-opened reasoning frame and serve
only to locate an unambiguous final suffix across stream chunks, not enforce
negotiated-mode fail-closed reasoning rules. Qwen XML tool parsing SHALL apply
only to that suffix; without one, raw output SHALL remain text. Complete
requested tool blocks MAY follow an exact text prefix; calls SHALL retain source
order and use UUID IDs under KAP-116. Only whitespace SHALL separate or follow
tool blocks. Complete or ambiguous tool syntax in the identified suffix SHALL
fail closed when malformed, unknown, unrequested, duplicate-argument or
interleaved/trailing-text. Truncated marker prefixes SHALL fail closed only at
length and SHALL remain ordinary text at clean stop.

Parameter decoding SHALL use `tool.parameters.properties[name].type`: declared
`string` SHALL retain raw text; `number`, `integer`, `boolean`, `object`, `array`
and `null` SHALL require JSON parsing and matching types. Absent or unknown
types SHALL retain vLLM qwen3 JSON-or-trimmed-text semantics. Non-finite values
and numeric parse failures SHALL produce `tool_call_parse_failed`. This SHALL
NOT claim general JSON Schema validation of generated values. Total decoded
output SHALL remain bounded including reasoning and framing; pass-through
SHALL NOT discard bytes to fit the bound.

#### Scenario: Tool-shaped bytes occur within reasoning

- **WHEN** generated reasoning contains tool-like markers before its matching closing frame
- **THEN** those bytes remain legacy-blended text and are not emitted as tool calls

#### Scenario: Control markers cross chunks or output exceeds the bound

- **WHEN** markers arrive across stream boundaries
- **THEN** framing preserves the same bytes and tool decisions as unsplit input
- **AND** total decoded output beyond the bound fails rather than discarding reasoning to fit

#### Scenario: Thinking ends at length or reasoning framing is malformed

- **WHEN** thinking ends at length or reasoning framing is malformed without an unambiguous final suffix
- **THEN** raw legacy-blended output passes through as text without tool parsing, subject to total decoded-output bounds

#### Scenario: Tool marker prefix ends the identified suffix

- **WHEN** an identified final suffix ends with a truncated tool marker prefix
- **THEN** it fails closed at length but remains ordinary text at clean stop

#### Scenario: Declared parameter types govern decoding

- **WHEN** a requested tool call supplies parameter text
- **THEN** declared strings retain raw text, declared JSON types require parsing and matching types, and absent or unknown types use JSON-or-trimmed-text semantics
- **AND** non-finite values or numeric parse failures produce `tool_call_parse_failed`

### Requirement: Historical execution remains disabled

Historical smoke-runner `main` and `execute` SHALL fail closed before mutation,
and historical setup SHALL remain disabled. The source bundle's effort artifact
digest differs from main's source-owned effort registry and the old registration
environment variable SHALL NOT create registration authority. Only deterministic
scripts/tests are retained as current evidence. Future reasoning work SHALL
either rebuild the exact qualified KAP-49 fixture with new reviewed provenance
under current registration or separately accept a new artifact profile;
`final_only` SHALL require a separate public contract.

#### Scenario: Historical fixture is requested

- **WHEN** an operator invokes historical setup or runner main/execute
- **THEN** it refuses before mutation without restoring runtime registration or using implicit template defaults

### Requirement: Historical tuple grants no current authorization or qualification

The pinned vLLM 0.27.1 image tuple in ADR 0037 SHALL remain a historical proven
reference only. This independent experiment SHALL NOT fulfill
`reconcile-linux-node-source-dev-contract`, change `SPEC.md` §1.4, §1.5, §4.10,
§7.2.9 or M9, or weaken ADR 0035.
It SHALL grant no live execution authorization, native cessation, custody,
capacity, model/provider/platform qualification or support. No current-main
real API/OpenCode proof SHALL be claimed.

The supervisor SHALL require `ORCHARD_KAP112_GPU_UUID` and
`ORCHARD_KAP112_SNAPSHOT_ROOT`; those inputs SHALL NOT authorize execution.
Live supervisor/download requires separate owner approval and has not run for
this port. Any future live plan SHALL bind exact clean source and tuple, bound
mutations, stop on drift or exhausted limits, use loopback/owner-only transports
and disposable state, and restore only its owned baseline. Logical unload,
HTTP closure and wrapper-owned provider stop SHALL NOT prove native cessation,
request-slot release, resource release or Node Agent custody. Client tools
SHALL remain client-owned rather than Orchard execution or confinement.

#### Scenario: Deterministic tests pass

- **WHEN** fake-provider tests or retained deterministic scripts pass
- **THEN** the result is implementation evidence only, not real API/OpenCode proof or Linux Node, model or provider qualification

#### Scenario: Required supervisor inputs are supplied

- **WHEN** the required GPU and snapshot inputs are present but separate owner approval is absent
- **THEN** their presence grants no permission to download, supervise or execute inference
