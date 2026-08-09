## ADDED Requirements

### Requirement: Observable idempotent release before alternate acquisition
Allocation and temporary-claim release SHALL remain idempotent and SHALL report `released`, `already_released`, `not_applicable`, or `unresolved`.
An unavailable authority, ambiguous cleanup, unresolved cancel drain, or unavailable quarantine store MUST NOT be reported as confirmed release.
Attempt 2 scheduling and acquisition SHALL require attempt 1 execution resolution and an affirmative release result.
Opaque claim tokens MUST remain process-local and MUST NOT be persisted or transferred between attempts.
This requirement traces to `SPEC.md` §4.6.2, §5.9, and `docs/decisions/0017-one-request-bounded-alternate-node-retry.md`.

#### Scenario: First claim is released before second acquisition
- **WHEN** attempt 1 ends before Output Commitment and qualifies for retry
- **THEN** Orchard affirmatively resolves execution and releases the first Node claim
- **AND** only then may it schedule or acquire capacity on a different Node

#### Scenario: Authority failure is unresolved
- **WHEN** the capacity authority exits or cannot confirm release
- **THEN** the release result is `unresolved`
- **AND** no attempt 2 schedule or acquisition begins

#### Scenario: Defensive duplicate release is harmless
- **WHEN** cleanup releases a claim that was already released effectively once
- **THEN** the result is `already_released`
- **AND** capacity is not incremented twice

### Requirement: Post-start capacity outcomes fail closed
Every dispatch-capacity acquisition, acceptance-gate, or revalidation rejection after `request_step.started` SHALL terminate that attempt without queue re-entry.
On attempt 1, ordinary scarcity SHALL record `not_retryable`, a held same-Request claim or unavailable quarantine store SHALL record `occupancy_unresolved`, and unverified or mismatched Node identity SHALL record `identity_unresolved`.
On either attempt, caller disconnect SHALL record `cancelled`.
On attempt 2, every other unsuccessful capacity outcome SHALL record `retry_exhausted` while preserving its specific failure class and code.
This requirement traces to `SPEC.md` §4.6.2, §5.4, §5.9, and `docs/decisions/0017-one-request-bounded-alternate-node-retry.md`.

#### Scenario: Ordinary scarcity occurs after attempt 1 starts
- **WHEN** attempt 1 post-start capacity revalidation reports ordinary scarcity
- **THEN** Orchard releases the claim effectively once
- **AND** attempt 1 records `not_retryable`
- **AND** the Request does not re-enter the queue

#### Scenario: Capacity failure occurs on attempt 2
- **WHEN** attempt 2 ends on a post-start capacity failure without caller cancellation
- **THEN** Orchard preserves the specific capacity failure class and code
- **AND** attempt 2 records `retry_exhausted`
- **AND** Orchard starts no third attempt

#### Scenario: Attempt 1 still holds a claim
- **WHEN** attempt 1 acquisition observes a held claim for the same logical Request
- **THEN** Orchard fails closed with `occupancy_unresolved`
- **AND** overlapping attempts do not run

#### Scenario: Attempt 1 candidate identity cannot prove exclusion
- **WHEN** attempt 1 capacity revalidation cannot verify the candidate's durable Node identity
- **THEN** Orchard records `identity_unresolved`
- **AND** it does not acquire alternate capacity
