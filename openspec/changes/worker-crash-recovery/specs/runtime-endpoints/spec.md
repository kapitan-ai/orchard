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

## MODIFIED Requirements

### Requirement: Versioned bounded heartbeat candidate payload
`node_heartbeats.payload` SHALL use Controller-produced schema version `1` with a closed
allowlist.
The row columns SHALL own canonical trusted `node_id` and `observed_at`.
The JSON envelope SHALL contain `schema_version`, `validity`, and optional
`invalid_reason`.
Allowed observation keys SHALL be `endpoint_id`, `target`, `availability`,
`worker_state`, `aggregate_active_request_count`, `aggregate_max_concurrency`,
`aggregate_capacity_evidence`, `placements`, `runtime_memory_budgets`,
`runtime_prefix_cache_statuses`, `supports_prompt_token_ids`, and
`worker_recovery_epoch`.
Nested keys SHALL use the existing `Target`, `ModelRef`, `Placement`,
`PlacementCapacity`, `MemoryBudget`, and `PrefixCacheStatus` vocabulary described by
ADR 0017, extended by the `worker_recovery` placement projection defined for
`SPEC.md` §12.2.3.
`worker_recovery_epoch` SHALL be the Node's current authenticated recovery epoch
string, and the nested `worker_recovery` projection SHALL carry exact-key
identity, epoch, revision, state, hydration validity, eligibility, and refusal
reason.
Neither field is a derived eligibility boolean: admission SHALL still be decided
by the Scheduler from this evidence.
This requirement refines `SPEC.md` §4.6.1 and §8.

Maps and lists MUST be capped at 40 entries, nesting at depth 4, and otherwise-unbounded
strings at 512 bytes.
Existing narrower domain bounds and numeric/status vocabularies MUST take precedence.
The encoded payload MUST be capped by validated
`node_heartbeat_payload_max_bytes`, default 262144 bytes.
Memory-budget entries SHALL use `MemoryBudget.normalize/1`.
Prefix-cache entries SHALL use `PrefixCacheStatus.normalize/1` and MUST NOT persist raw
`prefix_cache_fingerprints`.

An unknown schema, malformed required envelope, or payload still over the byte cap after
normalization SHALL produce a minimal versioned `validity = "invalid"` envelope with a
stable `invalid_reason`.
Such a row MUST NOT produce a positive scheduler candidate.
Unknown fields SHALL be dropped.

The payload MUST NOT contain credentials, certificate/API secrets, DSNs, prompt or response
bodies, raw tokens, tenant identifiers, raw prefix-cache fingerprint sets, raw
metadata/diagnostics, local paths/evidence, tool session identifiers, Controller policy,
Controller-accounted Allocation, quarantine, authority decisions, issue #128 acquirability,
or any derived eligibility boolean.

#### Scenario: Valid observation uses canonical bounded fields
- **WHEN** an accepted observation contains supported candidate evidence
- **THEN** Orchard persists only schema-version-1 allowlisted canonical fields
- **AND** every structural, string, numeric, status, and total-byte bound is enforced

#### Scenario: Oversize payload becomes invalid evidence
- **WHEN** normalized JSON still exceeds `node_heartbeat_payload_max_bytes`
- **THEN** Orchard commits a bounded minimal invalid envelope atomically with the Node and
  aggregate capacity updates
- **AND** candidate evaluation uses `dispatch_capacity_facts_unavailable`

#### Scenario: Sensitive and raw fingerprint data is excluded
- **WHEN** an observation contains prohibited fields or raw prefix-cache fingerprints
- **THEN** those fields are not persisted
- **AND** only sanitized prefix-cache status, fingerprint count, and warmth indicator may
  remain

#### Scenario: Recovery evidence travels inside the closed allowlist
- **WHEN** an accepted observation reports a worker recovery epoch and per-placement
  recovery projection
- **THEN** Orchard persists both inside schema version `1` under the same entry, depth,
  string, and byte bounds
- **AND** a candidate snapshot read reproduces them without widening the allowlist to any
  other new key
