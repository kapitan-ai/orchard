## MODIFIED Requirements

### Requirement: Retained worker recovery evidence

Runtime Endpoint observations SHALL retain exact-key worker recovery state, current authenticated recovery epoch/revision, and hydration validity independently of live loaded workers. The Controller SHALL preserve these fields and their existing authenticated freshness/ordering in durable observation projections; projections MUST NOT replace synchronous checkpoint authority. BEAM and gRPC compatibility paths SHALL convey equivalent evidence. Missing/malformed/old-epoch evidence MUST NOT establish recovery eligibility. This implements `SPEC.md` §12.2.3 without changing general Node health or §5.10.

Existing operator and scheduler exact-key queries SHALL retain hydration semantics. The cluster-reader status path SHALL instead inspect already-hydrated current evidence without hydration, epoch claim, recovery/checkpoint mutation or observation persistence. It SHALL return `503 worker_recovery_unavailable` when such evidence is unavailable, never infer clean state from absence. This is the explicit reader exception to §12.2.3, not a change to cold-placement scheduling authority.

#### Scenario: Open placement has no live worker
- **WHEN** the last worker for an exact key is removed after a crash-loop trip
- **THEN** status still reports that key as failed with open recovery state and current epoch/revision
- **AND** unrelated placement evidence remains independently eligible

#### Scenario: Clean cold key obtains eligibility without loading
- **WHEN** a new/cold key lacks positive exact-key recovery evidence on the existing operator or scheduler path
- **THEN** `InspectWorkerRecoveryPlacement` hydrates authoritative checkpoint state and returns current-epoch eligibility without loading or clearing
- **AND** an authoritatively absent key may be reported clean without operator re-arm

#### Scenario: Reader cannot hydrate a cold key
- **WHEN** the reader status path requests an exact key without already-hydrated current evidence
- **THEN** it returns `503 worker_recovery_unavailable` without claiming an epoch, hydrating, checkpointing or inferring clean state
- **AND** a valid already-hydrated result may be projected through the reader schema without changing its source state

#### Scenario: Legacy or stale observation cannot authorize admission
- **WHEN** an observation lacks recovery support or its identity, epoch, freshness, or ordering is invalid
- **THEN** its loaded placement data cannot establish recovery eligibility
- **AND** fresh authenticated current evidence is required rather than a legacy-loaded fallback

#### Scenario: Fresh epoch reports stored nonclean keys before cold absence
- **WHEN** a Node Agent restarts with stored checkpoints that are not proven clean
- **THEN** it lists those keys through the authenticated checkpoint path and hydrates each one before its status reports `worker_recovery_epoch`
- **AND** until then it reports no epoch, so its projection establishes no cold absence and an unavailable listing or read stays fail-closed

#### Scenario: Bounded recovery projection omits an exact key
- **WHEN** a placement projection has reached its 40-entry bound and omits the requested model reference
- **THEN** Orchard treats that absence as incomplete rather than proof of a cold placement
- **AND** valid exact-key recovery evidence included at the bound remains usable

#### Scenario: Invalid recovery record cannot become absence
- **WHEN** a projected recovery record has a valid model reference but invalid recovery evidence, or has an invalid model reference
- **THEN** Orchard preserves an invalid indication and fails eligibility closed
- **AND** it does not silently drop the record into cold-placement absence

### Requirement: Authorized recovery and checkpoint operations

The Runtime Endpoint control boundary SHALL support exact-key `RecoverWorkerPlacement` and authenticated recovery checkpoint hydration/write semantics under `SPEC.md` §12.2.2. Operator recovery SHALL route through the authenticated Active Controller Operator API; for the Node Agent inside the Controller's own BEAM in all-in-one source development, that API SHALL forward the same validated and audited command in-process, bound to that Node Agent's identity. Ordinary load/unload callers MUST NOT acquire recovery authority by setting flags. Node-to-Controller checkpoint operations SHALL restrict writes to the authenticated Node's exact keys and current epoch/revision. Only the Node SHALL originate mutations; the Controller SHALL execute transactional CAS on Node request, while Operator API forwarding SHALL NOT pre-claim or mutate the checkpoint. No direct Node database access is required.

The narrow Operator API SHALL provide status at `GET /ops/v1/worker-recovery/nodes/:node_id/models/:model_id` with exact version, and recovery at the corresponding `POST` with version, `clear | unload | reload`, expected epoch/revision, bounded command identifier, and nonblank reason. Existing authentication, write authorization, identity resolution, and audit rules SHALL apply to recovery commands and existing operator/admin status. Reader status SHALL additionally admit valid cluster `cluster_reader` authority through the [reader contract](../read-only-cluster-role/spec.md), retaining Active leadership and identity validation but using only non-hydrating evidence and a bounded reader representation. This grant SHALL NOT authorize POST, preview, checkpoint operations or Node trust. The Operator API SHALL reach an admitted Node through its activation-probe target as well as an active Node through its inference target, because both already hold checkpoint authority. Recovery MUST NOT modify Controller §5.10 breaker state.

#### Scenario: Authenticated operator clears exact placement
- **WHEN** the Active Controller authorizes an operator clear with matching key/epoch/revision
- **THEN** it invokes the dedicated Node recovery operation and returns success only after resolved cleanup and committed checkpoint
- **AND** the existing audit facility records bounded recovery outcome metadata

#### Scenario: Reader inspects but cannot recover
- **WHEN** an enabled cluster-reader API Client requests status for a known exact target with valid already-hydrated evidence on Active
- **THEN** it receives only the reader recovery projection
- **AND** posting recovery or preview returns `403 operator_required` before forwarding any command

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
