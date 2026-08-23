# ADR: Host capability and runtime providers are separate authorities

## Status

Accepted on 2026-08-23 under issues #266 and #267.

## Context

The current MLX worker discovers Apple device and working-set facts while also reporting runtime readiness and execution capacity.
Durable Controller contracts use overlapping `mlx`, `worker_backend`, working-set, artifact-format, and scheduler vocabulary.

Hardware presence does not prove that a runtime can initialize or execute a particular model.
Runtime readiness does not prove complete host inventory, driver health, topology, or allocatable resources.
Keeping both authorities inside one provider also duplicates discovery when a host supports multiple providers or devices.

## Decision

Define a host capability provider and a runtime provider as separate authorities.

The host capability provider reports host-observed device inventory, stable device identity, topology, architecture, acceleration availability, memory domains, driver readiness, changing health, observation time, and bounded diagnostics.
The runtime provider reports protocol and provider identity, supported artifact formats and features, model compatibility, runtime initialization and health, device bindings, active allocation, concurrency, cache capabilities, and execution capacity.

Neither authority proves the other.
Dispatch eligibility requires compatible fresh authenticated evidence from both authorities plus current Controller trust, lifecycle, health, capacity, and policy gates.

Orchard SHALL distinguish artifact format, runtime provider, acceleration implementation, device resource, and memory domain.
Portable policy and scheduling MUST NOT branch on operating-system names or provider identifiers as substitutes for capability evidence.

Introduce normalized evidence additively.
Absent, malformed, stale, conflicting, unauthenticated, or version-incompatible required evidence cannot prove eligibility.
Before normalized evidence becomes authoritative, compare decisions diagnostically and preserve current scheduling behavior.
The authoritative cutover requires a separately reviewed behavior change and stable provider-neutral explanations.

Current MLX fields and model records remain valid migration inputs.
Provider-specific working-set or failure fields MAY feed normalization or bounded diagnostics until their documented compatibility window ends.

## Consequences

Orchard can represent multiple devices, memory domains, and runtime providers without encoding Apple or MLX assumptions in portable scheduling.
Device inventory can exist before a worker starts, while runtime initialization remains provider-owned.
Scheduler decisions become more explicit and explainable across heterogeneous Nodes.

The Node Agent must aggregate and authenticate two evidence sources and handle disagreement, freshness, and version skew.
Capability normalization touches Runtime Endpoints, persistence, diagnostics, model contracts, Console and CLI presentation, and scheduling, so implementation must remain additive until cutover.

## SPEC.md impact

Update required in §§1.5, 4.1, 4.6.1, 5.5, 5.7, 6.4, 7.5, 8.2, and 10.10.
