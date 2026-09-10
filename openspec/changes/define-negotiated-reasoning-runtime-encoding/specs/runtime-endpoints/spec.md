## ADDED Requirements

### Requirement: Negotiated reasoning uses a live prepared execution boundary

For an explicit negotiated reasoning Request, the Runtime Endpoint Interface SHALL obtain reasoning support only from an opt-in live observation projection and select only an already loaded placement with a fresh exact tuple match. This is a narrow reasoning-specific eligibility predicate and SHALL NOT make generic capability evidence authoritative for readiness, admission, placement capacity, legacy scheduling, retry, or ordinary projection.

The interface SHALL expose unary `PrepareInference` before execution. It SHALL return an exact-tuple proof and opaque single-use authorization bound to the Request and current loaded worker instance. The Controller SHALL validate the proof before accepting the attempt as running and redeem the authorization only through the matching execution request. Missing, stale, malformed, mismatched, expired, cancelled, or previously redeemed preparation evidence SHALL fail before invocation through the existing `runtime_incompatible` pre-acceptance behavior.

Legacy status, execution, and event projections SHALL omit reasoning additions for older or non-advertising bindings. Reasoning evidence is live-only: heartbeat and durable observation writes MUST NOT carry it or extend its freshness.

#### Scenario: A live probe cannot prove an unloaded placement

- **WHEN** a live reasoning observation has no valid loaded binding for the requested model
- **THEN** the Controller does not select that placement for negotiated execution
- **AND** it does not load the placement merely to discover support

#### Scenario: Preparation proof is lost

- **WHEN** the Controller does not receive a valid preparation proof and authorization
- **THEN** it records the closed pre-acceptance incompatibility outcome
- **AND** the Worker Runtime has not invoked the model or emitted content or usage

#### Scenario: An older binding handles a legacy request

- **WHEN** the Runtime Endpoint binding does not advertise the reasoning observation projection
- **THEN** Orchard sends no reasoning field or event to that binding
- **AND** legacy behavior remains available under its existing contract
