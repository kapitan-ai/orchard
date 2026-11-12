## MODIFIED Requirements

### Requirement: Snapshot candidate SchedulerExplanation
Snapshot and bounded compatibility candidates SHALL use
`cluster_management.scheduler_explanation.v1` selected/scored, rejected, and skipped
structures.
Candidate diagnostics SHALL identify `candidate_source` as `monitor_snapshot` or
`bounded_compatibility_probe`.
No new reason vocabulary is introduced.
This requirement refines `SPEC.md` §7.3.5 and ADR 0017.

These diagnostic/source requirements SHALL continue to govern internal/persisted explanations and full operator/admin output. The cluster-reader API representation SHALL instead use `contract_version: "orchard.cluster_reader.scheduler_explanation.v1"` with top-level `projection: "cluster_reader.v1"` and only the closed fields in [the reader projection](../../design.md#closed-reader-projections). It SHALL omit diagnostics, components, target references and supplemental prose without deleting them from internal explanations. Reader admission SHALL require active/proven leadership and current disclosure authority at transmission admission; unknown or invalid required data SHALL fail closed without inspected raw errors.

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

#### Scenario: Reader serialization excludes persisted diagnostic content
- **WHEN** a reader requests a known Request's valid explanation on Active and passes transmission admission
- **THEN** only the reader-versioned subset is delivered without diagnostic/source maps or supplemental text
- **AND** the stored explanation and existing full operator/admin representation remain unchanged
