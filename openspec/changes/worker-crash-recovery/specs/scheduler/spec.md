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
