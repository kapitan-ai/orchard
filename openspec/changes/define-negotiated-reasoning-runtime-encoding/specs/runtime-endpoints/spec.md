## ADDED Requirements

### Requirement: Negotiated reasoning uses a live prepared execution boundary

For an explicit negotiated reasoning Request, the Runtime Endpoint Interface SHALL obtain reasoning support only from an opt-in live observation projection and select only an already loaded placement with a fresh exact tuple match. This is a narrow reasoning-specific eligibility predicate and SHALL NOT make generic capability evidence authoritative for readiness, admission, placement capacity, legacy scheduling, retry, or ordinary projection. The explicit negotiated Request is the sole opt-in; no separate operator configuration flag SHALL enable, disable, or widen that projection.

The predicate SHALL consider only `SPEC.md` §5.6 Tier 0 candidates, whether resident from earlier traffic or prewarmed by a §6.10 `preload = true` pinning policy. Tier 1 and Tier 2 candidates SHALL be ineligible, `residency_preference` and `max_cold_start_ms` SHALL NOT apply to negotiated candidate selection, and a negotiated Request SHALL resolve `timeout_at` through the §12.4 loaded-only formula under every resolved policy.

The predicate SHALL NOT reclassify capacity scarcity or unknown support as incompatibility, and capacity eligibility SHALL NOT narrow what it may observe. The closed §7.2.7 `503 server_error` plus `runtime_incompatible` pre-dispatch mapping SHALL apply only when the requested model has no loaded placement on an active trusted Node, or when every loaded placement of that model was probed and each affirmatively returned an absent or mismatched tuple. When a proving placement exists but cannot be dispatched for capacity, breaker, or tenant-cap reasons, or whenever any loaded placement's support remains unknown through an incomplete probe, an elapsed wave deadline, or a Node withheld as stale, unhealthy, or breaker-suppressed, the Request SHALL keep its existing `cluster_busy` or `model_busy` queue-waitable outcome as transient pre-dispatch unavailability, SHALL NOT record `not_retryable`, and SHALL NOT read that placement as proof of no support. That equivalence covers queue outcome semantics only; queue wait and wave time consume the negotiated Request's own §12.4 loaded-only budget.

The live observation SHALL run as one bounded wave over the reachable loaded-placement universe: every loaded placement of the requested model on a scheduler-fresh healthy active trusted Node, including those ordinary eligibility excludes solely for exhausted capacity or tenant active caps, deduplicated on the §5.5 normalized target identity and ordered by the §5.7 ranking as it would apply to them with the lexicographic `node_id` tie-break last. A stale, unhealthy, or circuit-breaker-suppressed Node SHALL be withheld rather than probed, so it cannot hold an in-flight slot it will never answer and §5.10 suppression is preserved; its support SHALL remain unknown.

The wave SHALL hold at most four probes in flight, advance through that deterministic order as probes complete, observe each placement at most once, and run under one 2000 ms wave deadline rather than a per-target timeout. It SHALL NOT retry an individual probe transport. Because the §5.7 ranking is capability-blind, the window SHALL advance rather than stay fixed on the leading four.

Selection evidence and exhaustion evidence SHALL be distinct. A timeout, transport failure, task exit, or otherwise incomplete probe SHALL prove no support for selection while leaving that placement unobserved and its support unknown; only a completed observation returning an absent or mismatched tuple SHALL count a placement as observed and non-proving.

The wave SHALL resolve to the highest-ranked proving placement, never to whichever probe answered first, and a lower-ranked proof SHALL NOT end the wave until every higher-ranked in-flight probe has resolved non-proving. It SHALL otherwise stop on exhaustion of that universe or on the wave deadline, and exhaustion SHALL prove absent support only when no placement's support was left unknown.

The wave budget SHALL be per logical Request rather than per scheduling pass: one initial fresh wave plus at most one further fresh wave, and that second one only for a real Automatic Attempt Retry after attempt 1 has started. A pre-start busy queue re-grant SHALL run no new wave and SHALL carry the earlier wave's selected placement only as a non-authoritative scheduling hint, explicitly carved out from the fresh-observation selection rule. That hint SHALL claim no reasoning support and SHALL confer no invocation authority; `PrepareInference` SHALL remain authoritative and revalidate the exact tuple before invocation. A re-granted pass that still cannot dispatch, or whose hint an unload or load replacement invalidated, SHALL requeue or terminalize under the existing queue-wait budget and `queue_timeout` outcome rather than re-probe.

Automatic Attempt Retry SHALL run its wave fresh rather than reuse attempt 1's evidence, whose freshness budget forwarding SHALL NOT refresh. Attempt 2 SHALL apply `exclude_node_ids` first, rebuild and reorder its universe by the same deterministic rule, advance through it under the same four-in-flight bound and 2000 ms wave deadline with no transport retry, and obtain a new `PrepareInference` proof for the different endpoint it selects. A wave proving no different eligible candidate SHALL resolve `no_alternative_node` unless an earlier §5.8 decline reason applies.

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

#### Scenario: A capable placement is saturated while an incapable one is idle

- **WHEN** the only tuple-proving loaded placement is over its concurrency limit and a different loaded placement that proves nothing is idle
- **THEN** the wave still observes the saturated placement, because its universe is not narrowed by capacity eligibility
- **AND** Orchard returns the ordinary queue-waitable `cluster_busy` or `model_busy` outcome rather than the incompatibility mapping
- **AND** it records no `not_retryable` decision

#### Scenario: Capable placements rank below incapable ones

- **WHEN** a negotiated reasoning Request has ten deduplicated loaded placements and only those ranked fifth and lower prove the exact tuple
- **THEN** the wave advances past the four incapable leaders as their probes complete and resolves to a proving placement
- **AND** it holds at most four probes in flight throughout and observes each placement at most once

#### Scenario: A lower-ranked probe answers first

- **WHEN** a lower-ranked placement proves the tuple while a higher-ranked probe is still in flight
- **THEN** the wave does not end on that proof and waits for the higher-ranked probe to resolve
- **AND** it selects the higher-ranked placement when that probe also proves the tuple

#### Scenario: The wave deadline elapses before the universe is exhausted

- **WHEN** the 2000 ms wave deadline elapses with loaded placements still unobserved
- **THEN** Orchard returns the transient queue-waitable outcome rather than the incompatibility mapping
- **AND** it records no `not_retryable` decision, because unobserved placements are not proof that support is absent

#### Scenario: The loaded universe is exhausted without support

- **WHEN** the wave probes every loaded placement of the requested model and each affirmatively returns an absent or mismatched tuple
- **THEN** Orchard fails the Request before dispatch with the closed pre-dispatch incompatibility mapping
- **AND** two identical scheduling attempts advance through the same deterministic order

#### Scenario: The one capable placement is briefly unreachable

- **WHEN** the only tuple-proving loaded placement answers its probe with a transport failure and every other probed placement affirmatively returns a mismatched tuple
- **THEN** Orchard returns the transient queue-waitable outcome rather than the incompatibility mapping
- **AND** it records no `not_retryable` decision, because an incomplete probe leaves support unknown rather than disproven

#### Scenario: A breaker-suppressed node holds a loaded placement

- **WHEN** a loaded placement of the requested model sits on a stale, unhealthy, or circuit-breaker-suppressed Node
- **THEN** the wave withholds that Node rather than probing it, and §5.10 suppression is preserved
- **AND** exhaustion of the remaining universe cannot conclude permanent incompatibility, because that Node's support stays unknown

#### Scenario: A busy re-grant returns to the scheduler

- **WHEN** a negotiated reasoning Request is re-granted from the queue after a pre-start busy outcome
- **THEN** it runs no new reasoning wave and treats the earlier selection as a scheduling hint only
- **AND** `PrepareInference` revalidates the exact tuple before invocation
- **AND** a hint it can still not dispatch terminalizes under the existing queue-wait budget rather than re-probing

#### Scenario: Automatic retry needs reasoning evidence again

- **WHEN** attempt 1 fails a retryable pre-commit failure and attempt 1's reasoning evidence has expired
- **THEN** attempt 2 runs the one further fresh bounded wave over its re-ranked universe with attempt 1's Node excluded
- **AND** it obtains a new `PrepareInference` proof for the different endpoint it selects

#### Scenario: Preparation proof is lost

- **WHEN** the Controller does not receive a valid preparation proof and authorization
- **THEN** it records the closed pre-acceptance incompatibility outcome
- **AND** the Worker Runtime has not invoked the model or emitted content or usage

#### Scenario: An older binding handles a legacy request

- **WHEN** the Runtime Endpoint binding does not advertise the reasoning observation projection
- **THEN** Orchard sends no reasoning field or event to that binding
- **AND** legacy behavior remains available under its existing contract
