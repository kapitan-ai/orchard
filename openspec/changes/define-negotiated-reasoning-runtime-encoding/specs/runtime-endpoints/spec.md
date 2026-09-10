## ADDED Requirements

### Requirement: Negotiated reasoning uses a live prepared execution boundary

For an explicit negotiated reasoning Request, the Runtime Endpoint Interface SHALL obtain reasoning support only from an opt-in live observation projection and select only an already loaded placement with a fresh exact tuple match. This is a narrow reasoning-specific eligibility predicate and SHALL NOT make generic capability evidence authoritative for readiness, admission, placement capacity, legacy scheduling, retry, or ordinary projection. The explicit negotiated Request is the sole opt-in; no separate operator configuration flag SHALL enable, disable, or widen that projection.

The predicate SHALL consider only `SPEC.md` §5.6 Tier 0 candidates, whether resident from earlier traffic or prewarmed by a §6.10 `preload = true` pinning policy. Tier 1 and Tier 2 candidates SHALL be ineligible, `residency_preference` and `max_cold_start_ms` SHALL NOT apply to negotiated candidate selection, and a resolved cold-start budget SHALL NOT admit a cold or cached candidate. When no Tier 0 candidate proves the exact tuple, Orchard SHALL fail closed before dispatch through the existing §7.2.7 `503 server_error` plus `runtime_incompatible` mapping.

The live observation SHALL run as one bounded wave over at most the first four deduplicated Tier 0 candidates under the §5.5 normalized target identity, with one observation attempt per candidate for the entire logical Request through terminal completion, a 2000 ms per-target timeout, and no retry. Automatic Attempt Retry SHALL NOT reallocate that budget or initiate a second wave; attempt 2 SHALL select only from Tier 0 candidates the original wave already proved and SHALL otherwise resolve `no_alternative_node` unless an earlier §5.8 decline reason applies.

The interface SHALL expose unary `PrepareInference` before execution. It SHALL return an exact-tuple proof and opaque single-use authorization bound to the Request and current loaded worker instance. The Controller SHALL validate the proof before accepting the attempt as running and redeem the authorization only through the matching execution request. Missing, stale, malformed, mismatched, expired, cancelled, or previously redeemed preparation evidence SHALL fail before invocation through the existing `runtime_incompatible` pre-acceptance behavior.

Legacy status, execution, and event projections SHALL omit reasoning additions for older or non-advertising bindings. Reasoning evidence is live-only: heartbeat and durable observation writes MUST NOT carry it or extend its freshness.

#### Scenario: A live probe cannot prove an unloaded placement

- **WHEN** a live reasoning observation has no valid loaded binding for the requested model
- **THEN** the Controller does not select that placement for negotiated execution
- **AND** it does not load the placement merely to discover support

#### Scenario: No loaded capacity exists under an allow-cold-load policy

- **WHEN** a negotiated reasoning Request resolves an `allow_cold_load` routing policy and the cluster has no Tier 0 candidate proving the exact tuple
- **THEN** Orchard fails the Request before dispatch with the closed pre-dispatch incompatibility mapping
- **AND** it neither loads, caches, nor downloads an artifact to create a negotiated candidate

#### Scenario: The candidate universe exceeds the probe budget

- **WHEN** more than four deduplicated Tier 0 candidates could serve a negotiated reasoning Request
- **THEN** the Controller observes at most the first four deduplicated candidates once each, with a 2000 ms per-target timeout and no retry
- **AND** an automatic retry starts no second wave and chooses only among candidates that wave already proved

#### Scenario: Preparation proof is lost

- **WHEN** the Controller does not receive a valid preparation proof and authorization
- **THEN** it records the closed pre-acceptance incompatibility outcome
- **AND** the Worker Runtime has not invoked the model or emitted content or usage

#### Scenario: An older binding handles a legacy request

- **WHEN** the Runtime Endpoint binding does not advertise the reasoning observation projection
- **THEN** Orchard sends no reasoning field or event to that binding
- **AND** legacy behavior remains available under its existing contract
