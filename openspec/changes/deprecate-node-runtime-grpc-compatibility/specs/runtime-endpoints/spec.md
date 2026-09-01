## ADDED Requirements

### Requirement: Scoped Node Runtime gRPC Compatibility Deprecation
Per `SPEC.md` §§1.2, 7.5, 10.6, 11, and 13, Orchard SHALL deprecate `cluster.v1.NodeRuntimeService` only as the first-party Controller-to-Node Agent Runtime Endpoint compatibility transport through explicit Bridge, Deprecation, Floor, and Removal release epochs.
The transport-independent Runtime Endpoint Interface SHALL remain the durable Controller-facing contract.
Certificate-authenticated Peer Grant, enrollment, certificate lifecycle, delivery, recovery, diagnostics, and other pre-BEAM control roles SHALL remain outside this deprecation unless separately replaced through an accepted change.
The Node Agent-to-Worker Runtime gRPC and Unix-domain-socket boundary SHALL remain outside this deprecation.
Future non-BEAM Runtime Endpoint adapters MAY use a separately accepted protocol and MUST NOT require permanent retention of `NodeRuntimeService` merely because an adapter extension point exists.

#### Scenario: First-party compatibility transport is deprecated
- **WHEN** Orchard advances through an accepted `NodeRuntimeService` deprecation stage
- **THEN** only the first-party Controller-to-Node Runtime Endpoint compatibility role changes
- **THEN** Runtime Endpoint Interface operations and observations remain transport-independent

#### Scenario: Peer Grant control remains required
- **WHEN** the first-party Runtime Endpoint path no longer uses `NodeRuntimeService`
- **THEN** certificate-authenticated Peer Grant delivery and recovery remain available through their separately owned control protocol
- **THEN** Orchard does not treat BEAM as the credential-delivery mechanism required to establish its own authorization

#### Scenario: Worker Runtime remains local and provider-neutral
- **WHEN** the Controller-to-Node runtime compatibility transport is disabled or removed
- **THEN** the Node Agent continues to supervise Worker Runtime processes through the separately owned provider-neutral local boundary

#### Scenario: Future non-BEAM adapter is proposed
- **WHEN** a future external or non-BEAM Runtime Endpoint requires a transport protocol
- **THEN** its accepted adapter contract selects an appropriate protocol without assuming `NodeRuntimeService` permanence

### Requirement: Staged Runtime Compatibility Topology Migration
Orchard SHALL migrate the active all-in-one source-development Runtime Endpoint path before disabling the runtime compatibility listener in any supported profile.
All-in-one source development SHALL use a same-VM transport-independent Runtime Endpoint client by default without requiring distributed Erlang networking.
The first all-in-one migration SHALL retain explicit gRPC selection, the runtime listener, both adapters, all runtime protobuf bindings, and every shared dependency as immediate rollback assets.
Split-role and packaged defaults and listeners MUST NOT change until their profile-specific evidence gates pass in a later accepted stage.

#### Scenario: All-in-one first slice uses same-VM runtime semantics
- **WHEN** the accepted first implementation slice migrates all-in-one `bin/dev`
- **THEN** the Controller invokes the local Node Agent through Runtime Endpoint Interface semantics inside the same BEAM VM
- **THEN** the active path does not require a Node Runtime gRPC loopback connection, EPMD, cookie material, or BEAM distribution listeners

#### Scenario: All-in-one first slice rolls back
- **WHEN** the new all-in-one source-development path cannot complete a required Runtime Endpoint operation
- **THEN** a contributor may restart all-in-one source development with explicit gRPC compatibility selection
- **THEN** Orchard does not retry the failed request automatically through gRPC

#### Scenario: Split-role default is unchanged by the first slice
- **WHEN** the all-in-one migration is implemented
- **THEN** split-role source development retains its current BEAM default and explicit gRPC opt-out
- **THEN** its listener behavior remains unchanged

#### Scenario: Packaged profiles are unchanged by the first slice
- **WHEN** the all-in-one migration is implemented
- **THEN** packaged Controller, Node Agent, Orchard.app, DMG, launchd, generated environment, listener, and rollback behavior remain unchanged

### Requirement: Bridge Deprecation Floor And Removal Release Gates
Orchard SHALL map each Bridge, Deprecation, Floor, and Removal epoch to exact released Product Versions only after that epoch's evidence gate passes.
The mapping SHALL enumerate every Product Version in each epoch and every actual Controller `N` with Node Agent `N` and `N-1` pairing rather than using epoch labels as version substitutes.
The Bridge Release SHALL qualify every affected supported profile on the non-gRPC first-party path while retaining compatibility adapters and listeners.
The Deprecation Release SHALL make the non-gRPC path the only default for qualified profiles, make the runtime listener default-off, and retain explicit compatibility as rollback.
The non-destructive Floor Release SHALL retain every compatibility asset and provide a durable compatibility cutover that raises one cluster's exact minimum Product Version only after every participating Controller and Node Agent runs the Floor Release and proves removal readiness.
The Removal Release SHALL require that previously completed exact Floor Release cutover before removing the first-party runtime adapters and listener.
The Removal Release MUST NOT create or raise the compatibility floor that authorizes its own destructive cleanup.

#### Scenario: Bridge baseline is not yet qualified
- **WHEN** any affected supported profile lacks operation, real topology, real runtime, packaging, mixed-version, or rollback evidence
- **THEN** Orchard does not declare the Bridge Release baseline complete
- **THEN** listener defaults remain unchanged

#### Scenario: Deprecation baseline remains reversible
- **WHEN** a qualified profile runs the Deprecation Release
- **THEN** its non-gRPC first-party path is the default
- **THEN** explicit compatibility selection can still enable the runtime adapter and listener for rollback

#### Scenario: Floor cutover is attempted with a mixed cohort
- **WHEN** any participating Controller or Node Agent does not run the exact Floor Release or lacks removal-readiness evidence
- **THEN** Orchard rejects the cutover and leaves the prior compatibility floor unchanged
- **THEN** every runtime compatibility asset remains installed

#### Scenario: Floor cutover completes before removal
- **WHEN** every participating Controller and Node Agent runs the exact Floor Release and proves the required capability contract
- **THEN** Orchard durably records the exact Product Version floor, capability contract, participating identities and versions, evidence time, and operator approval
- **THEN** later update and rollback preflight rejects versions below that floor before mutation

#### Scenario: Removal is attempted from an older baseline
- **WHEN** the exact Floor Release cutover is absent, stale, or does not cover every participant in a Removal Release update
- **THEN** preflight rejects the update before mutation
- **THEN** the operator receives a clear floor and compatibility explanation

### Requirement: Runtime Compatibility Mixed-Version And Rollback Matrix
Before assigning Product Versions to an epoch, Orchard SHALL enumerate every real Controller `N` with Node Agent `N` and `N-1` pairing across that transition.
The exact Product Version immediately before the Removal Release SHALL belong to the Floor epoch.
The Removal Release Controller SHALL support the immediately previous Floor Release Node Agent over the non-gRPC path as its actual `N-1` obligation.
The Floor Release Controller SHALL support the Removal Release Node Agent over the non-gRPC path as the bounded Controller rollback pairing.
Before any participant advances to the Removal Release, the exact Floor Release cutover SHALL cover all participating Controllers and Node Agents.
Compatibility preflight SHALL verify effective non-gRPC capability, identity, authorization, reachability, and operation-contract evidence in addition to Product Version.

#### Scenario: Removal Controller operates previous Node Agent
- **WHEN** a Removal Release Controller communicates with the immediately previous Floor Release Node Agent
- **THEN** the pair completes the supported Runtime Endpoint operation and observation contract over the non-gRPC path

#### Scenario: Controller rolls back after Node Agent removal update
- **WHEN** a Node Agent runs the Removal Release and the Controller rolls back to the Floor Release
- **THEN** the pair completes the bounded rollback contract over the non-gRPC path
- **THEN** it does not require the removed Node Runtime listener

#### Scenario: An intervening Product Version exists
- **WHEN** a real Product Version exists between two assigned compatibility epochs
- **THEN** the accepting change includes that version in the exact support and rollback matrix
- **THEN** Orchard does not infer compatibility from the symbolic epoch labels

#### Scenario: Version matches but capability evidence fails
- **WHEN** a participant reports a nominally compatible Product Version but cannot prove required non-gRPC capability, identity, authorization, reachability, or operation compatibility
- **THEN** preflight rejects the staged update before mutation

### Requirement: Independent Runtime Compatibility Deletion Layers
Orchard SHALL treat listener exposure and profile defaults, first-party runtime client and server adapters, runtime protobuf messages and generated bindings, and shared gRPC/protobuf dependencies as four independent deletion layers in that order.
Each layer SHALL have its own consumer search, prerequisites, exact validation evidence, and rollback point.
Listener absence MUST NOT prove adapter or protobuf deletion safe.
Adapter removal MUST NOT prove runtime-message deletion safe while BEAM internals, Worker Runtime schemas, generated bindings, tests, or packages still consume those messages.
`NodeRuntimeService` removal MUST NOT authorize deletion of shared gRPC or protobuf dependencies used by Peer Grant/control or Worker Runtime boundaries.

#### Scenario: Runtime listener is absent
- **WHEN** a qualified profile runs without the Node Runtime TCP listener
- **THEN** Orchard treats only listener exposure as proven absent
- **THEN** adapter, runtime-message, generated-binding, and shared-dependency deletion remain separately gated

#### Scenario: Runtime adapters have no supported consumer
- **WHEN** every supported profile, CLI path, generated operator environment, smoke path, and mixed-version pair no longer selects the first-party runtime adapters
- **THEN** Orchard may remove those adapters in the accepted Removal Release
- **THEN** runtime protobuf messages remain until their own consumers are removed

#### Scenario: Worker Runtime imports runtime messages
- **WHEN** the provider-neutral Worker Runtime schema or an implementation still imports `cluster.v1.runtime` messages
- **THEN** Orchard does not delete those runtime messages or generated bindings

#### Scenario: Retained control protocol uses gRPC
- **WHEN** Peer Grant delivery, recovery, or another separately retained control role still uses gRPC or protobuf
- **THEN** Orchard preserves the required shared dependencies and direct validation

### Requirement: Runtime Compatibility Evidence And Consumer Gate
Before each default promotion, listener change, adapter removal, or runtime-message deletion, Orchard SHALL record exact sanitized evidence for every behavior claimed by that stage.
The evidence SHALL cover applicable Runtime Endpoint operation parity, observation normalization, bootstrap, liveness, diagnostics, cancellation, packaging, real-runtime, real-topology, mixed-version, upgrade, and rollback behavior.
Repository and project searches MAY establish that no supported external `NodeRuntimeService` consumer is known, but MUST NOT be represented as universal proof of absence.
Any validated supported consumer discovered before adapter removal SHALL block removal until it migrates or receives a separate accepted compatibility decision.

#### Scenario: PR 346 evidence is reused
- **WHEN** PR #346 is cited as listener-free evidence
- **THEN** Orchard credits only its deterministic source-development BEAM Runtime Endpoint operation matrix and listener-absence proof
- **THEN** Orchard does not infer packaged, real-MLX, physical multi-host, mixed-version, upgrade, rollback, or protobuf-independence qualification

#### Scenario: Unknown consumer is reported during deprecation
- **WHEN** an operator reports a supported `NodeRuntimeService` consumer during the Bridge or Deprecation stage
- **THEN** Orchard validates the consumer against the supported product contract
- **THEN** a validated supported consumer blocks adapter removal until its compatibility path is resolved

#### Scenario: No external consumer is found in repository evidence
- **WHEN** repository, issue, PR, packaging, configuration, test, and history searches find only Orchard-owned consumers and speculative future-adapter language
- **THEN** the change records that bounded absence without claiming that no private or historical consumer exists
