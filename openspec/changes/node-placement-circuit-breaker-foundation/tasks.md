## 1. Contract and persistence

- [x] 1.1 Create a separate OpenSpec package subordinate to `SPEC.md` §5.10
- [x] 1.2 Fix canonical identity, database decision time, half-open windows, expiry, clear fencing, and transport ownership in the design
- [x] 1.3 Add the expand migration, schemas, constraints, restrictive Node foreign key, validated non-FK model UUID, and globally idempotent failure identity
- [x] 1.4 Prove migration rollback and do not synthesize contributions from historical health or request data

## 2. Durable breaker recording

- [x] 2.1 Add one public idempotent recording seam for typed actual failures
- [x] 2.2 Enforce the closed §5.10 failure-class mapping and one-breaker maximum
- [x] 2.3 Serialize concurrent recording and persist transition evidence atomically
- [x] 2.4 Implement exact Node and placement rolling windows, thresholds, and suppression durations
- [x] 2.5 Fence late pre-clear delivery by generation and watermark
- [x] 2.6 Cover duplicate delivery, boundary times, concurrent threshold crossings, and target isolation

## 3. Scheduler and dispatch capacity

- [x] 3.1 Read database-authoritative breaker facts in candidate construction and final revalidation
- [x] 3.2 Remove open Nodes before tiering, ranking, scoring, or dispatch with `node_circuit_breaker_open`
- [x] 3.3 Suppress only cold or warm placement loading with `model_load_suppressed`
- [x] 3.4 Preserve valid already-loaded dispatch and broader `placement_suppressed` lifecycle semantics
- [x] 3.5 Fail closed on unavailable read or identity authority without falsely reporting an open breaker
- [x] 3.6 Cover scheduler explanation, expiry, restart, and Active/Standby behavior

## 4. Operator authority and audit

- [x] 4.1 Add bounded Node and placement breaker inspection through authenticated Operator API routes
- [x] 4.2 Add idempotent clear operations with required reason and Controller-owned authorization
- [x] 4.3 Persist clear and transition audit evidence atomically
- [x] 4.4 Prove unauthorized credentials fail closed and clear does not mutate health or lifecycle

## 5. Transport-health ownership

- [x] 5.1 Keep transport probes and `Nodes.record_transport_failure/3` health-only
- [x] 5.2 Route each actual eligible failure through the sole idempotent breaker recorder
- [x] 5.3 Cover one transport failure updating health and contributing at most once without contradictory eligibility

## 6. Validation and handoff

- [x] 6.1 Run focused persistence, concurrency, window, scheduler, transport, and Operator API tests
- [x] 6.2 Run the complete applicable Elixir workflow and coverage from `AGENTS.md`
- [x] 6.3 Validate this change strictly and validate all OpenSpec specs strictly
- [x] 6.4 Reconcile independent design and Oracle review findings against `SPEC.md` and the final code
- [ ] 6.5 Record exact local and hosted validation evidence in the pull request without merging it
