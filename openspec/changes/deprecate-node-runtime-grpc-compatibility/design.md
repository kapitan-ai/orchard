## Context

The Runtime Endpoint Interface is Orchard's transport-independent Controller-facing execution boundary.
The first-party Node Agent is its v1 endpoint.
`NodeRuntimeService` is one compatibility adapter for that interface, not the interface itself.

The current product contract contains four different facts that cannot be collapsed into one removal decision.

- Split-role source development defaults to BEAM but preserves explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` operation on port `50071`.
- All-in-one `bin/dev` rejects BEAM and uses gRPC loopback as its active Controller-to-Node Runtime Endpoint path.
- Packaged Controller and Node Agent releases default to BEAM but preserve explicit gRPC fallback, listener configuration, generated operator environments, and launchd behavior.
- Peer Grant/control and Worker Runtime boundaries use gRPC or protobuf for roles that the first-party Runtime Endpoint migration does not replace.

PR #341 made the Node Runtime listener independently configurable without changing any supported default.
PR #346 then proved a listener-free source-development BEAM operation matrix using a real Controller, a real Node Agent, the real BEAM client and endpoint, and a deterministic validation adapter.
PR #346 does not prove packaged operation, real MLX execution, physical multi-host behavior, mixed Product Versions, rolling upgrades, rollback, or removal of protobuf-shaped internals.

The current Product Version is a development version, and repository evidence does not establish which published release cohorts operators run.
This design therefore names relative compatibility epochs and evidence gates rather than inventing an immediate SemVer removal floor.

## Goals / Non-Goals

**Goals:**

- Define exactly which `NodeRuntimeService` role is deprecated.
- Preserve every independent gRPC and protobuf boundary not replaced by this change.
- Inventory current consumers, supported compatibility modes, implementation dependencies, test coupling, and speculative future-adapter language.
- Define how all-in-one, split-role source development, packaged releases, mixed versions, and rollback move through the deprecation.
- Define observable evidence gates between warning, default-off, adapter removal, protobuf deletion, and dependency cleanup.
- Identify the smallest reversible first implementation slice.

**Non-Goals:**

- Any runtime, shell, configuration, packaging, CLI, protobuf, generated-code, or dependency behavior change in this proposal.
- A listener default change or executable deprecation warning.
- Removal or replacement of Peer Grant, enrollment, certificate lifecycle, delivery, recovery, diagnostics, or other pre-BEAM control traffic.
- A Node Agent-to-Worker Runtime protocol change.
- Repository-wide removal of gRPC or protobuf.
- A promise that every future non-BEAM Runtime Endpoint adapter uses BEAM or the current `NodeRuntimeService` protocol.
- A claim that repository search proves no unknown external consumer exists.

## Boundary Decision

The deprecation target is the first-party Controller-to-Node Agent Runtime Endpoint operations currently carried by `cluster.v1.NodeRuntimeService`.

The following boundaries remain supported and outside this deprecation.

- `Orchard.RuntimeEndpoint.Client` and the complete transport-independent Runtime Endpoint operation and observation model.
- Certificate-authenticated `ControllerPeerGrantService` delivery and recovery.
- Enrollment, Node and Controller certificate lifecycle, trust recovery, diagnostics, and other pre-BEAM control responsibilities that still require an explicit authenticated control path.
- The provider-neutral Node Agent-to-Worker Runtime interface over local gRPC and Unix-domain sockets.
- `common.proto`, `events.proto`, and shared gRPC/protobuf dependencies while any retained boundary consumes them.
- A future non-BEAM Runtime Endpoint adapter designed under its own accepted protocol contract.

Removal of the current runtime compatibility protocol does not authorize any retained boundary to move onto BEAM.
It also does not authorize external or partially trusted endpoints to join the first-party BEAM mesh.

## Consumer And Compatibility Inventory

### Product and public API promises

Repository product contracts expose `NodeRuntimeService` as an internal `cluster.v1` compatibility service rather than a tenant-facing public API.
The public `/v1/responses` and `/v1/chat/completions` contracts depend on stable Runtime Endpoint outcomes, not on this transport.
No accepted repository contract or current issue and PR evidence identifies a supported external product that directly consumes `NodeRuntimeService`.
This is bounded repository and project evidence, not proof that no private or historical consumer exists.

### Supported operator compatibility modes

| Surface | Current commitment | Removal implication |
|---|---|---|
| All-in-one `bin/dev` | Active gRPC loopback on the source-development port and explicit rejection of BEAM | Must migrate first and retain explicit immediate rollback during its first slice |
| Split-role source development | BEAM default with explicit `grpc` opt-out and `ORCHARD_RUNTIME_CLIENT_TARGETS` | Opt-out cannot be removed before a released compatibility baseline and rollback proof |
| Packaged Controller | BEAM default with explicit gRPC fallback and generated operator environment support | Fallback cannot be removed before packaged, lifecycle, real-runtime, and mixed-version qualification |
| Packaged Node Agent | Runtime listener remains default-enabled and listener host, port, TLS credentials, and readiness remain configured | Default-off and removal require separate profile gates |
| Orchard.app, DMG, and launchd | Payload wrappers and generated environments preserve both BEAM and gRPC profiles | App update and rollback evidence must cover the selected release baseline |

### First-party implementation dependencies

| Layer | Current consumers and coupling |
|---|---|
| Controller interface and selection | `Orchard.RuntimeEndpoint.Client`, `BeamClient`, `GrpcCompatibilityClient`, inference configuration, and activation probes |
| Direct gRPC dispatch | `GrpcNodeRuntimeClient` and `NodeRuntimeService.Stub` |
| Domain mapping | `GrpcCompatibilityMapper`, shared `GrpcMapping`, Node Agent `RuntimeEndpointMapper`, status observation normalization, and inference event mapping |
| Scheduler, lifecycle, inference, and diagnostics | single-node and multi-node schedulers, request dispatch, inference, Nodes observation paths, activation, Console diagnostics, and CLI join probes |
| Node Agent service | `RuntimeServer`, Node `Endpoint`, `GRPC.Server.Supervisor`, listener settings, TLS credentials, readiness, and supervision tests |
| Protocol and generation | `proto/cluster/v1/runtime.proto`, generated Elixir `runtime.pb.ex`, generated Python `runtime_pb2.py` and `runtime_pb2_grpc.py`, root generation tasks, and drift tests |
| Worker Runtime imports | the provider-neutral Worker Runtime schema and MLX implementation still import runtime request, response, acknowledgement, model, and inference-event messages from `cluster.v1` |

### Transport-only and compatibility test coupling

Controller adapter, mapper, scheduler, dispatch, activation, observation, and inference suites directly construct gRPC compatibility messages or clients.
Node Agent suites start the compatibility server and assert listener supervision and readiness behavior.
CLI node-join, generated-environment, payload-wrapper, and transport tests encode the compatibility configuration contract.
Source-development, shutdown-custody, payload-release, and packaging smoke paths select gRPC explicitly in some scenarios.
These tests are removal work, not evidence that the transport is part of the public inference API.

### Speculative future adapters

ADR 0001 and the accepted runtime-endpoints specification allow the current protocol to be reused or evolved for a future non-BEAM adapter.
No current repository implementation, accepted adapter contract, or supported external consumer requires that reuse.
The extension point belongs to the Runtime Endpoint Interface, not to `NodeRuntimeService` permanence.

## Topology Migration

### Stage A: all-in-one source-development migration

The first implementation slice changes only the active all-in-one source-development Runtime Endpoint path.
All-in-one `bin/dev` will use a same-VM transport-independent Runtime Endpoint client by default.
It will not enable distributed Erlang networking merely to call the Node Agent inside the same BEAM VM.

The slice retains explicit gRPC selection, the listener, both adapters, all protocol bindings, and dependencies.
Its rollback is an immediate restart with the explicit gRPC selection.
The source-development port remains available for the rollback mode.

This slice closes the only source-development topology that still requires gRPC for its active first-party path.
It does not change split-role or packaged behavior.

### Stage B: Bridge Release baseline

The Bridge Release is the first released Product Version in which every affected supported topology has a qualified non-gRPC first-party path while the runtime compatibility adapters and listeners remain available.
The Bridge Release may warn when operators explicitly select the runtime gRPC compatibility mode or enable its listener.
Warnings must identify the selected compatibility surface without implying that Peer Grant/control or Worker Runtime gRPC is deprecated.

The Bridge Release is not a removal floor.
It exists so mixed-version and rollback evidence can be gathered from a shipped baseline before destructive cleanup.

### Stage D: Deprecation Release baseline

The Deprecation Release makes the non-gRPC path the only default for every qualified first-party profile.
The Node Runtime listener is default-off for those profiles and is enabled only by the explicit compatibility profile.
The Controller adapter, Node Agent server adapter, protocol bindings, and dependencies remain present.

The explicit compatibility mode remains a rollback tool during this release.
Upgrade preflight reports gRPC-only configuration and every endpoint that cannot prove the required non-gRPC capability, identity, authorization, and reachability.

### Stage F: Floor Release and compatibility cutover

The Floor Release is a non-destructive release after the Deprecation Release.
It retains the runtime listener, both runtime adapters, protocol bindings, and shared dependencies.
It ships the preflight and durable compatibility-cutover mechanism that can raise one cluster's minimum Controller and Node Agent Product Version to the exact Floor Release only after every participating Controller and Node Agent runs that version and proves removal readiness.

The cutover records the exact Product Version floor, non-gRPC capability contract, participating Controller and Node Agent identities and versions, evidence timestamp, and operator approval.
It rejects a stale, incomplete, or mixed cohort and leaves the prior floor unchanged.
After cutover, update and rollback preflight rejects any Controller or Node Agent older than the recorded Floor Release before mutation, even though the Floor Release artifacts still retain the compatibility adapters.

The Floor Release therefore separates the compatibility-floor decision from destructive cleanup and makes the floor observable before Stage X.

### Stage X: Runtime adapter removal

The Removal Release removes the first-party Controller and Node Agent `NodeRuntimeService` adapters and the runtime listener.
It rejects `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`, `ORCHARD_RUNTIME_CLIENT_TARGETS`, and listener-only runtime compatibility configuration with a clear minimum-version error.
It requires a previously recorded Floor Release compatibility cutover and refuses mutation when the cutover is absent, stale, or names another Product Version.

The Removal Release does not automatically delete runtime protobuf messages or shared dependencies.

## Mixed-Version And Rollback Contract

The Controller `N` requirement to support Node Agent `N` and `N-1` remains normative.
Rollback additionally requires a newer Node Agent to work with the immediately previous Controller across each staged rollout, even though that reverse direction is not the general support promise.

Bridge, Deprecation, Floor, and Removal are compatibility epochs, not substitutes for Product Versions.
Before an epoch is assigned, its accepting change must enumerate the exact Product Versions in that epoch and the complete Controller `N` with Node Agent `N` and `N-1` matrix for every real release transition.
Any intervening Product Version must appear in that matrix rather than being skipped by a symbolic epoch label.

The exact Product Version immediately before the Removal Release must belong to the Floor epoch.
The Removal Controller must operate the immediately previous Floor Node Agent over the non-gRPC path as its actual `N-1` obligation.
The Floor Controller must operate the Removal Node Agent over the non-gRPC path as the bounded Controller rollback pairing.
Every earlier version must be rejected by the recorded Floor cutover before an X mutation begins.

Version strings are necessary but insufficient.
Preflight must also prove the effective non-gRPC capability, exact identity and authorization, target reachability, required operation and event contract, and absence of unresolved gRPC-only configuration.

The rollback floor must be raised through the durable Floor Release cutover while all compatibility assets remain installed.
The Removal Release may consume that earlier decision but must not create or raise the floor itself.

## Four Deletion Layers

### Layer 1: listener exposure and profile defaults

Ordering:

1. Migrate the active all-in-one source-development path while retaining explicit gRPC rollback.
2. Qualify listener-free non-gRPC behavior for each supported split-role and packaged profile.
3. Add scoped compatibility warnings in the Bridge Release.
4. Make the Node Runtime listener default-off only in the Deprecation Release and only for qualified profiles.
5. Ship the non-destructive Floor Release, complete the durable compatibility cutover, and reject rollback below its exact Product Version before adapter removal.

Prerequisites include profile-specific operation parity, bootstrap, liveness, diagnostics, packaging, real topology, mixed-version, and rollback evidence.
The rollback point remains explicit compatibility selection until the Floor cutover is completed.
After the Floor cutover and before Removal, the complete Floor Release remains the rollback point with all compatibility assets still installed.

Current decision: GO only for the first all-in-one implementation slice after proposal acceptance.
Current decision: NO-GO for changing split-role or packaged listener defaults.

### Layer 2: first-party runtime client and server adapters

Remove `GrpcCompatibilityClient`, `GrpcNodeRuntimeClient`, compatibility mappers, `RuntimeServer`, service registration, and compatibility-specific callers only in the Removal Release.
No supported profile, generated operator environment, smoke path, CLI command, actual `N` and `N-1` pair, or Floor Controller with Removal Node Agent rollback pair may still select these adapters.

Rollback after this layer requires installing the complete Floor Release artifacts and is allowed only because the Floor Controller with Removal Node Agent pairing was qualified before removal.

Current decision: NO-GO.

### Layer 3: runtime protobuf messages and generated bindings

First replace protobuf-shaped BEAM internals and transport-independent domain seams before deleting runtime messages.
Then remove `runtime.proto`, generated Elixir and Python runtime bindings, and generation inputs only after all first-party adapters are gone and the provider-neutral Worker Runtime contract no longer imports those messages.

Listener absence and adapter removal do not prove this layer safe.
PR #346's deterministic adapter itself still exercises protobuf-shaped runtime types.

Rollback after message deletion requires restoring a coherent schema, generated bindings, and every dependent package together.

Current decision: NO-GO.

### Layer 4: shared gRPC and protobuf dependencies

Re-evaluate dependency ownership only after the first three layers are complete.
The repository may narrow which applications own gRPC server, client, protobuf, and generation dependencies without deleting them globally.
Global removal remains blocked while Peer Grant/control or Worker Runtime boundaries consume them.

Current decision: NO-GO for repository-wide dependency removal.

## Acceptance Evidence Gates

Each default promotion, listener change, adapter removal, and message deletion must record exact commit, Product Version, topology, commands, and sanitized pass or fail evidence.
Evidence must cover the following areas at the stage that claims them.

- Runtime Endpoint operation parity for status, model readiness, unload, inference streaming, active cancellation, prefix-cache scoring, and every accepted additive operation.
- Observation normalization for identity, availability, health, placements, aggregate and placement capacity, runtime telemetry, capabilities, and version-skew omission behavior.
- Bootstrap and authorization for same-VM local operation, source-development BEAM, and production Peer Grant paths without circular credential delivery.
- Active and idle liveness, reconnect, restart, heartbeat persistence, scheduler exclusion, and no automatic same-request gRPC fallback.
- Diagnostics and lifecycle callers, including activation, node join, recovery, CLI probes, Console status, and support paths.
- Real MLX execution across the retained Worker Runtime boundary.
- Orchard.app, DMG, payload wrapper, launchd, installed-service, update, rollback, and retained-state behavior.
- Real supported topologies, including physical multi-host operation where the profile claims it.
- Controller and Node Agent `N` and `N-1` operation plus the explicitly required reverse Controller rollback pairing.
- Preflight rejection of too-old versions, incompatible capabilities, unresolved gRPC-only configuration, and missing identity, authorization, or reachability evidence before mutation.

PR #346 satisfies only the source-development listener-free transport-isolation subset for its deterministic validation adapter.
It is reusable evidence for Stage A and later source-development gates, but it is not packaged, real-MLX, physical multi-host, mixed-version, upgrade, rollback, or protobuf-deletion qualification.

## Supported External Consumer Decision

No supported external or non-BEAM `NodeRuntimeService` consumer was found in the repository, current issues and PRs, accepted decisions, packaging, configuration, or test history reviewed for this change.
The supported consumers found are Orchard's own Controller, Node Agent, CLI and tests, generated bindings, and explicit operator compatibility profiles.

This bounded absence does not justify surprise removal.
The Bridge Release warning and release notes must provide an operator reporting path for an unknown consumer before the Deprecation Release makes the listener default-off.
Any validated supported consumer discovered before Stage X blocks adapter removal until it migrates or receives a separately accepted compatibility decision.

## Decisions And Alternatives

### Use a same-VM local client for all-in-one source development

The all-in-one topology already runs the Controller and Node Agent in one BEAM VM.
Its first-party Runtime Endpoint path will use a transport-independent same-VM client rather than opening a network protocol to itself.

Alternative: start a named local distributed Erlang node and route the call through `BeamClient`.
Rejected because same-VM operation does not need EPMD, cookie material, distribution listeners, or the high-trust BEAM boundary.

Alternative: disable the split-role listener first.
Rejected as the first slice because split-role already defaults to BEAM and the change would not remove the all-in-one contract exception.

### Use Bridge, Deprecation, Floor, and Removal release epochs

Relative epochs keep the contract reviewable without inventing a SemVer or deployed-cohort fact that the repository does not establish.
The accepted implementation sequence must map every epoch to exact released Product Versions, enumerate every actual `N` and `N-1` pairing, and preserve its artifacts before advancing.
The non-destructive Floor Release and durable cutover raise the compatibility floor before the Removal Release deletes anything.

Alternative: remove adapters in the first release where all profiles default to the non-gRPC path.
Rejected because it combines promotion, compatibility-floor change, and destructive cleanup without a shipped rollback baseline.

### Keep future adapters protocol-independent

Future external or non-BEAM Runtime Endpoints remain possible through the Runtime Endpoint Interface.
They require their own trust, protocol, compatibility, and qualification decision.

Alternative: retain `NodeRuntimeService` indefinitely because a future adapter might use it.
Rejected because no current consumer requires that promise and speculative reuse does not justify a permanent first-party protocol obligation.

## Risks / Trade-offs

- [Risk] An unknown external consumer relies on the nominally internal `cluster.v1` service.
  - Mitigation: Keep conclusions bounded, provide a Bridge Release warning and reporting window, and block removal on any validated supported consumer.
- [Risk] Removing the explicit runtime gRPC mode reduces recovery options when BEAM authorization or reachability fails.
  - Mitigation: Retain explicit compatibility through the Deprecation Release and qualify non-gRPC recovery before Stage X.
- [Risk] A version-only preflight admits a pair that cannot actually communicate.
  - Mitigation: Require effective capability, identity, authorization, target, and operation-contract evidence in addition to Product Version.
- [Risk] Protobuf deletion breaks the BEAM path or Worker Runtime even after the TCP listener is gone.
  - Mitigation: Make domain decoupling and provider-neutral Worker Runtime imports explicit prerequisites for Layer 3.
- [Risk] A broad dependency cleanup removes Peer Grant/control or Worker Runtime gRPC accidentally.
  - Mitigation: Reassess dependency ownership last and preserve each retained boundary through direct tests.
- [Risk] PR #346 is treated as production qualification.
  - Mitigation: Name its exact deterministic source-development scope at every stage that cites it.

## Migration Plan

1. Accept this scoped contract without changing runtime behavior.
2. Implement and qualify the same-VM all-in-one Runtime Endpoint path while retaining explicit gRPC rollback.
3. Establish and release the Bridge epoch after every affected supported profile has qualified non-gRPC operation and scoped compatibility warnings.
4. Establish and release the Deprecation epoch after default-off listener behavior, packaged lifecycle, mixed-version, and rollback qualification pass.
5. Ship the non-destructive Floor Release with all compatibility assets intact and map every epoch to exact Product Versions and actual version pairings.
6. Complete the durable compatibility cutover only after every participating Controller and Node Agent runs the Floor Release and proves removal readiness.
7. Remove first-party `NodeRuntimeService` adapters and listener only after Removal Controller with Floor Node Agent and Floor Controller with Removal Node Agent evidence passes and the earlier Floor cutover is present.
8. Decouple runtime protobuf-shaped domain and Worker Runtime imports before deleting runtime messages and generated bindings.
9. Reassess shared dependency ownership without weakening Peer Grant/control or Worker Runtime boundaries.

Rollback before Stage X selects the explicit runtime gRPC compatibility profile and restarts the affected services.
Rollback at or after Stage X installs the complete preserved Floor Release artifacts and uses the prequalified Floor Controller with Removal Node Agent pairing until Node Agents are rolled back safely.

## Open Questions

- Which future released Product Versions will be assigned to the Bridge, Deprecation, Floor, and Removal epochs after their evidence gates pass?
- Which operator-facing warning and reporting surface will collect evidence of an unknown `NodeRuntimeService` consumer during the Bridge Release?
- Which accepted Worker Runtime ownership slice will remove the remaining `cluster.v1.runtime` message imports before Layer 3 can proceed?
