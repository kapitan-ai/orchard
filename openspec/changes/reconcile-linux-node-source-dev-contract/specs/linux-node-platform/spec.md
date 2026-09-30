## Purpose

Defines the bounded experimental `ubuntu_24_04_x86_64_node` Linux Node candidate: its closed host matrix, source-development installation path, exact source evidence binding, identity ownership, private-network trust, observation-only inventory, version-skew targeting, provider separation, and mixed-platform acceptance, without establishing Linux Node support.

## ADDED Requirements

### Requirement: Linux Node Candidate Has A Closed Host Matrix

The `ubuntu_24_04_x86_64_node` candidate SHALL satisfy the closed experimental host matrix in `SPEC.md` §1.4, under which Ubuntu 26.04 LTS, other Ubuntu releases, and rootless installation remain unqualified.
Defining, implementing, or testing the candidate SHALL NOT establish Linux Node support.
This requirement changes `SPEC.md` §1.4.

#### Scenario: Host outside the matrix is prepared

- **WHEN** candidate preflight observes a host outside the closed matrix, including Ubuntu 26.04 LTS
- **THEN** preflight fails before Node Identity Root, service-manager, or enrollment mutation
- **AND** diagnostics name the unqualified dimension without claiming support

### Requirement: Linux Node Candidate Targets Source Development

The candidate SHALL follow the proposed Node-only source-development target path, no-artifact rule, no-build source qualification, and no Controller, Console, or database role on qualification hosts in `SPEC.md` §§1.4 and 11, and SHALL produce no Debian package or other deployment artifact.
That path is not yet operable on the candidate host, and making it operable is future implementation work.
This requirement changes `SPEC.md` §§1.4 and 11.

#### Scenario: Contributor prepares the candidate

- **WHEN** a contributor prepares a candidate Node on a matrix host after the source path is implemented
- **THEN** the Node Agent runs from a source checkout at an exact revision with the pinned toolchain
- **AND** no package, image, or other deployment artifact is built or installed

### Requirement: Candidate Evidence Binds To An Exact Clean Source Revision

Every candidate qualification record SHALL satisfy the exact source evidence binding in `SPEC.md` Milestone 9 and SHALL also bind the observed host matrix facts.
A dirty, unidentified, or drifted checkout SHALL produce implementation evidence only and SHALL NOT satisfy a qualification gate.
Evidence binding SHALL NOT impose a host-wide canonical checkout location or single-checkout rule on developer worktrees, macOS hosts, or Nodes outside the candidate qualification host.
This requirement changes `SPEC.md` Milestone 9.

#### Scenario: Qualification runs from a modified checkout

- **WHEN** candidate tests run from a checkout with uncommitted changes or a lock or generated output that does not match the recorded revision
- **THEN** the results are recorded as implementation evidence only
- **AND** no qualification gate is marked satisfied

### Requirement: Linux Node Agent Runs With Least Privilege

Candidate qualification SHALL run the Node Agent under the dedicated least-privilege identity in `SPEC.md` §4.9, and that identity SHALL own its Node Identity Root.
Agent operation as root, with sudo, or under a shared interactive account SHALL remain unqualified.
Any fixed service-identity name belongs to a future separately approved packaging contract.
This requirement changes `SPEC.md` §4.9.

#### Scenario: Agent starts as root

- **WHEN** a candidate Node Agent starts with root privileges or a shared interactive account
- **THEN** the run is not qualification evidence
- **AND** diagnostics identify the privilege dimension as unqualified

### Requirement: One Agent Exclusively Owns One Node Identity Root

Each candidate Node Agent SHALL satisfy the exclusive owner-only Node Identity Root lock and local POSIX filesystem rules in `SPEC.md` §4.9.
PID, heartbeat, runtime-directory, and process-name evidence SHALL NOT adopt an existing identity or process.
This requirement changes `SPEC.md` §4.9.

#### Scenario: Duplicate Agent starts for the same identity

- **WHEN** another Agent already holds the Node Identity Root ownership lock
- **THEN** the new Agent fails before enrollment, Runtime Endpoint activation, or Worker Runtime startup
- **AND** it neither adopts the existing process nor rewrites the identity

### Requirement: Qualified Lifecycle Uses One Supervised Agent Without Creating Authority

Candidate lifecycle qualification SHALL satisfy the single supervised Agent, single qualification-host Agent, and foreground-session evidence rules in `SPEC.md` §4.9 and Milestone 9, with the Agent and its Worker Runtime descendants in that unit's cgroup.
systemd, cgroup, PID, heartbeat, runtime-directory, and device observations SHALL NOT prove Orchard custody, native cessation, request-slot release, resource release, dispatch authority, or scheduling authority.
This requirement changes `SPEC.md` §§4.9 and 13.4.

#### Scenario: Supervised unit reports an empty cgroup

- **WHEN** systemd reports that the candidate unit stopped and its cgroup is empty
- **THEN** Orchard records the observation as lifecycle evidence
- **AND** no request slot, resource, placement, or scheduling authority is released from that observation alone

### Requirement: Linux Connectivity Uses Existing Private-Network Trust

The candidate SHALL satisfy the private-network certificate and Peer Grant model in `SPEC.md` §10.6, including its source-qualification transport, its non-production test-mesh participants including the macOS Controller, the separation of that evidence from production BEAM eligibility and support, its prohibited transports, fallbacks, and replay, reconnect revalidation, and the exclusion of shared-cookie runs from evidence.
This requirement changes `SPEC.md` §10.6.

#### Scenario: Private-network session reconnects

- **WHEN** the selected Runtime Endpoint transport reconnects after interruption
- **THEN** current certificate, Node, admission, target, Peer Grant, and generation authority are revalidated before new work
- **AND** an ambiguously accepted inference operation is not automatically replayed

#### Scenario: Source qualification exercises the Runtime Endpoint

- **WHEN** candidate source qualification exercises Runtime Endpoint behavior
- **THEN** it uses Peer Grant-authorized TLS Distribution in the controlled model-free source-development test mesh
- **AND** the run neither joins production BEAM membership nor falls back to shared-cookie Distribution or gRPC compatibility

#### Scenario: Production Controller is proposed for the test mesh

- **WHEN** a Controller with production BEAM membership, production credentials, or production data is proposed as a test-mesh participant
- **THEN** it is not admitted to the source-qualification test mesh
- **AND** no run that included it counts as candidate evidence

#### Scenario: Node is reachable only through a relay

- **WHEN** the candidate Node is reachable from the Controller only through NAT traversal, a tunnel, or a relay
- **THEN** the topology is outside the candidate contract
- **AND** it produces no candidate trust or qualification evidence

### Requirement: Linux Node Candidate Stays Outside Production BEAM

The candidate SHALL remain outside the Mac-only production BEAM boundary in `SPEC.md` §7.5.0 and SHALL require the separately accepted amendment, release and trust profile, and owner decision in `SPEC.md` §§1.4 and 7.5.0 before any Linux Node production BEAM eligibility or support claim.
This contract SHALL NOT widen that boundary.
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

Linux Node platform qualification SHALL remain separate from every runtime-provider, acceleration, model, and workload qualification, as `SPEC.md` §1.4 requires, and any one-H100 pilot SHALL follow the separately gated single-tuple bounds in `SPEC.md` Milestone 9.
A successful candidate install, inventory check, or lifecycle test SHALL NOT qualify CUDA, ROCm, vLLM, a model, or a runtime-provider profile.
This requirement changes `SPEC.md` §§1.4 and Milestone 9.

#### Scenario: Candidate passes model-free qualification

- **WHEN** the candidate passes every provider-neutral gate on a host with an NVIDIA accelerator
- **THEN** Orchard records Linux Node platform evidence only
- **AND** no CUDA, vLLM, model, or runtime-provider support is claimed

### Requirement: Mixed-Platform Acceptance Includes The Linux Node And A Designated Predecessor

The `macos_controller_linux_node_model_free` acceptance profile SHALL satisfy the `N`/`N` and `N`/`N-1` pairing, non-production participant, model-free proof, independent host evidence, exact worker-unit and resource-allocation targeting, and exact earlier-distinct-Product-Version predecessor requirements in `SPEC.md` Milestone 9 and §13.1, and SHALL remain unmet until those targeting contracts are defined and their implementation is accepted.
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

This contract SHALL define only the standalone candidate Node in `SPEC.md` §1.4 and SHALL NOT define, authorize, or qualify a Linux Controller, a managed or local Postgres, or a composition that places a Controller, Postgres, and Node on one candidate host.
A coordinated single-host composition SHALL require its own accepted contract reconciled into `SPEC.md` before implementation.
This requirement changes `SPEC.md` §§1.4 and 11.

#### Scenario: Controller is started on the candidate host

- **WHEN** a Controller or database role runs on the candidate qualification host
- **THEN** the host is outside this candidate contract
- **AND** no candidate qualification or single-host composition evidence is recorded
