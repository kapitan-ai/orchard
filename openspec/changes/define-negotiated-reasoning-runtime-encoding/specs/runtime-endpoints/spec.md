## ADDED Requirements

### Requirement: Negotiated reasoning uses a live prepared execution boundary

For an explicit negotiated reasoning Request, the Runtime Endpoint Interface SHALL obtain reasoning support only from an opt-in live observation projection and select only an already loaded placement with a fresh exact tuple match. This is a narrow reasoning-specific eligibility predicate and SHALL NOT make generic capability evidence authoritative for readiness, admission, placement capacity, legacy scheduling, retry, or ordinary projection. The explicit negotiated Request is the sole opt-in; no separate operator configuration flag SHALL enable, disable, or widen that projection.

The predicate SHALL consider only `SPEC.md` §5.6 Tier 0 candidates, whether resident from earlier traffic or prewarmed by a §6.10 `preload = true` pinning policy. Tier 1 and Tier 2 candidates SHALL be ineligible, `residency_preference` and `max_cold_start_ms` SHALL NOT apply to negotiated candidate selection, and a negotiated Request SHALL resolve `timeout_at` through the §12.4 loaded-only formula under every resolved policy.

The predicate SHALL run after ordinary eligibility and ranking and SHALL NOT reclassify capacity scarcity as incompatibility. The closed §7.2.7 `503 server_error` plus `runtime_incompatible` pre-dispatch mapping SHALL apply only when the requested model has no loaded placement on an active trusted Node, or when every Tier 0 candidate the bounded wave observed fails the exact-tuple predicate. When a loaded placement exists but capacity scarcity leaves no Tier 0 candidate, the Request SHALL keep its existing `cluster_busy` or `model_busy` queue-waitable outcome, and that unobserved placement SHALL NOT be read as proof of no support.

The live observation SHALL run as one bounded wave per Inference Attempt. Its universe SHALL be built without the reasoning predicate — ordinary §5.5 eligibility, §5.6 Tier 0 grouping, then the §5.7 ranking in force with its lexicographic `node_id` tie-break last — and deduplicated on the §5.5 normalized target identity. The wave SHALL observe at most the first four candidates of that deterministic order, once each, with a 2000 ms per-target timeout and no transport retry. Candidates beyond the bound SHALL remain unobserved and SHALL prove no support without extending the wave.

Automatic Attempt Retry SHALL run a fresh wave rather than reuse attempt 1's evidence, whose freshness budget forwarding SHALL NOT refresh. Attempt 2 SHALL apply `exclude_node_ids` first, rebuild and reorder its universe by the same deterministic rule, observe at most the first four deduplicated candidates under the same per-target timeout with no transport retry, and obtain a new `PrepareInference` proof for the different endpoint it selects. Each attempt SHALL run at most one wave, so a logical Request SHALL run at most two, and a wave proving no different eligible candidate SHALL resolve `no_alternative_node` unless an earlier §5.8 decline reason applies.

The interface SHALL expose unary `PrepareInference` before execution. It SHALL return an exact-tuple proof and opaque single-use authorization bound to the Request and current loaded worker instance. The Controller SHALL validate the proof before accepting the attempt as running and redeem the authorization only through the matching execution request. Missing, stale, malformed, mismatched, expired, cancelled, or previously redeemed preparation evidence SHALL fail before invocation through the existing `runtime_incompatible` pre-acceptance behavior.

Legacy status, execution, and event projections SHALL omit reasoning additions for older or non-advertising bindings. Reasoning evidence is live-only: heartbeat and durable observation writes MUST NOT carry it or extend its freshness.

#### Scenario: A live probe cannot prove an unloaded placement

- **WHEN** a live reasoning observation has no valid loaded binding for the requested model
- **THEN** the Controller does not select that placement for negotiated execution
- **AND** it does not load the placement merely to discover support

#### Scenario: No loaded placement exists under an allow-cold-load policy

- **WHEN** a negotiated reasoning Request resolves an `allow_cold_load` routing policy and the requested model has no loaded placement on any active trusted Node
- **THEN** Orchard fails the Request before dispatch with the closed pre-dispatch incompatibility mapping
- **AND** it neither loads, caches, nor downloads an artifact to create a negotiated candidate
- **AND** its deadline used the loaded-only formula, adding neither the queue-wait nor the cold-start term

#### Scenario: The only tuple-proving placement is at capacity

- **WHEN** a loaded placement that would prove the exact tuple has no available capacity, leaving no Tier 0 candidate
- **THEN** Orchard returns the ordinary queue-waitable `cluster_busy` or `model_busy` outcome rather than the incompatibility mapping
- **AND** it records no `not_retryable` decision and does not treat the unobserved placement as proof of no reasoning support

#### Scenario: The candidate universe exceeds the probe budget

- **WHEN** more than four deduplicated Tier 0 candidates could serve a negotiated reasoning Request
- **THEN** the Controller observes the first four of the ranking order, once each, with a 2000 ms per-target timeout and no transport retry
- **AND** two identical scheduling attempts observe the same four candidates
- **AND** candidates beyond the bound stay unobserved and prove no support

#### Scenario: Automatic retry needs reasoning evidence again

- **WHEN** attempt 1 fails a retryable pre-commit failure and attempt 1's reasoning evidence has expired
- **THEN** attempt 2 runs one fresh bounded wave over its re-ranked universe with attempt 1's Node excluded
- **AND** it obtains a new `PrepareInference` proof for the different endpoint it selects

#### Scenario: Preparation proof is lost

- **WHEN** the Controller does not receive a valid preparation proof and authorization
- **THEN** it records the closed pre-acceptance incompatibility outcome
- **AND** the Worker Runtime has not invoked the model or emitted content or usage

#### Scenario: An older binding handles a legacy request

- **WHEN** the Runtime Endpoint binding does not advertise the reasoning observation projection
- **THEN** Orchard sends no reasoning field or event to that binding
- **AND** legacy behavior remains available under its existing contract
