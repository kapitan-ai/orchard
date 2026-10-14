## ADDED Requirements

### Requirement: Default-off Worker experiment uses existing local seams

The separately selected `vllm_poc` source-development experiment SHALL remain
default-off behind existing local gRPC. It SHALL consume existing rendered
prompts through loopback HTTP `/v1/completions` on port 58080, use logical
load/unload and concurrency one, and introduce
no Controller, shared request or tokenizer registration contract. It SHALL
send authoritative prompt IDs as a flat nonnegative integer list when present,
require their count to equal `input_tokens`, and use the rendered string only
when IDs are absent. Provider usage SHALL still equal the Controller count.
It SHALL reject token-ID output, logprobs and unsupported controls, accept only
prompt suffix `<think>\n` or `<think>\n\n</think>\n\n`, and require temperature
`1.0`/top-p `0.95`, and pin top-k `20`, min-p `0`, presence penalty `0` and
repetition penalty `1`.

#### Scenario: Request does not match the bounded seam

- **WHEN** a selected request supplies invalid prompt IDs, requests token-ID output or logprobs, or supplies an incompatible prompt suffix or sampling controls
- **THEN** the Worker rejects it before provider generation rather than approximating or rerendering it

#### Scenario: Controller supplies authoritative prompt IDs

- **WHEN** the existing request includes prompt IDs and matching input count
- **THEN** the adapter sends those IDs rather than asking the provider to retokenize rendered text
- **AND** a provider usage mismatch still fails closed

#### Scenario: Stream-mode capacity remains within the existing contract

- **WHEN** the experimental Worker reports capacity or admits a generation
- **THEN** it retains concurrency one and rejects another active generation with `worker_busy`
- **AND** the supervisor retains `--max-num-seqs 1`; N-slot admission is deferred pending separate approval to amend `SPEC.md` §7.5.3

### Requirement: Stateful framing preserves legacy-blended reasoning

The Worker SHALL preserve generated reasoning bytes as legacy-blended text
under KAP-49, not project `final_only`. Raw `legacy_blended` output SHALL pass
through even when thinking ends at length or reasoning framing is malformed.
Stateful framing SHALL start inside the prompt-opened reasoning frame and serve
only to locate an unambiguous final suffix across stream chunks, not enforce
negotiated-mode fail-closed reasoning rules. Qwen XML tool parsing SHALL apply
only to that suffix; without one, auto/none raw output SHALL remain text and
required/named tool choices SHALL fail with `tool_choice_not_satisfied`. For
the recognized disabled prompt, output SHALL start in final-text state without
advertising a new effort mapping or negotiated reasoning capability. Complete
requested tool blocks MAY follow an exact text prefix; calls SHALL retain source
order and use UUID IDs under KAP-116. Only whitespace SHALL separate or follow
tool blocks. Complete or ambiguous tool syntax in the identified suffix SHALL
fail closed when malformed, unknown, unrequested, duplicate-argument or
interleaved/trailing-text. Truncated marker prefixes SHALL fail closed only at
length and SHALL remain ordinary text at clean stop.

Reasoning/raw text SHALL stream immediately. After the reasoning close, the
Worker SHALL withhold only the minimal suffix that could begin a tool control
marker, releasing it when it cannot do so. Once a complete control marker is
seen, subsequent bytes SHALL remain buffered until terminal parsing. Tool calls
SHALL be validated before emission; terminal text SHALL exclude already-emitted
bytes. Later malformed reasoning framing SHALL retain raw passthrough semantics.
Terminal validation MAY fail after text deltas have been delivered, ending with
exactly one failed terminal and no completion, without retracting delivered text.
First-token timing SHALL retain the existing first emitted legacy text boundary
in `SPEC.md` §5.8.

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
- **THEN** auto/none raw legacy-blended output passes through as text without tool parsing, subject to total decoded-output bounds
- **AND** required/named tool choice fails with `tool_choice_not_satisfied`

#### Scenario: Provider pauses before terminal

- **WHEN** reasoning or safe final text arrives before the provider terminal
- **THEN** the Worker emits that text without waiting for the terminal
- **AND** it withholds possible tool markers until disambiguation and validates complete calls only at terminal

#### Scenario: Tool marker prefix ends the identified suffix

- **WHEN** an identified final suffix ends with a truncated tool marker prefix
- **THEN** it fails closed at length but remains ordinary text at clean stop

#### Scenario: Declared parameter types govern decoding

- **WHEN** a requested tool call supplies parameter text
- **THEN** declared strings retain raw text, declared JSON types require parsing and matching types, and absent or unknown types use JSON-or-trimmed-text semantics
- **AND** non-finite values or numeric parse failures produce `tool_call_parse_failed`

### Requirement: Cancellation does not invent native cessation evidence

Each request SHALL own its provider connection and random request ID. The Worker
SHALL validate supplied response IDs and close only the cancelled request's
transport. Local reader settlement SHALL remain bounded. The cancelled terminal
SHALL retain code `cancelled` and report `cancel accepted; native cessation
unconfirmed` in its message and cancellation cleanup logs. Other premature-stream
cleanup SHALL log unconfirmed cessation with the provider request ID. Settled
reader cleanup SHALL permit new local admission despite unconfirmed cessation.
Only an unsettled reader SHALL latch the Worker unhealthy and deny new local
admission until replacement, including after logical unload/reload.
Cancel acceptance SHALL NOT be represented as native cessation confirmation.

This reuse policy SHALL retain exclusive provider ownership, Worker concurrency
one and supervisor `--max-num-seqs 1`. It relies on vLLM serialization and native
execution/block-reuse fences, with possible next-request latency. Slice 3 SHALL
revisit a provider-side cessation receipt before concurrency above one.

Pinned vLLM's aggregate metrics SHALL NOT authorize a confirmed result: they have
neither a request identity nor a freshness barrier or native execution fence.
Confirmed polling remains blocked pending a separately approved provider signal,
as recorded in ADR 0037. This experiment adds no resource-release authority.

#### Scenario: An active request is cancelled

- **WHEN** an active request is cancelled
- **THEN** its transport closes and it receives exactly one cancelled terminal with unconfirmed cessation
- **AND** once its reader settles within the bound, the Worker remains healthy and admits a subsequent request

#### Scenario: A cancelled request's reader does not settle

- **WHEN** the reader fails to settle within the two-second cleanup bound
- **THEN** the cancelled terminal still reports unconfirmed cessation
- **AND** the Worker remains unhealthy and denies new admission even after logical unload/reload

#### Scenario: An aggregate snapshot reports zero running and waiting requests

- **WHEN** provider aggregate metrics report zero after a client disconnect
- **THEN** the adapter does not infer request-scoped native cessation from that possibly stale snapshot

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
