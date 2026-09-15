## ADDED Requirements

### Requirement: Retained worker recovery evidence

Runtime Endpoint observations SHALL retain exact-key worker recovery state, current authenticated recovery epoch/revision, and hydration validity independently of live loaded workers. The Controller SHALL preserve these fields and their existing authenticated freshness/ordering in durable observation projections; projections MUST NOT replace synchronous checkpoint authority. BEAM and gRPC compatibility paths SHALL convey equivalent evidence. Missing/malformed/old-epoch evidence MUST NOT establish recovery eligibility. This implements `SPEC.md` §12.2.3 without changing general Node health or §5.10.

#### Scenario: Open placement has no live worker
- **WHEN** the last worker for an exact key is removed after a crash-loop trip
- **THEN** status still reports that key as failed with open recovery state and current epoch/revision
- **AND** unrelated placement evidence remains independently eligible

#### Scenario: Clean cold key obtains eligibility without loading
- **WHEN** a new/cold key lacks positive exact-key recovery evidence
- **THEN** `InspectWorkerRecoveryPlacement` hydrates authoritative checkpoint state and returns current-epoch eligibility without loading or clearing
- **AND** an authoritatively absent key may be reported clean without operator re-arm

#### Scenario: Legacy or stale observation cannot authorize admission
- **WHEN** an observation lacks recovery support or its identity, epoch, freshness, or ordering is invalid
- **THEN** its loaded placement data cannot establish recovery eligibility
- **AND** fresh authenticated current evidence is required rather than a legacy-loaded fallback

### Requirement: Authorized recovery and checkpoint operations

The Runtime Endpoint control boundary SHALL support exact-key `RecoverWorkerPlacement` and authenticated recovery checkpoint hydration/write semantics under `SPEC.md` §12.2.2. Operator recovery SHALL route through the authenticated Active Controller Operator API; ordinary load/unload callers MUST NOT acquire recovery authority by setting flags. Node-to-Controller checkpoint operations SHALL restrict writes to the authenticated Node's exact keys and current epoch/revision. Only the Node SHALL originate mutations; the Controller SHALL execute transactional CAS on Node request, while Operator API forwarding SHALL NOT pre-claim or mutate the checkpoint. No direct Node database access is required.

The narrow Operator API SHALL provide status at `GET /ops/v1/worker-recovery/nodes/:node_id/models/:model_id` with exact version, and recovery at the corresponding `POST` with version, `clear | unload | reload`, expected epoch/revision, bounded command identifier, and nonblank reason. Existing authentication, write authorization, identity resolution, and audit rules SHALL apply. Recovery MUST NOT modify Controller §5.10 breaker state.

#### Scenario: Authenticated operator clears exact placement
- **WHEN** the Active Controller authorizes an operator clear with matching key/epoch/revision
- **THEN** it invokes the dedicated Node recovery operation and returns success only after resolved cleanup and committed checkpoint
- **AND** the existing audit facility records bounded recovery outcome metadata

#### Scenario: Forwarding fails before Node claim
- **WHEN** the Operator API cannot deliver an authorized recovery command to the Node
- **THEN** it has not changed the checkpoint revision or created a pending operation
- **AND** only a command received and serialized by the Node can originate its authoritative CAS

#### Scenario: Untrusted caller supplies force or operator flag
- **WHEN** an ordinary load/unload caller attempts to clear using force or claimed operator metadata
- **THEN** it does not clear recovery state on either BEAM or gRPC paths

#### Scenario: Checkpoint acknowledgement is lost
- **WHEN** the Node cannot confirm a pre-effect checkpoint or operator completion acknowledgement
- **THEN** it does not infer success or repeat destructive effects
- **AND** status/revision reconciliation determines whether the result is committed, stale, or unresolved

#### Scenario: Another Node or stale owner writes a checkpoint
- **WHEN** a checkpoint operation targets another Node's key or fails current epoch/revision comparison
- **THEN** the Controller refuses the write without changing durable recovery state

### Requirement: Structured recovery admission refusal

A Node SHALL refuse ordinary ensure and execution for backoff, restarting, open, or recovery-required placements before all fast paths, as required by `SPEC.md` §12.2.3. The result SHALL be structurally distinguishable from an actually attempted model-load failure and carry the bounded reason `worker_restart_backoff`, `worker_restart_in_progress`, `placement_crash_breaker_open`, or `placement_recovery_required`. Controller normalization SHALL occur before generic ModelLoadFailure conversion.

#### Scenario: Stale loaded observation reaches the Node
- **WHEN** a Controller attempts ensure or execution using loaded evidence for a currently blocked key
- **THEN** Node admission returns the structured recovery refusal without starting a load or inference
- **AND** it does not count that refusal as a crash

#### Scenario: Refusal after Request attempt starts
- **WHEN** an attempt receives a proven pre-execution recovery refusal with resolved identity and releasable capacity
- **THEN** it normalizes to existing `capacity_rejection` with stable `model_busy` and no model-load category
- **AND** normal execution/capacity evidence and unchanged retry gates apply with no §5.10 breaker event

#### Scenario: Real failure is not hidden by recovery state
- **WHEN** an actually run Request attempt loses a worker or fails its model load
- **THEN** its existing failure classification and §5.10 attribution remain intact
- **AND** later residency recovery/refusals do not add duplicate attempt events

#### Scenario: Unresolved identity or occupancy remains unresolved
- **WHEN** recovery refusal is accompanied by unresolved identity or runtime occupancy
- **THEN** existing uncertainty classification and cancellation/deadline precedence remain authoritative
- **AND** the Controller does not falsely report resolved capacity rejection or release
