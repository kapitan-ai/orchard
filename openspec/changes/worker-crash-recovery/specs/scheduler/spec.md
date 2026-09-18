## ADDED Requirements

### Requirement: Worker recovery eligibility without load bypass

The Scheduler and dispatch acceptance SHALL enforce `SPEC.md` §12.2.3 recovery eligibility for the exact Node/model/version before loaded/cold ranking, capacity acquisition, and final execution admission. Backoff, restarting, open, recovery-required, or untrusted/unknown recovery evidence MUST NOT be bypassed by loaded hints, reconciliation, preload, force flags, or §5.10 clear. The Node's current admission check SHALL remain authoritative when Controller evidence lags.

#### Scenario: Loaded and cold paths reject the same blocked key
- **WHEN** a candidate's recovery evidence reports backoff, restarting, open, or recovery-required
- **THEN** the candidate is rejected with its bounded recovery reason before ranking regardless of a loaded hint
- **AND** no normal ensure-load or reconciliation path clears that state

#### Scenario: State changes after capacity acquisition
- **WHEN** an eligible snapshot becomes stale because the worker crashes before execution acceptance
- **THEN** final revalidation and Node admission prevent execution on the blocked key
- **AND** any held Request capacity follows existing release/uncertainty rules

#### Scenario: Other placements remain eligible
- **WHEN** one Node/model/version opens its crash breaker
- **THEN** another version or model on that Node and that model on another Node remain independently selectable under their own policies
- **AND** this event alone does not suppress Node health

### Requirement: Recovery rejection preserves Controller breaker and retry policy

Pre-attempt recovery rejection SHALL remain an eligibility outcome under existing queue/no-candidate behavior, not create an attempt or breaker event. Post-start proven pre-execution recovery refusal SHALL be processed by the existing closed retry gates as `capacity_rejection`, as specified in `SPEC.md` §12.2.3. Actual failed attempts SHALL keep their unchanged §5.10 attribution; neither breaker clear SHALL clear the other policy.

#### Scenario: No eligible recovery-ready candidate before an attempt
- **WHEN** all candidates are excluded by recovery state before `request_step.started`
- **THEN** existing no-eligible-candidate/queue-budget behavior applies
- **AND** no attempt-derived §5.10 event is emitted

#### Scenario: Post-start refusal does not manufacture a load failure
- **WHEN** stale evidence causes a proven pre-execution recovery refusal after attempt start
- **THEN** the existing closed gates process `capacity_rejection` and `model_busy`, not `model_load_failure` or `worker_or_node_loss`
- **AND** no retry or §5.10 event is added solely because of the refusal

#### Scenario: Clears remain independent
- **WHEN** operator recovery clears the Node §12.2 state
- **THEN** an existing Controller §5.10 suppression remains effective
- **AND** clearing §5.10 does not authorize a Node with open §12.2 state to load

## MODIFIED Requirements

### Requirement: Production scheduling does not probe status inline
Production candidate construction and final dispatch revalidation SHALL use durable
observations and current Controller-owned facts without status-probing Runtime Endpoints on
the production scheduling path.
Database unavailability, incomplete reads, or absence of usable facts MUST NOT use stale
process memory or the unmanaged compatibility branch.
Initial allocation/legacy-claim acquisition and final acceptance-gated ADR 0013
revalidation SHALL remain mandatory.
Worker recovery admission SHALL decide from the durable observation and its placement
projections on that path.
A placement that is not loaded holds no recovery state to resolve, so a fresh authenticated
recovery epoch SHALL admit it, while a loaded placement without exact current-epoch evidence
SHALL remain refused.
Only the bounded unmanaged-compatibility wave MAY resolve a cold placement with a targeted
read-only recovery query, and a transport that cannot answer that query SHALL fall back to
epoch-only evidence rather than be treated as unrecovered.
This requirement refines `SPEC.md` §4.6.2, §5.9, and §12.2.3.

#### Scenario: Production snapshot is available
- **WHEN** fresh intersected production candidates exist
- **THEN** MultiNode filters and ranks them without a Runtime Endpoint status call

#### Scenario: Facts change after selection
- **WHEN** newer observation or Controller facts remove authority before execution
- **THEN** final revalidation refuses `ExecuteInference`
- **AND** pre-acceptance authority is released exactly once under existing retry/queue rules

#### Scenario: Cold production candidate is admitted without a recovery query
- **WHEN** a production candidate reports a fresh recovery epoch and no loaded placement for
  the requested model
- **THEN** recovery admission accepts it with no Runtime Endpoint status or inspection call
- **AND** a loaded placement lacking exact current-epoch evidence is still refused without a
  reprobe

#### Scenario: Uninspectable transport does not imply unrecovered state
- **WHEN** the bounded unmanaged-compatibility wave reaches a transport that cannot answer a
  recovery query
- **THEN** admission uses the authenticated epoch alone
- **AND** the candidate is not refused for missing recovery evidence
