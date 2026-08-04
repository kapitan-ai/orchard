# Design: durable production snapshots with a bounded compatibility exception

## Decision source

ADR 0017 selects Postgres-backed request-scoped production candidates without a
cross-request production mirror. ADRs 0001, 0013, and 0015 remain authoritative for durable
observations, Controller-owned dispatch capacity, and background liveness.

## Production data flow

1. The Active Controller background observer obtains an authenticated Runtime Endpoint
   Observation for a trusted admitted or active target.
2. The authenticated seam validates identity, target, ordering, and observation shape.
3. One transaction advances Node heartbeat/health, refreshes aggregate DispatchCapacity
   evidence, and appends a versioned `node_heartbeats` row.
4. MultiNode resolves the effective targets and exact certificate-backed active inventory.
5. One Postgres snapshot read intersects those targets with the latest fresh,
   identity-matching heartbeat rows.
6. MultiNode filters, evaluates, ranks, and explains only that request-scoped result.
7. Dispatch acquires authority before connection/model load and revalidates current durable
   facts immediately before execution under the existing acceptance gate.

The query result is immutable for one scheduling attempt. Different Nodes may have different
observation times; the query supplies database snapshot consistency, not monitor-cycle
atomicity.

## Candidate universe

For production, membership requires all three identities to agree: the effective normalized
`Inference.runtime_endpoint_targets/0` target, the exact
`Nodes.active_runtime_endpoint_targets/0` trusted target, and the persisted heartbeat
target plus `node_id`. Address-only equality is insufficient for a production Node.

A removed/reconfigured target, inactive Node, unmatched heartbeat, or target outside the
effective set is excluded even when historical data remains fresh.

The static unmanaged branch is separate. It is available only when
`allow_static_runtime_target_fallback=true`, trusted admitted/active inventory is
confirmed empty, and `Inference.static_runtime_target?/1` matches the normalized target.
It may execute one compatibility probe wave over at most four deduplicated configured
targets, one connect/status attempt per target, existing 2000 ms timeout, no retry. It
cannot run on inventory uncertainty or production snapshot failure, publish production
Node-owned queue sources, or change an unmanaged target into trusted inventory.

## Payload schema and bounds

The Controller serializes `node_heartbeats.payload` schema version `1`. The row columns
own trusted `node_id` and `observed_at`. The JSON allowlist is:

- envelope: `schema_version`, `validity`, optional `invalid_reason`;
- endpoint: `endpoint_id`, `target`, `availability`, `worker_state`;
- aggregate capacity: `aggregate_active_request_count`,
  `aggregate_max_concurrency`, `aggregate_capacity_evidence`;
- placements: `placements`, using canonical `model_ref`, `state`, `capacity`,
  and `last_used_at`;
- ranking observations: `runtime_memory_budgets`,
  `runtime_prefix_cache_statuses`, and `supports_prompt_token_ids`.

`target` uses `Target` fields `id`, `transport`, `address`, and `node_id`.
Placement capacity uses `active_request_count`, `max_concurrency`, `status`, and
`source`. Aggregate capacity evidence uses `runtime_concurrency_limit`,
`active_request_count`, and `validity`.

Memory entries pass through `MemoryBudget.normalize/1`. Prefix-cache entries pass through
`PrefixCacheStatus.normalize/1`; raw `prefix_cache_fingerprints` never enter JSONB.
This retains status, counters, fingerprint count, and warmth indicator without violating
`SPEC.md` §7.5.3.

Structural bounds reuse `Orchard.Nodes` snapshot limits: 40 entries per map/list, depth 4,
and 512 bytes for strings without a narrower domain limit. Domain limits remain:
BEAM target names 255 bytes; model refs 160 characters; mode/implementation 40 characters;
status/source 80 characters; status messages 240 characters; and normalized uint32/uint64
ranges. The final JSON is capped by validated
`node_heartbeat_payload_max_bytes`, default 262144 bytes.

Optional malformed facts normalize to existing invalid/unknown values. An unsupported
schema, malformed required envelope, or still-oversize normalized payload produces a
minimal invalid envelope, commits with the same observation transaction, and is ineligible
with `dispatch_capacity_facts_unavailable`. Unknown fields are dropped.

Prohibited data includes secrets, credentials, DSNs, prompts, responses, raw tokens, tenant
IDs, raw prefix-cache fingerprint sets, raw metadata/diagnostics, local paths/evidence, tool
session identifiers, Controller policy/allocation/quarantine, authority results, and
acquirability.

Request-specific prefix-cache scoring remains under the existing §7.5.3 bound: selected
candidate only in observe-only mode; at most incumbent and challenger in tie-only mode.
Snapshot decoupling adds no status/score fan-out. Without persistable raw fingerprints, the
earlier live fingerprint-match hint is rank-neutral.

## Snapshot freshness, restart, and failure

Both `nodes.last_heartbeat_at` and the selected heartbeat `observed_at` must remain
within `node_freshness_threshold_ms` at query time. Aggregate capacity evidence separately
satisfies ADR 0013 currentness rules.

Controller or scheduler restart needs no production-cache hydration; the next schedule
reads Postgres. Missing, stale, malformed, or identity-mismatched rows remain explicit
rejected candidates when the target universe and coherent query result are available.

Inventory database unavailability preserves current `:no_active_nodes` behavior and emits
no SchedulerExplanation. Snapshot database failure after resolving targets uses the existing
`:cluster_busy`/bounded queue outcome, does not use stale memory or production probes, and
emits no explanation because no coherent evaluation exists.

## Queue-capacity source lifecycle

Queue-capacity sources do not come from request snapshots.

After the observation transaction commits, the existing Node ingestion consumer runs the
shared capacity evaluation. Positive results refresh source-scoped loaded/cold lane
contributions; ineligible or unavailable results clear them. Identity rejection, transport
failure, stale sweep, lifecycle/health/freshness loss, malformed facts, failed commit, or
consumer failure clears the affected sources.

QueueManager/Controller restart begins with no Node-owned source contributions. The next
accepted eligible background observation repopulates them. No heartbeat-history replay is
required. Static unmanaged probes do not publish production sources; configured base lane
capacity is unaffected.

## Authority and revalidation

The snapshot is evidence, not a permit. Controller policy, phase, allocation, quarantine,
trusted lifecycle/health, and the shared evaluation stay Controller-owned. Placement
Capacity may reduce eligibility but never increases aggregate authority. Ranking facts
cannot override a non-positive authority decision.

Dispatch acquires or recognizes the allocation/legacy claim before connection or load.
Immediately before `ExecuteInference`, it holds the per-Node acceptance gate and reruns
shared authority and Placement Capacity checks against the latest durable observation and
current Controller facts. The gate remains held through acceptance or pre-acceptance
failure. No production status probe is part of revalidation.

## SchedulerExplanation mapping

Use `cluster_management.scheduler_explanation.v1`. Each candidate adds bounded diagnostics
`candidate_source = "monitor_snapshot"` or
`"bounded_compatibility_probe"`.

- Selected/scored snapshot candidates retain ranking order, additive components, and empty
  reason codes.
- Eligible lower-tier snapshot candidates are skipped with
  `lower_tier_not_considered`.
- Missing or invalid payload facts are rejected with
  `dispatch_capacity_facts_unavailable`.
- Stale facts use `node_observation_stale`.
- Identity mismatch uses `runtime_identity_mismatch`.
- Existing runtime and shared capacity failures retain their current reason codes.

If all coherently read candidates are rejected, record the explanation and preserve the
existing `cluster_busy` or queue-waitable live-node-capacity outcome. Explanation build or
persistence failure remains observational. Inventory/snapshot database failure emits no
candidate explanation, because a trustworthy candidate list was never evaluated.

## Trade-offs

The design adds a Postgres query, bounded JSON history, and retention work. It avoids
production cache recovery and invalidation. The four-target unmanaged probe exception keeps
source-development compatibility without reopening production fan-out. Queue hints recover
only after a new observation following restart, deliberately preferring temporary
under-admission to stale wakeups.
