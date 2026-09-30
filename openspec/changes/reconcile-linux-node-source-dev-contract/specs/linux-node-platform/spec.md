## Purpose

Defines the bounded experimental `ubuntu_24_04_x86_64_node` Linux Node candidate: its closed host matrix, source-development installation path, exact source evidence binding, identity ownership, private-network trust, observation-only inventory, version-skew targeting, provider separation, and mixed-platform acceptance, without establishing Linux Node support.

## ADDED Requirements

### Requirement: Linux Node Candidate Has A Closed Host Matrix

Orchard SHALL define `ubuntu_24_04_x86_64_node` as an experimental Linux Node platform profile candidate that requires Ubuntu Server 24.04 LTS on x86_64, Linux kernel 6.8 or newer within the Ubuntu 24.04 hardware-enablement line, glibc 2.39 or newer within that release, systemd 255 or newer, and unified cgroup v2.
Other Ubuntu releases, including Ubuntu 26.04 LTS, other distributions, architectures, libc implementations, init systems, containers-as-hosts, WSL, and rootless installation SHALL remain unqualified.
Defining, implementing, or testing the candidate SHALL NOT establish Linux Node support.
This requirement changes `SPEC.md` §1.4.

#### Scenario: Host outside the matrix is prepared

- **WHEN** candidate preflight observes a host outside the closed matrix, including Ubuntu 26.04 LTS
- **THEN** preflight fails before Node Identity Root, service-manager, or enrollment mutation
- **AND** diagnostics name the unqualified dimension without claiming support

### Requirement: Linux Node Candidate Targets Source Development

The candidate's proposed target installation path SHALL be source development of the Node-only role of the portable Node Agent from an exact source revision with the pinned repository toolchain.
That path is not yet operable on the candidate host, and making it operable is future implementation work.
The candidate SHALL NOT define or produce a Debian package, other package, container image, or other deployment artifact.
Executing candidate source qualification SHALL NOT require building a Linux Node package, `Orchard.app`, or a DMG and SHALL NOT add a distribution goal.
Candidate qualification hosts SHALL run no Controller, Console, or database role.
This requirement changes `SPEC.md` §§1.4 and 11.

#### Scenario: Contributor prepares the candidate

- **WHEN** a contributor prepares a candidate Node on a matrix host after the source path is implemented
- **THEN** the Node Agent runs from a source checkout at an exact revision with the pinned toolchain
- **AND** no package, image, or other deployment artifact is built or installed

### Requirement: Candidate Evidence Binds To An Exact Clean Source Revision

Every candidate qualification record SHALL bind to the exact source commit and tree, clean-checkout proof, dependency lock identities, pinned toolchain identity, passing generated-output drift checks, and the observed host matrix facts.
A dirty, unidentified, or drifted checkout SHALL produce implementation evidence only and SHALL NOT satisfy a qualification gate.
Evidence binding SHALL NOT impose a host-wide canonical checkout location or single-checkout rule on developer worktrees, macOS hosts, or Nodes outside the candidate qualification host.
This requirement changes `SPEC.md` Milestone 9.

#### Scenario: Qualification runs from a modified checkout

- **WHEN** candidate tests run from a checkout with uncommitted changes or a lock or generated output that does not match the recorded revision
- **THEN** the results are recorded as implementation evidence only
- **AND** no qualification gate is marked satisfied

### Requirement: Linux Node Agent Runs With Least Privilege

Candidate qualification SHALL run the Node Agent as a dedicated unprivileged non-login service identity that owns its Node Identity Root.
That identity SHALL have no sudo, package-mutation, database-credential, device-reset, or device-reconfiguration authority.
Agent operation as root, with sudo, or under a shared interactive account SHALL remain unqualified.
Any fixed service-identity name belongs to a future separately approved packaging contract.
This requirement changes `SPEC.md` §4.9.

#### Scenario: Agent starts as root

- **WHEN** a candidate Node Agent starts with root privileges or a shared interactive account
- **THEN** the run is not qualification evidence
- **AND** diagnostics identify the privilege dimension as unqualified

### Requirement: One Agent Exclusively Owns One Node Identity Root

Each candidate Node Agent SHALL hold a process-lifetime exclusive owner-only lock in its durable Node Identity Root and SHALL reject a second owner before enrollment, Runtime Endpoint activation, or Worker Runtime startup.
Candidate qualification SHALL place that Node Identity Root on a local POSIX filesystem that enforces ownership, mode, and atomic rename.
PID, heartbeat, runtime-directory, and process-name evidence SHALL NOT adopt an existing identity or process.
This requirement changes `SPEC.md` §4.9.

#### Scenario: Duplicate Agent starts for the same identity

- **WHEN** another Agent already holds the Node Identity Root ownership lock
- **THEN** the new Agent fails before enrollment, Runtime Endpoint activation, or Worker Runtime startup
- **AND** it neither adopts the existing process nor rewrites the identity

### Requirement: Qualified Lifecycle Uses One Supervised Agent Without Creating Authority

Candidate lifecycle qualification SHALL use one systemd system service unit that supervises exactly one Node Agent for one Node Identity Root, with the Agent and its Worker Runtime descendants in that unit's cgroup.
The candidate qualification host SHALL run exactly one supervised candidate Agent.
A foreground developer session SHALL produce implementation evidence only.
systemd, cgroup, PID, heartbeat, runtime-directory, and device observations SHALL NOT prove Orchard custody, native cessation, request-slot release, resource release, dispatch authority, or scheduling authority.
This requirement changes `SPEC.md` §§4.9 and 13.4.

#### Scenario: Supervised unit reports an empty cgroup

- **WHEN** systemd reports that the candidate unit stopped and its cgroup is empty
- **THEN** Orchard records the observation as lifecycle evidence
- **AND** no request slot, resource, placement, or scheduling authority is released from that observation alone

### Requirement: Linux Connectivity Uses Existing Private-Network Trust

The candidate SHALL use only the accepted private-network certificate and Peer Grant model.
Its source qualification SHALL use certificate-authenticated control for enrollment, credential lifecycle, Peer Grant delivery and recovery, and diagnostics, plus Peer Grant-authorized TLS Distribution in a controlled model-free source-development test mesh outside production BEAM membership.
That source-qualification evidence SHALL remain distinct from production BEAM eligibility and support.
The candidate SHALL NOT substitute shared-cookie Distribution, make gRPC compatibility its default Runtime Endpoint transport, or add a new Runtime Endpoint transport, an outbound-only Runtime Endpoint session, an Internet-exposed Node listener, NAT traversal, a tunnel or relay that substitutes for private-network reachability, automatic transport fallback, or replay of an ambiguously accepted inference operation.
Reconnect SHALL revalidate current certificate, Node, admission, target, Peer Grant, and generation authority before accepting new work.
Shared-cookie runs SHALL NOT count as candidate trust or qualification evidence.
This requirement changes `SPEC.md` §10.6.

#### Scenario: Private-network session reconnects

- **WHEN** the selected Runtime Endpoint transport reconnects after interruption
- **THEN** current certificate, Node, admission, target, Peer Grant, and generation authority are revalidated before new work
- **AND** an ambiguously accepted inference operation is not automatically replayed

#### Scenario: Source qualification exercises the Runtime Endpoint

- **WHEN** candidate source qualification exercises Runtime Endpoint behavior
- **THEN** it uses Peer Grant-authorized TLS Distribution in the controlled model-free source-development test mesh
- **AND** the run neither joins production BEAM membership nor falls back to shared-cookie Distribution or gRPC compatibility

#### Scenario: Node is reachable only through a relay

- **WHEN** the candidate Node is reachable from the Controller only through NAT traversal, a tunnel, or a relay
- **THEN** the topology is outside the candidate contract
- **AND** it produces no candidate trust or qualification evidence

### Requirement: Linux Node Candidate Stays Outside Production BEAM

The candidate SHALL remain outside the production BEAM boundary, which `SPEC.md` §7.5.0 limits to signed first-party Orchard releases on operator-controlled admitted Macs inside restricted private networks.
This contract SHALL NOT widen that boundary.
Any production BEAM eligibility or support claim for a Linux Node SHALL require a separately accepted amendment of that boundary with an explicit release and trust profile, exact provenance and reverification, and the accountable product owner's decision.
Source-qualification evidence, portable compilation, a successful transport probe, or certificate identity alone SHALL NOT satisfy that future gate.
This requirement changes `SPEC.md` §§1.4, 7.5.0, and Milestone 9.

#### Scenario: Source revision requests production BEAM

- **WHEN** a candidate Node running from a source revision requests production BEAM admission
- **THEN** admission fails closed before distribution membership
- **AND** source-qualification evidence does not substitute for an accepted release and trust profile

### Requirement: Linux Inventory Is Observation Only

The Linux capability provider SHALL report bounded CPU, memory, disk, OS, kernel, network, and optional accelerator observations through provider-neutral contracts.
Accelerator identity SHALL use a vendor-documented stable identifier when available, and PCI address and device ordinal SHALL remain topology observations.
NVIDIA/CUDA and AMD/ROCm evidence SHALL retain distinct provenance and qualification.
Missing vendor tooling, permission failures, malformed output, duplicates, or unstable identities SHALL produce absent or invalid evidence.
Inventory SHALL NOT create schedulable capacity, a worker unit, a resource allocation, device binding, reset authority, runtime startup, or runtime custody.
This requirement changes `SPEC.md` §4.1.

#### Scenario: Stable accelerator is observed

- **WHEN** the capability provider obtains a valid vendor-stable accelerator identifier
- **THEN** it reports the bounded device observation with its evidence provenance
- **AND** no scheduler, allocation, or runtime authority is created from that observation

#### Scenario: Vendor tooling is missing

- **WHEN** the vendor tool for an observed accelerator is absent or fails
- **THEN** the accelerator evidence is recorded as absent or invalid
- **AND** the device is not reported as healthy or free

### Requirement: Linux Targeting Fails Closed Across Version Skew

Controller `N` MAY interoperate with candidate Node Agent `N` and `N-1` only where the negotiated wire and behavior contract preserves the requested operation.
Missing additive observation fields SHALL decode as absent evidence.
An operation whose safe meaning depends on a worker-unit, resource-allocation, runtime-incarnation, residency, or control-generation target SHALL be rejected when either participant cannot preserve the complete target and SHALL NOT downgrade to ambiguous Node or model targeting.
This requirement changes `SPEC.md` §13.4.

#### Scenario: Older receiver lacks generation targeting

- **WHEN** a writer requests a targeted operation and the receiver cannot preserve its complete target
- **THEN** the receiver rejects the operation with a stable compatibility failure
- **AND** no Node or model ambiguous mutation is attempted

### Requirement: Runtime-Provider Qualification Remains Separate

Linux Node platform qualification SHALL remain separate from every runtime-provider, acceleration, model, and workload qualification.
A successful candidate install, inventory check, or lifecycle test SHALL NOT qualify CUDA, ROCm, vLLM, a model, or a runtime-provider profile.
A one-H100 runtime-provider pilot SHALL require separate authorization after every provider-neutral candidate gate passes and SHALL qualify only one immutable H100, vLLM, model, and serving-configuration tuple at concurrency one without implying broader support.
This requirement changes `SPEC.md` §§1.4 and Milestone 9.

#### Scenario: Candidate passes model-free qualification

- **WHEN** the candidate passes every provider-neutral gate on a host with an NVIDIA accelerator
- **THEN** Orchard records Linux Node platform evidence only
- **AND** no CUDA, vLLM, model, or runtime-provider support is claimed

### Requirement: Mixed-Platform Acceptance Includes The Linux Node And A Designated Predecessor

The `macos_controller_linux_node_model_free` acceptance profile SHALL pair a qualified macOS Controller `N` with candidate Node Agent versions `N` and `N-1`.
It SHALL prove enrollment, admission, authenticated observation, exact worker-unit and resource-allocation targeting under separately accepted contracts, cancellation, drain, Agent restart, orphan handling, and peer isolation for both pairings with model-free fixtures and independently captured evidence from every participating host.
The profile SHALL remain unmet until those targeting contracts are defined and their implementation is accepted.
The `N-1` side SHALL use an exact predecessor Node Agent revision, identified by commit and tree, whose Product Version is earlier than and distinct from `N` and which governed previous-line evidence designates as the logical `N-1` of `SPEC.md` §13.1.
An older commit, a revision sharing `N`'s Product Version, or an arbitrary earlier version SHALL NOT qualify as `N-1`.
This contract SHALL NOT define that designation, and until accepted release-line governance defines it the `N-1` pairing SHALL remain unmet.
Missing predecessor or macOS host evidence SHALL leave the profile unmet, and no support-window floor, first-release exemption, or synthetic predecessor SHALL waive the `N-1` pairing.
This requirement changes `SPEC.md` Milestone 9.

#### Scenario: Only Linux host evidence is available

- **WHEN** candidate behavior is exercised on Linux without controlled macOS Controller evidence
- **THEN** the Linux results may be retained as candidate evidence
- **AND** mixed-platform acceptance remains unmet

#### Scenario: No designated predecessor exists

- **WHEN** no earlier distinct Product Version has been designated by governed previous-line evidence as the logical `N-1`
- **THEN** the `N`/`N-1` pairing remains unmet
- **AND** the profile is not declared passed on `N`/`N` evidence alone

#### Scenario: Older commit shares the current Product Version

- **WHEN** an older commit carries the same Product Version as `N`
- **THEN** it does not qualify as the `N-1` side
- **AND** the `N`/`N-1` pairing remains unmet

### Requirement: Standalone Node Contract Defines No Single-Host Composition

This contract SHALL define only a standalone candidate Node.
It SHALL NOT define, authorize, or qualify a Linux Controller, a managed or local Postgres, or a composition that places a Controller, Postgres, and Node on one candidate host.
A coordinated single-host composition SHALL require its own accepted contract reconciled into `SPEC.md` before implementation.
This requirement changes `SPEC.md` §§1.4 and 11.

#### Scenario: Controller is started on the candidate host

- **WHEN** a Controller or database role runs on the candidate qualification host
- **THEN** the host is outside this candidate contract
- **AND** no candidate qualification or single-host composition evidence is recorded
