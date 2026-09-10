## ADDED Requirements

### Requirement: Complete family migration requires shared authorization parity

Under proposed `SPEC.md` §§7.3, 7.4, 10.4, 10.9, and 11.9, each Controller-owned operation family SHALL be marked COMPLETE only after Console, API, and portable CLI use the same authoritative action/resource/scope policy and domain operation contract.
Its contract SHALL define authentication audiences, principal and target scope, leadership, audit actor, idempotency, preview/confirmation, secret return, revocation concurrency, and degraded-Controller behavior.
Parity SHALL be evaluated for equivalent effective authority admitted by each surface and MUST NOT imply a transport supports principals its admission policy denies.
The implementation SHALL inventory all existing family entry points and remove or delegate alternate authority paths before completion.
Its retained-writer ledger SHALL include Portal self-service/logout/epoch paths, Console session lifecycle, batch rotation/provisioning, grants, recovery, and direct-DB CLI writers, each with explicit authority, fences, audit, and completion disposition.
Every writer SHALL satisfy action-policy/session/fence/audit compatibility before cutover even when its broader operation family is deferred; incompatible software SHALL remain stopped or isolated from the live post-cutover authority store.
Family completion SHALL require positive parity tests, denied-scope and revoked-authority tests, stale LiveView and concurrency tests, failure-path coverage, and the applicable repository quality workflow.
Passing structural OpenSpec validation or introducing HTTP wrappers SHALL NOT establish family completion.
Unmigrated families SHALL remain explicitly identified as the current migration baseline without a blanket claim of cross-surface completion.

#### Scenario: CLI still has an alternate local write

- **WHEN** Console and API use shared policy but a normal family CLI path can mutate through direct Repo access
- **THEN** the family remains incomplete
- **AND** local recovery cannot be used to excuse that ordinary-operation bypass

#### Scenario: First credential family completes

- **WHEN** credential metadata inspection and revocation satisfy the family contract on Console, Admin API, and portable CLI with passing parity and failure-path evidence
- **THEN** that family can be marked COMPLETE through reviewed acceptance
- **AND** credential creation, rotation, API Client disablement, and other families remain separately tracked
