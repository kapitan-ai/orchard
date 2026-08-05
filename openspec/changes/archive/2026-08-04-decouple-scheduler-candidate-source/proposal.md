# Decouple production scheduler candidates from inline status probes

## Why

`Orchard.Scheduler.MultiNode` currently probes every effective Runtime Endpoint target on
each scheduling attempt. Slice A of issue #122 already moved trusted active-Node liveness to
a leader-owned background observer. Issue #149 must remove the remaining production
request-path coupling without weakening Postgres authority, ADR 0013 revalidation, explicit
static compatibility behavior, queue wakeups, or SchedulerExplanation coverage.

## What changes

- Persist accepted authenticated trusted observations as versioned, bounded
  `node_heartbeats` rows atomically with Node heartbeat/health and aggregate
  DispatchCapacity evidence.
- Define production candidates as the exact intersection of effective configured targets,
  certificate-backed active inventory, and fresh identity-matching durable observations.
- Build one immutable request-scoped production candidate snapshot from Postgres; do not add
  a cross-request production mirror.
- Remove production inline status probing and prohibit stale-memory or unbounded probe
  fallback when the durable source is unavailable.
- Preserve the explicitly unmanaged static fallback only when enabled and trusted inventory
  is confirmed empty, bounded to one no-retry wave over at most four configured targets
  with the existing 2000 ms per-target timeout.
- Keep Node-owned queue-capacity sources ingestion-driven: accepted observations refresh or
  clear them through the shared evaluator; scheduling reads do not rebuild them.
- Preserve Controller-owned acquisition and final pre-execution revalidation.
- Extend SchedulerExplanation coverage for snapshot and compatibility candidates using
  existing selected/rejected/skipped structures and reason codes.
- Implement seven-day heartbeat retention.

The payload uses a closed version-1 schema grounded in the current
`RuntimeEndpoint.Observation`, `Target`, `Placement`, `PlacementCapacity`,
`MemoryBudget`, and `PrefixCacheStatus` vocabulary. It never persists raw prefix-cache
fingerprint sets, issue #128 acquirability, or another derived authority/eligibility result.

## Out of scope

- Issue #128 scheduler failure reclassification.
- A cross-request leader-local production candidate mirror.
- New public inference errors or scheduler reason codes.
- Rebuilding queue-capacity sources from scheduling reads.
- UI or operator-surface work.
- The heartbeat-lag metric/exporter and other metrics-floor work.
- M7 durable permits, leadership fencing, reservation recovery, or durable quarantine
  release.

## SPEC.md impact

`SPEC.md` is updated now only for the shipped first-party Controller-pull direction and
5000 ms default observation interval. Candidate persistence, target intersection, bounded
compatibility probing, snapshot reads, queue-source recovery, payload schema,
SchedulerExplanation behavior, and production inline-probe removal remain proposed in this
active package. Synchronizing those accepted behaviors into `SPEC.md` is a pending
implementation/archive task. The §9.1 heartbeat-lag metric remains a separate normative
obligation.
