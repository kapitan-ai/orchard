## 1. Architecture and current SPEC reconciliation

- [x] 1.1 Record ADR 0017 with production target intersection, bounded unmanaged fallback, queue-source, payload, explanation, and revalidation decisions
- [x] 1.2 Author this active OpenSpec package and scheduler/runtime-endpoint deltas
- [x] 1.3 Reconcile `SPEC.md` only to the shipped first-party Controller-pull direction and 5000 ms default interval
- [x] 1.4 Validate: `CI=1 OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate decouple-scheduler-candidate-source --type change --strict --no-interactive`
- [ ] 1.5 Synchronize accepted candidate-source, payload, queue-source, explanation, and inline-probe behavior into `SPEC.md` during implementation acceptance/archive

## 2. Durable trusted observations

- [x] 2.1 Add the `node_heartbeats` persistence module and migration required by `SPEC.md` §8
- [x] 2.2 Implement schema-version-1 allowlist normalization, structural/domain bounds, configurable 262144-byte default cap, and minimal invalid envelopes
- [x] 2.3 Append heartbeat history inside the authenticated Node/DispatchCapacity transaction; reject stale/identity-mismatched writes
- [x] 2.4 Exclude prohibited sensitive fields, raw prefix-cache fingerprints, Controller authority, and acquirability
- [x] 2.5 Enforce the §8.5 seven-day retention bound

## 3. Production candidate snapshots

- [x] 3.1 Resolve the exact intersection of effective targets, certificate-backed active inventory, and identity-matching fresh heartbeat rows
- [x] 3.2 Read the latest accepted row per trusted target with deterministic one-snapshot semantics
- [x] 3.3 Normalize loadedness, active counts, capacity, sanitized prefix-cache status, memory budgets, and prompt-token-ID support
- [x] 3.4 Apply Node/observation freshness and fail closed on missing, malformed, stale, identity-mismatched, or database-unavailable facts
- [x] 3.5 Refactor MultiNode production candidates to use the snapshot and remove production inline status probing

## 4. Explicit unmanaged compatibility

- [x] 4.1 Preserve static fallback only when enabled, trusted admitted/active inventory is confirmed empty, and `Inference.static_runtime_target?/1` matches
- [x] 4.2 Bound compatibility probing to one no-retry wave over at most four deduplicated configured targets with the existing 2000 ms per-target timeout
- [x] 4.3 Prove compatibility probing cannot run for production inventory, inventory uncertainty, or production snapshot failure
- [x] 4.4 Preserve explicit unmanaged ADR 0013 capacity classification and prevent compatibility probes from publishing production queue sources

## 5. Queue-capacity sources

- [x] 5.1 Keep source refresh/clearing in the accepted-observation ingestion consumer, separate from MultiNode snapshot reads
- [x] 5.2 Clear sources on identity rejection, transport failure, stale sweep, lifecycle/health/freshness loss, malformed facts, failed commit, or evaluator/consumer failure
- [x] 5.3 Start with no Node-owned sources after QueueManager/Controller restart and repopulate only from a new accepted eligible observation

## 6. Authority and explanations

- [x] 6.1 Preserve ADR 0013 acquisition/claim behavior and final acceptance-gated revalidation without a production status probe
- [x] 6.2 Emit SchedulerExplanation v1 selected/rejected/skipped candidates with bounded candidate-source diagnostics
- [x] 6.3 Map missing/malformed to `dispatch_capacity_facts_unavailable`, stale to `node_observation_stale`, identity mismatch to `runtime_identity_mismatch`, and preserve existing capacity/skip codes
- [x] 6.4 Preserve `:no_active_nodes` with no explanation for inventory unavailability and `:cluster_busy`/bounded queue behavior with no explanation for incoherent snapshot database failure
- [x] 6.5 Keep prefix-cache request RPCs within existing selected-only/two-candidate bounds and treat unavailable live fingerprint match as rank-neutral

## 7. Tests and quality gate

- [x] 7.1 Test transaction atomicity, schema/bounds, invalid envelopes, sensitive-field exclusion, and retention
- [x] 7.2 Test production target intersection, freshness, restart, target removal/reconfiguration, and database failures
- [x] 7.3 Test bounded unmanaged compatibility and absence of production fallback or queue-source publication
- [x] 7.4 Test ingestion-time queue refresh/clearing and fail-closed restart recovery independently of scheduling reads
- [x] 7.5 Test selected, rejected, and skipped snapshot/compatibility explanations, including missing, stale, identity-mismatched, malformed, and database-unavailable cases
- [x] 7.6 Test final revalidation against newer, stale, unhealthy, capacity-exhausted, and unavailable facts
- [x] 7.7 Run the applicable AGENTS.md Elixir formatting, compile, Credo, Dialyzer, test, and coverage workflow

## 8. Archive and sync

- [ ] 8.1 Archive/sync accepted deltas and review generated main specs for placeholder prose such as `Purpose TBD`
- [ ] 8.2 Confirm the separate §9.1 heartbeat-lag metric/exporter remains tracked by its owning metrics-floor work
