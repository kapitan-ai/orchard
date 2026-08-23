# ADR: Worker Runtime contracts have provider-neutral ownership

## Status

Accepted on 2026-08-23 under issues #266 and #267.

## Context

The Node Agent already supervises Worker Runtime subprocesses through a local gRPC and Unix-domain-socket boundary.
That boundary is the correct seam for multiple runtime providers.

The MLX package currently owns the protobuf source, the Elixir binding is hand-maintained, and MLX vocabulary has leaked into durable model, failure, capability, memory, and UI contracts.
Allowing each provider to own or fork the protocol would make version negotiation, generated bindings, conformance, and Node Agent mapping drift across implementations.

## Decision

Keep the Node Agent-to-worker subprocess boundary.
The Node Agent continues to own subprocess supervision, model loading, execution, streaming, cancellation, active allocation, diagnostics, failure handling, and cleanup.
The Controller communicates through the Runtime Endpoint and MUST NOT manage provider subprocesses directly.

Move Worker Runtime protocol source, version policy, generated bindings, and conformance fixtures to a provider-neutral repository boundary.
The MLX worker becomes one implementation of that contract and no longer owns it.
Independent ownership does not require a new publishable package or OTP application.

Generate every supported language binding from one normative source.
Required validation SHALL fail when committed generated bindings drift from that source.
The ownership migration SHALL preserve existing wire numbers and semantics.

Add capability negotiation versionably and additively.
A provider SHALL report protocol version, provider identity and version, supported artifact formats, runtime features, acceleration implementations, device-resource bindings, memory semantics, concurrency, and cache capabilities before those facts authorize work.
Unknown, malformed, absent, stale, or incompatible required evidence MUST NOT be treated as affirmative compatibility.

Provider-specific codes and fields MAY remain bounded diagnostic evidence during migration.
They MUST NOT become portable scheduler policy or new durable public categories without an explicit contract change.
Existing workers and bindings remain decodable through a documented compatibility window.

## Consequences

New providers can implement one stable local contract without joining the Controller transport or BEAM trust boundary.
Generated bindings and conformance fixtures reduce silent wire drift.
The Node Agent owns the mapping from provider protocol evidence into Orchard's portable domain.

The migration requires reproducible generation, compatibility fixtures, additive decoding, and coordinated packaging changes.
Real-hardware acceptance remains required in addition to provider-neutral conformance.

## SPEC.md impact

Update required in §§1.5, 2.4, 4.9, 4.10, 7.5, and 12.2.
