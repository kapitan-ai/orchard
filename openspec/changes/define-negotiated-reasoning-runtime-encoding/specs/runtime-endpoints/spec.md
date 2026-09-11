## ADDED Requirements

### Requirement: Negotiated reasoning uses a live prepared execution boundary

For an explicit negotiated reasoning Request, the Runtime Endpoint Interface SHALL obtain reasoning support only from an opt-in live observation projection and select only an already loaded placement with a fresh exact tuple match. This is a narrow reasoning-specific eligibility predicate and SHALL NOT make generic capability evidence authoritative for readiness, admission, placement capacity, legacy scheduling, retry, or ordinary projection. The explicit negotiated Request is the sole opt-in; no separate operator configuration flag SHALL enable, disable, or widen that projection.

The predicate SHALL consider only `SPEC.md` §5.6 Tier 0 candidates, whether resident from earlier traffic or prewarmed by a §6.10 `preload = true` pinning policy. Tier 1 and Tier 2 candidates SHALL be ineligible, `residency_preference` and `max_cold_start_ms` SHALL NOT apply to negotiated candidate selection, and a negotiated Request SHALL resolve `timeout_at` through the §12.4 loaded-only formula under every resolved policy.

The predicate SHALL run after ordinary eligibility and ranking and SHALL NOT reclassify capacity scarcity as incompatibility. The closed §7.2.7 `503 server_error` plus `runtime_incompatible` pre-dispatch mapping SHALL apply only when the requested model has no loaded placement on an active trusted Node, or when the bounded wave exhausts the ranked Tier 0 list without a candidate proving the exact tuple. When a loaded placement exists but capacity scarcity leaves no Tier 0 candidate, or when the wave deadline elapses with ranked candidates still unobserved, the Request SHALL keep its existing `cluster_busy` or `model_busy` queue-waitable outcome, SHALL NOT record `not_retryable`, and SHALL NOT read the unobserved placement as proof of no support. That equivalence covers queue outcome semantics only; queue wait and wave time consume the negotiated Request's own §12.4 loaded-only budget.

The live observation SHALL run as one bounded wave per Inference Attempt. Its universe SHALL be built without the reasoning predicate — ordinary §5.5 eligibility, §5.6 Tier 0 grouping, then the §5.7 ranking in force with its lexicographic `node_id` tie-break last — and deduplicated on the §5.5 normalized target identity. The wave SHALL hold at most four probes in flight, advance through that deterministic order as probes complete, observe each candidate at most once, and run under one 2000 ms wave deadline rather than a per-target timeout. It SHALL stop at the first candidate proving the exact tuple, on exhaustion of the ranked list, or when that deadline elapses, and SHALL NOT retry an individual probe transport. Because the §5.7 ranking is capability-blind, the window SHALL advance rather than stay fixed on the leading four.

Automatic Attempt Retry SHALL run a fresh wave rather than reuse attempt 1's evidence, whose freshness budget forwarding SHALL NOT refresh. Attempt 2 SHALL apply `exclude_node_ids` first, rebuild and reorder its universe by the same deterministic rule, advance through it under the same four-in-flight bound and 2000 ms wave deadline with no transport retry, and obtain a new `PrepareInference` proof for the different endpoint it selects. Each attempt SHALL run at most one wave, so a logical Request SHALL run at most two, and a wave proving no different eligible candidate SHALL resolve `no_alternative_node` unless an earlier §5.8 decline reason applies.

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

#### Scenario: Capable candidates rank below incapable ones

- **WHEN** a negotiated reasoning Request has ten deduplicated Tier 0 candidates and only those ranked fifth and lower prove the exact tuple
- **THEN** the wave advances past the four incapable leaders as their probes complete and selects a proving candidate
- **AND** it holds at most four probes in flight throughout and observes each candidate at most once

#### Scenario: The wave deadline elapses before the list is exhausted

- **WHEN** the 2000 ms wave deadline elapses with ranked Tier 0 candidates still unobserved
- **THEN** Orchard returns the transient queue-waitable outcome rather than the incompatibility mapping
- **AND** it records no `not_retryable` decision, because unobserved candidates are not proof that support is absent

#### Scenario: The ranked list is exhausted without support

- **WHEN** the wave observes every ranked Tier 0 candidate and none proves the exact tuple
- **THEN** Orchard fails the Request before dispatch with the closed pre-dispatch incompatibility mapping
- **AND** two identical scheduling attempts advance through the same deterministic order

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
