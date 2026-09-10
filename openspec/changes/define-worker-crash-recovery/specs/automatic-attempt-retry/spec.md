## ADDED Requirements

### Requirement: Worker Recovery Never Replays A Request

The Node Agent worker recovery state machine MUST NOT replay an inference Request, reconstruct an Inference Attempt, re-emit buffered output, or decide that attempt 2 may start.
It MAY notify the current Runtime Endpoint request owner once that the exact worker generation failed.
The Controller SHALL remain the sole owner of retry and SHALL preserve Output Commitment, caller liveness, absolute deadline, stable failure classification, first-Node identity, execution resolution, affirmative capacity release, different-Node exclusion, and the two-attempt maximum.
Restart eligibility, replacement success, or explicit worker recovery MUST NOT satisfy or bypass any Request retry gate.
Typed worker-recovery refusals before worker launch or execution acceptance SHALL be non-retryable under their specified `capacity_rejection`, `occupancy_unresolved`, or `runtime_failure` mapping and MUST NOT be normalized as `ModelLoadFailure` or a retryable inference failure.
This requirement preserves `SPEC.md` §§5.8 through 5.10, 12.2, and 12.7.

#### Scenario: Worker crashes before Output Commitment

- **WHEN** a worker crashes before Output Commitment and its Request owner receives one failure
- **THEN** only the Controller evaluates the existing closed retry gates
- **AND** a Node Agent restart timer neither replays the Request nor starts attempt 2

#### Scenario: Worker crashes after Output Commitment

- **WHEN** a worker crashes after Output Commitment
- **THEN** the logical Request does not retry
- **AND** later worker restoration cannot regenerate or replace committed output

#### Scenario: Capacity release is unresolved

- **WHEN** the failed worker's execution or capacity release cannot be resolved affirmatively
- **THEN** automatic attempt retry fails closed under the existing precedence
- **AND** a successful worker replacement does not change that outcome

#### Scenario: Stale Controller recovery view reaches the Node

- **WHEN** the Controller starts an attempt and the Node refuses load or pre-acceptance execution from newer open, backoff, pending-operation, unresolved-custody, or unavailable-authority recovery state
- **THEN** the Controller uses the closed typed recovery-refusal mapping and releases its allocation effectively once
- **AND** no automatic retry or §5.10 contribution is synthesized from the refusal

### Requirement: Recovery And Attempt Evidence Remain Distinct

Worker recovery evidence SHALL use recovery placement, recovery generation, worker generation, incident, and recovery-operation identities.
Inference Attempt evidence SHALL continue to use the logical Request and attempt identities defined by the existing append-only Request Event contract.
One evidence class MUST NOT be reused as the idempotency identity for the other.
This requirement preserves exactly-once accounting in `SPEC.md` §§3.7.1, 5.8 through 5.10, and 12.2.

#### Scenario: Duplicate worker incident and attempt outcome arrive

- **WHEN** duplicate delivery occurs for both one worker incident and one affected actual attempt outcome
- **THEN** the worker incident changes crash-loop state once
- **AND** the attempt outcome contributes to at most one eligible §5.10 breaker once
