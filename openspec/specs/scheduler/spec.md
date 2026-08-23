# scheduler Specification

## Purpose
Define how Orchard constructs production scheduler candidates from durable observations, bounds explicitly unmanaged compatibility probing, maintains ingestion-driven queue-capacity hints, and explains and revalidates dispatch decisions.
## Requirements
### Requirement: Exact production candidate universe
Each production MultiNode scheduling attempt SHALL limit its candidate universe to the
intersection of the effective normalized targets returned by
`Inference.runtime_endpoint_targets/0`, the exact certificate-backed active targets
returned by `Nodes.active_runtime_endpoint_targets/0`, and the latest accepted
scheduler-fresh heartbeat rows whose Node and normalized target identities match.
A fresh row MUST NOT admit an unconfigured, inactive, untrusted, address-only, removed,
reconfigured, or identity-mismatched target.
This requirement refines `SPEC.md` §4.6.1, §5.5, and ADR 0017.

#### Scenario: Trusted configured target has fresh evidence
- **WHEN** the effective target, trusted active inventory, and latest fresh heartbeat have
  the same Node and normalized target identity
- **THEN** the target enters the request-scoped production candidate snapshot

#### Scenario: Historical target is no longer effective
- **WHEN** a fresh heartbeat remains for a target that was removed or reconfigured
- **THEN** the target is excluded from the candidate universe

#### Scenario: Identity does not intersect
- **WHEN** address, target, or Node identity differs across the three sources
- **THEN** Orchard excludes the candidate with `runtime_identity_mismatch`

### Requirement: Request-scoped Postgres production snapshot
Each production scheduling attempt SHALL obtain one immutable request-scoped candidate
snapshot using one Postgres statement or a read transaction with equivalent snapshot
semantics.
The query SHALL deterministically select the latest accepted row by `observed_at` and row
identity per intersected target.
It MAY return different observation times for different Nodes and MUST NOT claim
same-instant monitor-cycle atomicity.
Both the Node heartbeat and selected row MUST satisfy
`node_freshness_threshold_ms` at query time.
This requirement refines `SPEC.md` §4.5, §5.5, and ADR 0017.

#### Scenario: Per-Node observations differ in time
- **WHEN** two intersected targets have different but scheduler-fresh observation times
- **THEN** one coherent database snapshot may include both
- **AND** each candidate remains tied to its own committed observation

#### Scenario: Observation is stale
- **WHEN** either the Node heartbeat or selected heartbeat row exceeds the freshness threshold
- **THEN** the target is rejected with `node_observation_stale`

#### Scenario: Scheduler restarts
- **WHEN** the scheduler or Active Controller restarts
- **THEN** the next production attempt reads Postgres
- **AND** no production candidate-mirror hydration is required

### Requirement: Bounded explicitly unmanaged compatibility probing
Orchard SHALL preserve the current explicitly unmanaged static fallback only when
`Inference.static_runtime_target_fallback_enabled?/0` is true, trusted admitted/active
inventory is confirmed empty, and `Inference.static_runtime_target?/1` matches the
normalized configured target.
That branch MAY run one compatibility status-probe wave over at most four deduplicated
configured targets, with one connect/status attempt per target, the existing 2000 ms
per-target timeout, and no retry.
It SHOULD complete as one bounded wave rather than serially multiplying the timeout.
The branch MUST NOT run when trusted inventory exists, inventory availability cannot be
proven, or the production snapshot fails.
It MUST NOT publish production Node-owned queue sources or change the target's explicit
unmanaged ADR 0013 classification.
This requirement refines `SPEC.md` §4.6.2, §5.5, and ADR 0017.

#### Scenario: Explicit static source-development target
- **WHEN** static fallback is enabled, trusted admitted/active inventory is confirmed empty,
  and a normalized target exactly matches explicit configuration
- **THEN** Orchard may include it through the bounded compatibility probe wave
- **AND** shared capacity evaluation treats it as explicitly unmanaged

#### Scenario: Production snapshot fails
- **WHEN** trusted inventory exists or a production snapshot cannot be read
- **THEN** Orchard does not run compatibility probes
- **AND** the exception does not become a production fallback


### Requirement: Compatibility post-load Placement Capacity revalidation
Final revalidation SHALL consume valid Placement Capacity from the successful `EnsureModelLoaded` result for an initially cold explicitly unmanaged compatibility candidate and SHALL require its model reference to exactly match the requested model.
Final revalidation SHALL preserve the captured target and resolved Node identity, aggregate capacity, availability, health, observation time and freshness behavior, and explicit unmanaged classification.
Missing, malformed, or model-mismatched post-load evidence MUST fail closed before `ExecuteInference`.
For an initially loaded compatibility candidate, missing additive load-result evidence MUST NOT replace or invalidate captured valid matching Placement Capacity; valid newer matching evidence MAY replace it.
This requirement refines `SPEC.md` §§5.5 and 5.9 and ADRs 0013 and 0017.

#### Scenario: Cold compatibility load supplies matching evidence
- **WHEN** the bounded compatibility observation found the requested model cold and `EnsureModelLoaded` succeeds with valid matching Placement Capacity
- **THEN** final revalidation evaluates that capacity with the captured identity and authority facts
- **AND** Orchard may call `ExecuteInference` only if the full evaluation remains eligible

#### Scenario: Cold compatibility load lacks usable evidence
- **WHEN** the successful load result has absent, malformed, or nonmatching Placement Capacity
- **THEN** final revalidation fails closed before `ExecuteInference`
- **AND** existing release, retry, queue, and public error behavior applies

#### Scenario: Loaded compatibility candidate receives an old-agent result
- **WHEN** the initial compatibility observation supplied valid matching Placement Capacity and the later result omits the additive field
- **THEN** final revalidation retains the captured placement capacity

### Requirement: One compatibility status attempt per logical request
The bounded explicitly unmanaged compatibility wave SHALL remain the only Controller Runtime Endpoint status operation for the logical request.
Each target SHALL receive at most one connect/status attempt with no retry through loading, final revalidation, failure handling, execution, and terminal completion.
An absent or invalid additive load-result field MUST NOT trigger another status attempt.
This requirement refines `SPEC.md` §§5.5 and 5.9 and ADR 0017.

#### Scenario: Post-load revalidation uses returned evidence
- **WHEN** a cold compatibility candidate reaches final revalidation after `EnsureModelLoaded`
- **THEN** Orchard uses the successful load result rather than status-probing the target again

#### Scenario: Old agent omits placement evidence
- **WHEN** an old agent returns a successful load result without Placement Capacity
- **THEN** the request fails closed before execution
- **AND** Orchard does not make a second status attempt

### Requirement: Production scheduling does not probe status inline
Production candidate construction and final dispatch revalidation SHALL use durable
observations and current Controller-owned facts without status-probing Runtime Endpoints on
the production scheduling path.
Database unavailability, incomplete reads, or absence of usable facts MUST NOT use stale
process memory or the unmanaged compatibility branch.
Initial allocation/legacy-claim acquisition and final acceptance-gated ADR 0013
revalidation SHALL remain mandatory.
This requirement refines `SPEC.md` §4.6.2 and §5.9.

#### Scenario: Production snapshot is available
- **WHEN** fresh intersected production candidates exist
- **THEN** MultiNode filters and ranks them without a Runtime Endpoint status call

#### Scenario: Facts change after selection
- **WHEN** newer observation or Controller facts remove authority before execution
- **THEN** final revalidation refuses `ExecuteInference`
- **AND** pre-acceptance authority is released exactly once under existing retry/queue rules

### Requirement: Queue-capacity sources remain ingestion-driven
Node-owned queue-capacity sources SHALL remain process-local hints refreshed or cleared by
the accepted-observation ingestion consumer after the observation transaction commits.
A MultiNode request snapshot MUST NOT publish, rebuild, or clear queue sources.
The shared ADR 0013 evaluation SHALL bound every positive source contribution.
This requirement refines `SPEC.md` §5.4 and ADR 0017.

Identity rejection, transport failure, heartbeat-age demotion, lifecycle/health/freshness
loss, malformed or unavailable capacity facts, failed observation commit, or evaluator/
consumer failure SHALL clear affected sources.
After QueueManager or Controller restart, Node-owned contributions SHALL start empty and
MUST be repopulated only by a new accepted eligible observation.
Explicitly unmanaged compatibility probes MUST NOT publish production sources.

#### Scenario: Accepted observation refreshes queue hints
- **WHEN** an accepted observation commits and the shared evaluation has positive slots
- **THEN** the ingestion consumer refreshes matching source-scoped loaded/cold contributions
- **AND** queued work may wake without a scheduling read

#### Scenario: QueueManager restarts
- **WHEN** QueueManager restarts
- **THEN** Node-owned source contributions are empty
- **AND** no heartbeat-history replay or request snapshot reconstructs them
- **AND** the next accepted eligible observation may repopulate them

#### Scenario: Observation fails closed
- **WHEN** observation persistence, identity, freshness, transport, or shared evaluation fails
- **THEN** Orchard clears the affected source contributions

### Requirement: Snapshot candidate SchedulerExplanation
Snapshot and bounded compatibility candidates SHALL use
`cluster_management.scheduler_explanation.v1` selected/scored, rejected, and skipped
structures.
Candidate diagnostics SHALL identify `candidate_source` as `monitor_snapshot` or
`bounded_compatibility_probe`.
No new reason vocabulary is introduced.
This requirement refines `SPEC.md` §7.3.5 and ADR 0017.

Missing or structurally malformed snapshot facts SHALL use
`dispatch_capacity_facts_unavailable`.
Stale facts SHALL use `node_observation_stale`.
Identity conflicts SHALL use `runtime_identity_mismatch`.
Existing runtime and capacity failures SHALL retain their current stable reason codes.
Eligible lower-tier candidates SHALL use `lower_tier_not_considered`.

When a coherent snapshot evaluates lifecycle-managed targets, its selected, rejected, and
skipped candidates SHALL remain explainable even when all candidates are rejected and the
existing `cluster_busy` or queue-waitable live-node-capacity outcome follows.
Inventory database unavailability SHALL preserve the current internal
`:no_active_nodes` outcome and no explanation.
Snapshot database failure after resolving the target universe SHALL use the existing
`:cluster_busy` or bounded queue outcome and no candidate explanation because no coherent
candidate list was evaluated.
Explanation build/persistence failure remains observational and MUST NOT alter inference.

#### Scenario: Snapshot selects and skips candidates
- **WHEN** a coherent snapshot selects a loaded candidate and leaves an eligible lower-tier candidate
- **THEN** the selected candidate appears in scored order with
  `candidate_source = monitor_snapshot`
- **AND** the lower-tier candidate appears in `skipped_candidates` with
  `lower_tier_not_considered`

#### Scenario: Snapshot rejects unavailable facts
- **WHEN** configured trusted targets have respectively missing, stale, identity-mismatched,
  or structurally malformed snapshot evidence
- **THEN** rejected candidates use respectively `dispatch_capacity_facts_unavailable`,
  `node_observation_stale`, `runtime_identity_mismatch`, and
  `dispatch_capacity_facts_unavailable`
- **AND** every rejected candidate carries `candidate_source = monitor_snapshot`

#### Scenario: Database is unavailable
- **WHEN** trusted inventory cannot be resolved
- **THEN** MultiNode preserves `:no_active_nodes` and emits no SchedulerExplanation
- **AND WHEN** the snapshot read fails after target resolution
- **THEN** Orchard preserves `:cluster_busy` or the bounded queue outcome and emits no
  candidate explanation
- **AND** neither case probes production targets or uses stale memory

#### Scenario: Bounded compatibility candidate is explained
- **WHEN** an explicitly unmanaged compatibility candidate is evaluated
- **THEN** its selected, rejected, or skipped entry carries
  `candidate_source = bounded_compatibility_probe`
- **AND** it uses the existing reason-code vocabulary

### Requirement: Normalized Runtime And Device Eligibility
Production scheduling SHALL match model artifact requirements to fresh authenticated runtime-provider capabilities, acceleration capabilities, device resources, memory domains, and Controller policy.
Scheduling MUST NOT authorize work solely from operating-system names, `worker_backend` strings, transport type, or inferred provider defaults.
Missing, malformed, stale, conflicting, or version-incompatible required capability evidence SHALL fail closed with stable provider-neutral explanation reasons.
This requirement refines `SPEC.md` §§5.5, 5.7, 5.9, and 7.3.5.

#### Scenario: Artifact supports MLX and future CUDA providers
- **WHEN** an artifact declares compatibility with multiple runtime-provider requirement sets
- **THEN** the scheduler evaluates each candidate against its normalized provider and device evidence
- **AND** it does not rewrite artifact format as `mlx` or `cuda`

#### Scenario: Provider string exists without capabilities
- **WHEN** an observation contains a provider identifier but omits required format, feature, device, or memory capability evidence
- **THEN** the scheduler rejects that capability match
- **AND** it does not infer eligibility from the provider identifier

### Requirement: Memory Eligibility Uses Memory Domains
Scheduler memory eligibility and ranking SHALL use normalized resource identities and memory domains such as unified, device, and system memory with fresh capacity and headroom evidence.
Provider-specific working-set or VRAM fields MAY feed adapter normalization but MUST NOT be required by portable scheduling.

#### Scenario: Unified-memory and discrete-GPU candidates are compared
- **WHEN** compatible candidates report normalized unified-memory and device-memory resources
- **THEN** each candidate is evaluated against the model requirement applicable to its memory domain
- **AND** portable scheduling does not assume that all accelerators share Apple unified-memory semantics
