## ADDED Requirements

### Requirement: Validated Runtime Endpoint output controls commitment
The Controller SHALL evaluate Output Commitment only after a Runtime Endpoint event passes protocol validation and before the event reaches a public handler or serializer.
A non-empty text delta, a valid tool-call delta with stable non-empty identity, or a future content-bearing structured-output delta SHALL commit output.
When commitment occurs, the Controller SHALL deliver all earlier buffered validated events in original order before exposing the committing event.
Accepted, progress, usage, model-load, empty text, and terminal events SHALL NOT commit output.
This requirement traces to `SPEC.md` §5.8, §5.9, and `docs/decisions/0017-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Valid tool-call identity commits before delivery
- **WHEN** the Runtime Endpoint emits a valid tool-call delta with a stable identity
- **THEN** the Controller records tool-call Output Commitment before downstream delivery
- **AND** it delivers earlier buffered validated events in original order before the committing event
- **AND** a later transport or handler failure does not retry

#### Scenario: Malformed output does not become safe retry input
- **WHEN** a Runtime Endpoint output event fails protocol validation
- **THEN** Orchard does not treat it as valid committed output
- **AND** the protocol-conformance failure remains non-retryable

### Requirement: Runtime retryability is necessary but insufficient
An inference Runtime Endpoint `Failed` event SHALL qualify for Automatic Attempt Retry only when `retryable` is true, its stable code is one of `node_unavailable`, `node_timeout`, `runtime_unavailable`, `resource_exhausted`, `timeout`, `worker_unavailable`, or `worker_down`, no Output Commitment occurred, and every Controller-owned retry gate passes.
A model-load result SHALL qualify only when its normalized category is `acquisition_failed`, `runtime_unavailable`, `resource_exhausted`, or `timeout`; its failure code or message SHALL NOT independently authorize retry.
Unknown codes, unknown categories, `retryable: false`, and deterministic failures SHALL fail closed.
`runtime_endpoint_missing_terminal`, `runtime_endpoint_duplicate_terminal`, and `runtime_endpoint_post_terminal_event` SHALL remain non-retryable source classifications and SHALL normalize to the existing stable Controller-owned terminal failure code for restricted capture.
This requirement traces to `SPEC.md` §5.8, §§12.1-12.3, §12.7, and `docs/decisions/0017-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Allowlisted transient failure qualifies for gate evaluation
- **WHEN** a pre-commit Runtime Endpoint failure has `retryable: true` and an allowlisted transient code
- **THEN** the Controller evaluates the remaining identity, execution, release, caller, deadline, and alternative-Node gates
- **AND** neither the flag nor code alone authorizes retry

#### Scenario: Model-load category controls retry eligibility
- **WHEN** model loading returns a normalized transient category with an arbitrary or misleading failure code
- **THEN** Orchard evaluates retry eligibility from the normalized category
- **AND** the failure code or message does not independently authorize retry

#### Scenario: Missing terminal stays non-retryable
- **WHEN** an accepted stream ends without exactly one terminal event
- **THEN** Orchard preserves the `runtime_endpoint_missing_terminal` source classification
- **AND** normalizes restricted-capture durable evidence to the existing stable Controller-owned terminal failure code
- **AND** no Automatic Attempt Retry begins

### Requirement: Execution resolution precedes retry
The Controller SHALL allow a pre-acceptance failure to qualify for retry only after cleanup and capacity release are affirmatively resolved.
An accepted pre-commit failure MAY qualify only when a valid terminal event or cancellation drain proves execution termination.
A transport loss whose drain cannot prove termination SHALL preserve quarantine and record `occupancy_unresolved`.
This requirement traces to `SPEC.md` §4.6.2, §5.9, §12.1, §12.2, and `docs/decisions/0017-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Accepted execution is drained
- **WHEN** an accepted pre-commit attempt fails transiently and cancellation drain proves termination
- **THEN** execution is resolved
- **AND** retry may continue through the remaining gates

#### Scenario: Accepted execution remains ambiguous
- **WHEN** cancellation drain cannot prove termination
- **THEN** Orchard quarantines the admitted Node when identity is known
- **AND** records `occupancy_unresolved`
- **AND** no attempt 2 begins

### Requirement: Pre-commit attempt events remain isolated
Validated events that occur before Output Commitment SHALL remain attempt-local until the retry decision is known.
If attempt 2 starts, attempt 1 buffered events SHALL NOT reach the logical public response.
If retry is declined or the attempt completes without commitment, the final attempt's buffered events SHALL be delivered in original order.
This requirement traces to `SPEC.md` §5.8 and `docs/decisions/0017-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Discarded attempt does not leak public events
- **WHEN** attempt 1 emits only pre-commit control or usage events and then qualifies for retry
- **THEN** those attempt 1 events are discarded from the logical public response
- **AND** attempt 2 begins with a clean public event stream
