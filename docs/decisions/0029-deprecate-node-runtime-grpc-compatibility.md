# ADR: Deprecate Node Runtime gRPC compatibility in staged release epochs

## Status

Proposed under issue #350.

## Context

ADR 0001 made the first-party Runtime Endpoint path BEAM-first while retaining `NodeRuntimeService` for explicit compatibility and possible future adapter use.
ADR 0012 retained separate gRPC and mTLS control roles for production BEAM authorization and recovery.
The provider-neutral Worker Runtime contract in ADR 0025 also retains a separate Node Agent-local gRPC and Unix-domain-socket boundary.

PR #341 made the Node Runtime listener configurable, and PR #346 proved a listener-free source-development BEAM operation matrix with a deterministic validation adapter.
The current contract still requires all-in-one gRPC loopback, explicit split-role and packaged gRPC fallback, a default-enabled Node Runtime listener, mixed Controller and Node Agent versions, and rollback-safe releases.
The BEAM path and Worker Runtime also still consume generated `cluster.v1.runtime` message types.

## Decision

Deprecate `NodeRuntimeService` only as the first-party Controller-to-Node Agent Runtime Endpoint compatibility transport.
Keep the transport-independent Runtime Endpoint Interface as the durable boundary.
Keep Peer Grant/control and Worker Runtime gRPC boundaries outside this deprecation.
Keep future non-BEAM adapters possible without promising the current protocol permanently.

Use staged Bridge, Deprecation, Floor, and Removal release epochs.
The Bridge Release qualifies every affected supported profile on the non-gRPC path while retaining compatibility.
The Deprecation Release makes the non-gRPC path the only default and makes the runtime listener default-off while retaining explicit rollback.
The non-destructive Floor Release retains every compatibility asset and records the exact minimum-version cutover only after every participant runs that version and proves removal readiness.
The Removal Release requires that earlier cutover and removes the first-party runtime adapters and listener only after actual `N`, `N-1`, and reverse Controller rollback pairings pass.

Migrate all-in-one source development first through a same-VM Runtime Endpoint client that does not require gRPC loopback or distributed Erlang networking.
Retain explicit gRPC restart as immediate rollback in that first slice.

Delete four layers independently and in order: listener and profile defaults, first-party runtime adapters, runtime protobuf messages and generated bindings, then shared dependency ownership.
Runtime-message deletion remains blocked while BEAM internals or the Worker Runtime contract consume those messages.
Shared dependency removal remains blocked while Peer Grant/control or Worker Runtime boundaries consume gRPC or protobuf.

## Consequences

The deprecation can advance without conflating listener absence with protobuf independence or weakening pre-BEAM authorization.
All-in-one source development gains a simpler same-VM architecture before any supported rollback surface is removed.
The staged release epochs require more qualification time but provide a non-circular Controller and Node Agent `N` and `N-1` window plus a tested Controller rollback pairing.
An unknown supported external consumer blocks adapter removal, but speculative future adapter language does not force permanent retention of `NodeRuntimeService`.

## SPEC.md impact

Update required in §§1.2, 7.5, 10.6, 11, and 13 only as accepted implementation stages change the current all-in-one, compatibility, listener, packaged, version, or rollback contract.
This proposal does not change `SPEC.md` or runtime behavior.
