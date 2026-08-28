# Node and placement circuit-breaker foundation (#296)

## Why

`SPEC.md` §5.10 already requires durable Node and `(node, model)` placement circuit breakers, but Orchard has no authoritative persistent state machine that records eligible failures, drives scheduler suppression, survives Controller changes, or supports Operator inspection and clearing.
The closed failure taxonomy prerequisite from #168 has landed, so this foundation can consume that vocabulary without widening it.
The separate automatic-attempt-retry change still needs this foundation before #170 can attribute failures from individual attempts.

## What changes

- Persist canonical Node and placement breaker identities, idempotent failure contributions, current generation, suppression state, and transition evidence in Postgres.
- Serialize recording and clearing so threshold crossings, duplicate delivery, expiry, and explicit clear remain deterministic across concurrent Controllers, restart, and Active/Standby changes.
- Apply the exact `SPEC.md` §5.10 failure classes, thresholds, rolling windows, and suppression durations using database-authoritative decision time.
- Make scheduler and dispatch-capacity decisions consume durable breaker facts and fail closed when required identity or state cannot be established.
- Suppress an open Node before ranking or dispatch, and suppress only cold or warm loading for an open placement breaker while preserving a separately valid already-loaded placement.
- Add authenticated Operator inspection and idempotent clear operations through Controller-owned authority with durable audit evidence.
- Keep Runtime Endpoint transport probes health-only and give actual failure outcomes one idempotent breaker-recording path.

## Out of scope

- Attempt attribution from #170.
- Hard prior-Node exclusion from #169.
- Attempt 2 orchestration from #171.
- Retry metrics from #172 or end-to-end retry proof from #173.
- New failure classes, reason codes, thresholds, windows, durations, or retry-specific breakers.
- Treating breaker state as Node health, Node lifecycle, or placement lifecycle.
- Metrics or alerting for breaker transitions.

## SPEC.md impact

This change implements the existing contract in `SPEC.md` §5.10 and integrates it with the scheduler eligibility contract in §5.5, the stable explanation vocabulary in §7.3.5, the Operator boundary in §7.3, audit requirements in §10, and Postgres-backed Active/Standby ownership in §3.3.
It does not change the apex policy.

## Relationship to automatic attempt retry

The `automatic-attempt-retry` package continues to own per-attempt attribution and retry sequencing.
Its task ledger records this separately implemented foundation as complete while leaving #169 through #173 work uncompleted.
No retry decision, declined retry, transport probe, or synthetic scheduler outcome contributes a breaker failure.
