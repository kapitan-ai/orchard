# Scheduler candidates come from durable monitor-refreshed observations

## Status

Accepted and implemented; `decouple-scheduler-candidate-source` was archived as
`2026-08-04-decouple-scheduler-candidate-source` after its deltas were synchronized into
the main OpenSpec specs.

This decision resolves the slice B question left open by
[ADR 0015](0015-thin-active-node-liveness-monitor-before-scheduler-decoupling.md).

## Context

`Orchard.Scheduler.MultiNode` currently probes every effective Runtime Endpoint target on
each scheduling attempt. ADR 0015 moved trusted active-Node liveness to a leader-owned
background observer but intentionally deferred the candidate source, snapshot contract, and
inline-probe boundary to issue #149.

ADR 0001 keeps Postgres observations authoritative. ADR 0013 keeps dispatch capacity
Controller-owned and requires initial allocation or legacy-claim acquisition plus final
fail-closed revalidation. The replacement source must remove production request latency
without treating Node telemetry, cached ranking facts, or BEAM connectivity as authority.

The current code also has two distinct target classes. Production-managed candidates come
from certificate-backed active inventory. When trusted admitted/active inventory is empty,
an explicitly enabled static source-development or compatibility target may use the
existing unmanaged fallback. Issue #149 must not accidentally remove that bounded
compatibility path or let it become a production fallback.

Queue-capacity sources are also distinct from MultiNode request candidates. They are
process-local hints refreshed or cleared when status is ingested. They are not reconstructed
by each scheduling read and do not authorize dispatch.

## Decision

### Production candidate source and universe

Issue #149 SHALL use durable `node_heartbeats` observations in Postgres as the
monitor-refreshed source for production-managed MultiNode candidates. It SHALL NOT add a
cross-request leader-local production candidate mirror in this slice.

At the start of a scheduling attempt, the production candidate universe is the intersection
of:

1. the effective normalized target set returned by `Inference.runtime_endpoint_targets/0`;
2. the exact certificate-backed `:active` target inventory returned by
   `Nodes.active_runtime_endpoint_targets/0`; and
3. the latest accepted scheduler-fresh heartbeat row whose Node identity and normalized
   target identity exactly match that target.

A heartbeat row does not make an unconfigured, inactive, untrusted, address-only, or
identity-mismatched endpoint a candidate. A target removed or changed after observation is
excluded even while its row remains within retention.

A scheduling attempt reads this intersection in one Postgres statement, or one read
transaction with equivalent snapshot semantics, and holds only the immutable request-scoped
result. Per-Node observation times may differ; Orchard makes no same-instant monitor-cycle
claim. Both the Node heartbeat and selected observation must satisfy
`node_freshness_threshold_ms` at read time.

### Explicitly unmanaged compatibility exception

Preserve the current static fallback only when
`Inference.static_runtime_target_fallback_enabled?/0` is true, trusted admitted/active
inventory is confirmed empty, and the target exactly satisfies
`Inference.static_runtime_target?/1`. Such a target remains explicitly unmanaged under
ADR 0013 and does not become production inventory or acquire production authority.

Because the trusted background observer does not probe static unmanaged targets, MultiNode
MAY run one compatibility status-probe wave for that branch only. The wave is limited to
the first four deduplicated explicitly configured static targets, one connect/status
attempt per target, the existing 2000 ms per-target status timeout, and no retry. It SHOULD
run within one bounded wave rather than serially multiplying the timeout. It MUST NOT run
when trusted inventory exists, inventory availability cannot be proven, or a production
candidate snapshot fails. It MUST NOT become an unbounded production fallback.

### Observation commit and payload

Each successful authenticated, non-stale trusted observation SHALL append one
`node_heartbeats` row in the same database transaction that advances
`nodes.last_heartbeat_at`, re-derives health, and refreshes aggregate DispatchCapacity
evidence. A transport failure creates no synthetic successful heartbeat.

The Controller-produced JSON payload uses schema version `1` and a closed top-level
allowlist matching existing domain vocabulary:

- `schema_version`, `validity`, and optional `invalid_reason`;
- `endpoint_id`, `target`, `availability`, and `worker_state`;
- `aggregate_active_request_count`, `aggregate_max_concurrency`, and
  `aggregate_capacity_evidence`;
- `placements`;
- `runtime_memory_budgets`;
- `runtime_prefix_cache_statuses`; and
- `supports_prompt_token_ids`.

The row's `node_id` and `observed_at` columns remain the canonical trusted identity and
observation time. `target`, `placements`, and capacity entries use the canonical
`Target`, `ModelRef`, `Placement`, and `PlacementCapacity` field names.
Memory-budget entries use `Orchard.Runtime.MemoryBudget.normalize/1`.
Persisted prefix-cache entries use `Orchard.Runtime.PrefixCacheStatus.normalize/1`, never
`normalize_for_scheduler/1`, so raw fingerprint sets are not persisted.

Normalization reuses current bounds where available: maps and lists are capped at 40
entries, nesting depth at 4, and otherwise-unbounded strings at 512 bytes, matching the
existing bounded Node snapshot contract. More specific domain limits win, including the
255-byte BEAM target address, 160-character model references, 40-character mode or
implementation, 80-character status/source values, 240-character status messages,
uint32/uint64 numeric ranges, and the existing status-code vocabularies. The complete
encoded JSON payload is additionally capped by validated configuration
`node_heartbeat_payload_max_bytes`, default 262144 bytes.

Unknown optional facts normalize to their existing unknown, missing, invalid, or
rank-neutral representation. Unknown schema version, malformed required envelope, or a
payload still over the byte cap after structural normalization is stored as a minimal
versioned `validity = "invalid"` envelope with a stable `invalid_reason`; it cannot
produce a positive candidate and is explained with
`dispatch_capacity_facts_unavailable`. This preserves atomic liveness/capacity evidence
without persisting an unbounded payload.

The payload MUST NOT contain credentials, certificate or API secrets, DSNs, prompt or
response bodies, raw prompt or token data, tenant identifiers, raw prefix-cache fingerprint
sets, raw metadata/diagnostics maps, local paths, local evidence, or tool/session
identifiers. It also MUST NOT contain Controller policy, Controller-accounted Allocation,
quarantine, an authority decision, issue #128 acquirability, or another derived eligibility
boolean.

Because raw prefix-cache fingerprint sets are prohibited from persistence, durable snapshot
candidates expose only the sanitized prefix-cache status, fingerprint count, and warmth
indicator. Request-specific cache scoring remains bounded by `SPEC.md` §7.5.3: at most the
already-selected candidate in observe-only mode or incumbent plus challenger in tie-only
mode. Decoupling MUST NOT introduce status or score fan-out. A live fingerprint match that
cannot be derived without prohibited raw persistence is rank-neutral.

### Queue-capacity sources

Node-owned queue-capacity sources remain ingestion-time, process-local hints. After an
accepted authenticated observation commits, the existing Node observation consumer reruns
the shared ADR 0013 evaluation and either refreshes the matching source-scoped loaded/cold
contributions or clears them. The request-scoped MultiNode snapshot read does not publish,
rebuild, or clear queue sources.

Identity rejection, transport failure, heartbeat-age demotion, lifecycle/health/freshness
loss, malformed or unavailable capacity facts, failed observation commit, and shared
evaluation failure clear the affected sources. QueueManager or Controller restart starts
with no live Node-owned source contributions; the next accepted eligible background
observation repopulates them. This is deliberately fail-closed and needs no
`node_heartbeats` replay. Explicitly unmanaged compatibility probes cannot publish
production Node-owned queue sources; configured base lane capacity remains separate.

### Authority and dispatch revalidation

The candidate snapshot is selection evidence, never a permit.

- trusted identity, lifecycle, health, policy, enforcement phase,
  Controller-accounted Allocation, quarantine, and the shared evaluation remain
  Controller-owned;
- Runtime Concurrency Enforcement Limit is Node-owned evidence composed with the
  Controller Dispatch Ceiling;
- Placement Capacity may reduce placement eligibility but cannot increase aggregate
  authority;
- loadedness and active counts retain their tier/ranking roles; sanitized prefix-cache and
  memory evidence retain only their permitted ranking roles; and
- acquirability remains derived and is never persisted.

Before connection or model loading, dispatch resolves trusted inventory and acquires or
recognizes the ADR 0013 allocation or temporary legacy claim. After any load and immediately
before `ExecuteInference`, it acquires the per-Node acceptance gate and reruns shared
authority plus Placement Capacity checks from the latest durable observation and current
Controller facts. The gate remains held through Node acceptance or pre-acceptance failure.
This revalidation is not a production status probe.

### Scheduler explanations and failure outcomes

Snapshot candidates SHALL use the existing SchedulerExplanation v1 selected/scored,
rejected, and skipped structures. Candidate diagnostics identify
`candidate_source = "monitor_snapshot"`; the bounded unmanaged exception uses
`candidate_source = "bounded_compatibility_probe"`.

No new reason code is introduced:

- missing or structurally malformed snapshot facts use
  `dispatch_capacity_facts_unavailable`;
- stale Node or observation evidence uses `node_observation_stale`;
- target/Node identity conflict uses `runtime_identity_mismatch`;
- unavailable runtime status uses `runtime_not_ready` or
  `transport_unreachable` as already classified;
- lower-tier candidates use `lower_tier_not_considered`; and
- shared capacity exclusions retain their existing ordered capacity reason codes.

When at least one lifecycle-managed target is evaluated, selected, rejected, and skipped
snapshot candidates remain observable even when all candidates are rejected and the
existing `cluster_busy`/queue-waitable live-node-capacity outcome follows. If trusted
inventory itself is unavailable, preserve MultiNode's current internal
`:no_active_nodes` outcome and no explanation. If the snapshot database read fails after
the target universe is resolved, use the existing `:cluster_busy` or bounded queue
outcome, do not probe production targets or use stale memory, and emit no candidate
explanation because no coherent candidate evaluation can be proven. Explanation generation
remains observational and cannot change the inference result.

### Retention and restart

`node_heartbeats` history follows the seven-day `SPEC.md` §8.5 retention default.
Controller or scheduler restart requires no candidate-cache hydration: the next production
schedule reads Postgres. Database unavailability or incomplete snapshot reads fail closed
as described above. Leadership loss stops background writes; a new Active Controller uses
durable rows and begins new observation cycles.

The `orchard_node_heartbeat_lag_seconds{node}` exporter remains separate metrics-floor work
owned by open GitHub issue #123. Scheduler freshness uses timestamps and does not require
the exporter.

## Rejected alternatives

A leader-local production mirror alone is rejected because process memory would become the
only copy of ranking evidence and require a restart/leadership hydration protocol. Using
both Postgres and a production mirror is deferred until measurement proves the snapshot
query is a bottleneck.

An unbounded inline probe fallback is rejected because it preserves production
target-count-dependent latency and hides database or monitor failures. The explicitly
unmanaged four-target compatibility wave is retained only because the trusted background
observer does not own that source-development branch.

Rebuilding queue sources from each schedule is rejected because QueueManager already owns
process-local source contributions and observation ingestion already has the correct
refresh/clear signals.

Persisting raw prefix-cache fingerprint sets is rejected by `SPEC.md` §7.5.3.
Persisting acquirability is rejected because it becomes stale as catalog, policy,
placement, allocation, or runtime state changes.

## Consequences

Production candidate construction becomes a bounded Postgres read. Static unmanaged
compatibility remains available under a visibly separate bounded exception. Queue sources
continue to wake work from observation ingestion and recover fail-closed after restart.

The design adds Postgres read load, bounded JSON history, retention cleanup, invalid-payload
handling, and explanation coverage. Those costs are accepted at the current scale before
adding a production mirror.

## SPEC.md impact

`SPEC.md` now includes the accepted first-party Controller-pull direction, 5000 ms default
interval, candidate persistence, configured target intersection, bounded unmanaged probing,
snapshot reads, queue-source behavior, payload schema, explanations, and inline
production-probe removal. The archived OpenSpec deltas are synchronized into the main
specs. The §9.1 heartbeat-lag exporter remains deferred to open GitHub issue #123.
