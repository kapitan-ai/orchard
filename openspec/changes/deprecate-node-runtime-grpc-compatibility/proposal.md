## Why

Orchard's first-party Controller-to-Node Runtime Endpoint path is BEAM-first in split-role source development and packaged releases, but the durable contract still requires the gRPC/protobuf `NodeRuntimeService` compatibility transport.
All-in-one `bin/dev` still uses gRPC loopback, split-role and packaged profiles still support explicit gRPC selection, and the Node Agent still exposes the compatibility listener by default.

PR #346 proves that a real source-development Controller and Node Agent can complete the validated Runtime Endpoint operation matrix while the Node Runtime gRPC listener is absent.
That proof does not cover all-in-one operation, packaged lifecycle, real MLX, physical two-Mac operation, mixed versions, upgrades, rollback, or protobuf independence.

One accepted compatibility contract is required before implementation changes any supported default, listener, adapter, generated binding, or dependency.

## What Changes

- Deprecate `NodeRuntimeService` only as the first-party Controller-to-Node Runtime Endpoint compatibility transport.
- Preserve the transport-independent Runtime Endpoint Interface and require all first-party migration work to keep its operation and observation semantics stable.
- Preserve certificate-authenticated Peer Grant, enrollment, certificate lifecycle, delivery, recovery, diagnostics, and other pre-BEAM control roles unless a separate accepted change replaces them.
- Preserve the Node Agent-to-Worker Runtime gRPC and Unix-domain-socket boundary.
- Preserve a future non-BEAM Runtime Endpoint adapter extension point without promising that `NodeRuntimeService` or `cluster.v1` remains its permanent protocol.
- Define a staged all-in-one, split-role, packaged, mixed-version, and rollback migration using Bridge, Deprecation, Floor, and Removal release epochs rather than naming an unsupported SemVer floor.
- Treat listener and profile defaults, first-party runtime adapters, runtime protobuf messages and generated bindings, and shared gRPC/protobuf dependencies as four independent deletion layers.
- Make all-in-one source-development migration to a same-VM transport-independent Runtime Endpoint client the first implementation slice after this proposal is accepted.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `runtime-endpoints`: Defines the scoped `NodeRuntimeService` deprecation boundary, topology migration, mixed-version and rollback gates, consumer evidence, and deletion ordering.

## Impact

- Product contract: `SPEC.md` §§1.2, 7.5, 10.6, 11, and 13 require reconciliation only as each accepted implementation stage changes supported behavior.
- Runtime Endpoint contract: `openspec/specs/runtime-endpoints/spec.md` currently requires all-in-one gRPC loopback, explicit split-role and packaged gRPC compatibility, and preservation of `NodeRuntimeService` as a possible adapter protocol.
- Decisions: ADR 0001's bounded gRPC retention is narrowed by proposed ADR 0029, while ADR 0012 and ADR 0025 remain fully in force for Peer Grant/control and Worker Runtime boundaries.
- Source development: `bin/dev`, `bin/dev-controller`, `bin/dev-node-agent`, `config/dev.exs`, and source-development transport tests encode current defaults and rollback surfaces.
- Packaged operation: release configuration, payload wrappers, generated environment files, Orchard.app/DMG lifecycle, and launchd profiles encode current BEAM defaults and explicit gRPC fallback.
- Runtime adapters: Controller compatibility clients and mappers, scheduler and lifecycle callers, Node Agent server and listener supervision, and CLI probes remain live until their stage gates pass.
- Protocol ownership: `runtime.proto`, generated Elixir and Python bindings, BEAM-side protobuf-shaped internals, and Worker Runtime imports prevent early runtime-message deletion.
- No runtime behavior, default, listener, generated binding, dependency, or `SPEC.md` text changes in this proposal.
