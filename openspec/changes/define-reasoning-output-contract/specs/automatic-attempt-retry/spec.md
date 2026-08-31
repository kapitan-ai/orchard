## ADDED Requirements

### Requirement: Retry pins the exact reasoning contract

Automatic attempt 2 for a negotiated Request SHALL preserve attempt 1's reasoning generation policy, projection, source provenance, exact `model_artifact_digest`, exact `chat_template_digest`, `render_contract`, `render_contract_version`, `parser_family`, `parser_version`, `runtime_contract_version`, and `event_binding_version`.
Attempt 2 SHALL use a different eligible endpoint that proves the same complete contract or Orchard SHALL decline retry before dispatch.
An omitted legacy Request MUST preserve `effective_contract.mode = legacy`, remain omitted `model_default + legacy_blended`, follow the existing legacy retry semantics, and MUST NOT fabricate nullable negotiated identity or enter the negotiated reasoning pipeline.
This requirement refines `SPEC.md` sections 3.4, 5.8, 7.3.4, and 7.5.3a.

#### Scenario: Alternate endpoint supports a different parser

- **WHEN** attempt 1 qualifies for retry but the only different eligible endpoint advertises a different parser family or version
- **THEN** Orchard declines retry before dispatch
- **AND** it does not renegotiate, downgrade, or rerender the Request

#### Scenario: Omitted request retries to a newer endpoint

- **WHEN** an omitted legacy Request qualifies for retry to an endpoint that advertises a newer reasoning contract
- **THEN** attempt 2 remains on the complete legacy pipeline
- **AND** it emits only legacy event variants

### Requirement: Operator retry preserves the exact stored reasoning contract

A negotiated operator retry SHALL preserve the source Request's reasoning generation policy, projection, provenance, exact model artifact and chat-template digests, render contract and version, parser family and version, runtime contract version, and event-binding version.
If the negotiated exact stored contract is unavailable or no compatible endpoint can honor it, Orchard MUST fail before dispatch rather than rerendering, renegotiating, downgrading, or widening capture.
An omitted legacy source SHALL preserve `effective_contract.mode = legacy` and follow the existing legacy operator-retry semantics.
This requirement refines `SPEC.md` section 7.3.4.

#### Scenario: Stored exact template is no longer available

- **WHEN** an operator retries a retained Request whose exact chat-template digest is unavailable
- **THEN** Orchard fails the retry before dispatch
- **AND** it does not substitute the current template

## MODIFIED Requirements

### Requirement: Transport-independent Output Commitment

Orchard SHALL mark Output Commitment when the Controller validates and observes the first non-empty delta selected for the logical public response.
A selected public reasoning delta under `projection = reasoning_structured` SHALL commit with kind `reasoning`.
Hidden reasoning under `projection = final_only` MUST NOT commit.
A selected non-empty text delta, any valid tool-call delta with a stable non-empty tool-call identity, or a future content-bearing structured-output delta SHALL keep its existing commitment behavior.
The Controller MUST record commitment before invoking a public event handler or serializer.
Accepted, progress, usage, model-load, empty, hidden-reasoning, and terminal events MUST NOT commit output.
Commitment SHALL be monotonic and identical for streaming and non-streaming Chat Completions and Responses.
This requirement refines `SPEC.md` sections 3.6, 3.7.1, 5.8, and 5.9 and preserves `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Selected public reasoning prevents retry

- **WHEN** attempt 1 emits a validated non-empty reasoning delta selected by `projection = reasoning_structured`
- **THEN** Output Commitment occurs with kind `reasoning` before downstream delivery
- **AND** a later attempt failure does not retry

#### Scenario: Hidden reasoning leaves retry eligible

- **WHEN** attempt 1 emits only hidden reasoning under `projection = final_only` before an eligible transient failure
- **THEN** Output Commitment remains false
- **AND** the retry decision continues through the remaining gates

#### Scenario: Empty text does not commit

- **WHEN** attempt 1 emits only empty text and control events before an eligible transient failure
- **THEN** Output Commitment remains false
- **AND** the retry decision continues through the remaining gates

#### Scenario: Tool-call identity prevents retry

- **WHEN** attempt 1 emits a valid selected tool-call delta with a stable identity and empty arguments
- **THEN** Output Commitment occurs before downstream delivery
- **AND** a later attempt failure does not retry

#### Scenario: Handler fails after commitment

- **WHEN** a public event handler fails after the committing event is observed
- **THEN** the failure is non-retryable
- **AND** Orchard does not regenerate output on another Node

### Requirement: Ordered append-only attempt evidence

Orchard SHALL persist Inference Attempt evidence as append-only `request_step.*` Request Events rather than a separate attempt table.
The orchestrator SHALL own exactly one started event for each attempt, and the dispatcher MUST NOT append another.
After the final pre-start caller and deadline gate, attempt 1 terminal evidence with `retried` and the sole attempt 2 started event MUST append atomically before attempt 2 dispatch.
Every terminal attempt SHALL record the closed evidence required by `SPEC.md` section 3.7.1 subject to Payload Capture Mode.
It SHALL include non-negative cumulative `output_tokens`, `output_usage_status = exact | lower_bound`, and optional presence-aware `reasoning_tokens` only when the subset is exact.
`attempt_outcome` SHALL be `completed`, `failed`, `cancelled`, `timed_out`, or `interrupted`.
`output_commitment_kind` SHALL be absent without commitment and otherwise SHALL be `reasoning`, `text`, `tool_call`, or `structured_output`.
The `reasoning` kind SHALL apply only to selected public reasoning under `projection = reasoning_structured`.
`execution_resolution` SHALL be `not_started`, `terminated`, or `unresolved`.
`capacity_release_outcome` SHALL be `released`, `already_released`, `not_applicable`, or `unresolved`.
`failure_class` SHALL use the closed section 3.7.1 vocabulary, and `failure_code` SHALL use a Controller-normalized stable value from the `SPEC.md` section 8.2 vocabulary.
Runtime, model-load, capacity, cancellation, deadline, terminal-conformance, and unknown source failures SHALL follow the normalization boundary in `SPEC.md` section 3.7.1.
A raw source code MAY persist separately only under `full` and SHALL NOT control retry, public mapping, or metrics.
Closed attempt evidence SHALL remain durable under `none` and `metadata`, while unknown raw runtime text SHALL NOT become durable evidence or a metric label.
Attempt 1 SHALL have no excluded Node, while attempt 2 SHALL record exactly attempt 1's durable Node UUID as excluded.
A target reference SHALL be an approved stable identifier under `full` or a deterministic hash outside `full`, never a raw target address.
The coarse Request SHALL terminalize exactly once.
This requirement refines `SPEC.md` section 3.7.1 and preserves `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Attempt 2 boundary is atomic

- **WHEN** every retry gate passes for a valid different compatible candidate
- **THEN** Orchard atomically appends attempt 1 terminal evidence with `retried` and the sole attempt 2 started event
- **AND** the dispatcher consumes that started context without appending another

#### Scenario: Hidden reasoning is not a commitment kind

- **WHEN** a final-only attempt emits hidden reasoning and then fails before selected output
- **THEN** terminal evidence keeps `output_committed = false`
- **AND** `output_commitment_kind` remains absent

#### Scenario: Attempt 2 start persistence fails

- **WHEN** Orchard cannot durably append attempt 2 started evidence
- **THEN** attempt 2 dispatch does not begin
- **AND** the Request terminalizes through the existing orchestration persistence failure

#### Scenario: Existing request events remain readable

- **WHEN** Orchard reads an older inference-turn result without enriched reasoning or attempt fields
- **THEN** the row remains readable
- **AND** closed validation applies only when constructing the enriched terminal shape

### Requirement: Logical accounting remains once per Request

Input-token accounting SHALL occur once and the output reservation SHALL remain held between attempts.
Quota SHALL reconcile once when the logical Request terminalizes.
The effective Payload Capture Mode SHALL apply unchanged to both attempts.
Logical output usage SHALL use the selected terminal attempt's exact total generated output tokens when proven, including hidden or selected public reasoning and final-answer tokens.
A Controller-synthesized failure that cannot prove the exact terminal total SHALL use the latest validated cumulative usage with `output_usage_status = lower_bound`.
Every selected terminal attempt SHALL carry `output_usage_status = exact | lower_bound`, and logical Request accounting SHALL preserve that status through quota reconciliation, metrics, audit, and every capture mode.
An exact reasoning-token subset MAY be retained as internal non-content detail when proven, and unavailable reasoning usage MUST remain distinct from an exact zero.
The subset MUST NOT cross the Runtime Endpoint or public API boundary until separately accepted presence-aware contracts preserve that distinction.
No lower-bound count may be serialized through an existing public field that implies an exact total.
Discarded pre-commit attempt output SHALL remain physical attempt telemetry and MUST NOT contribute logical public usage, output, or a second quota charge.
This requirement refines `SPEC.md` sections 5.3, 5.8, 9.1, and 10.10 and preserves `docs/decisions/0019-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Attempt 1 is discarded

- **WHEN** attempt 1 fails before commitment and attempt 2 starts
- **THEN** attempt 1 does not release or reacquire quota
- **AND** its buffered events and usage do not become logical public output or usage
- **AND** capture policy does not widen

#### Scenario: Controller synthesizes terminal failure

- **WHEN** the Controller has a latest validated cumulative output count but cannot prove the exact terminal total
- **THEN** logical usage uses that validated cumulative count
- **AND** `output_usage_status = lower_bound` remains durable through accounting and capture
- **AND** Orchard does not estimate a reasoning subset

#### Scenario: Exact zero remains distinct from a lower bound

- **WHEN** one terminal attempt proves `output_tokens = 0` and another Controller-synthesized terminal has a validated cumulative count of zero without exact terminal proof
- **THEN** the first records `output_usage_status = exact`
- **AND** the second records `output_usage_status = lower_bound`
- **AND** quota, metrics, audit, capture, and replay consumers do not collapse the two states
