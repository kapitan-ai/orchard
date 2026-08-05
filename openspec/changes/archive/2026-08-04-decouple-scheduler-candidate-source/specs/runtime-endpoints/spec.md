## ADDED Requirements

### Requirement: Durable authenticated heartbeat observation
The Active Controller SHALL append one `node_heartbeats` row for each successful,
authenticated, non-stale trusted Runtime Endpoint Observation in the same transaction that
advances `nodes.last_heartbeat_at`, re-derives Node health, and refreshes aggregate
DispatchCapacity evidence.
A standby Controller MUST write nothing on this path.
A transport failure MUST NOT append a synthetic successful heartbeat.
Heartbeat history SHALL follow the seven-day `SPEC.md` §8.5 retention default.
This proposed requirement refines `SPEC.md` §4.6.1, §8, and §8.5 and ADR 0017; it remains
pending SPEC synchronization at implementation acceptance/archive.

#### Scenario: Accepted observation commits atomically
- **WHEN** the Active Controller accepts a newer authenticated trusted observation
- **THEN** the Node update, aggregate DispatchCapacity evidence, and heartbeat row commit in
  one transaction
- **AND** failure of any write rolls back all three effects

#### Scenario: Transport failure has no heartbeat row
- **WHEN** the observer cannot obtain an authenticated observation
- **THEN** Orchard applies the existing durable health-demotion path
- **AND** no row claims that a successful heartbeat occurred

### Requirement: Versioned bounded heartbeat candidate payload
`node_heartbeats.payload` SHALL use Controller-produced schema version `1` with a closed
allowlist.
The row columns SHALL own canonical trusted `node_id` and `observed_at`.
The JSON envelope SHALL contain `schema_version`, `validity`, and optional
`invalid_reason`.
Allowed observation keys SHALL be `endpoint_id`, `target`, `availability`,
`worker_state`, `aggregate_active_request_count`, `aggregate_max_concurrency`,
`aggregate_capacity_evidence`, `placements`, `runtime_memory_budgets`,
`runtime_prefix_cache_statuses`, and `supports_prompt_token_ids`.
Nested keys SHALL use the existing `Target`, `ModelRef`, `Placement`,
`PlacementCapacity`, `MemoryBudget`, and `PrefixCacheStatus` vocabulary described by
ADR 0017.
This proposed requirement refines `SPEC.md` §4.6.1 and §8 and remains pending SPEC
synchronization at implementation acceptance/archive.

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
