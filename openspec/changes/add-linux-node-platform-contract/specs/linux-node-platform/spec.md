## ADDED Requirements

### Requirement: Linux Node Candidate Has A Closed Host Matrix

Orchard SHALL define `ubuntu_24_04_x86_64_node` as an experimental candidate
that requires Ubuntu Server 24.04 LTS on x86_64, Linux kernel 6.8 or newer within
the Ubuntu 24.04 hardware-enablement line, glibc 2.39 or newer within that
release, systemd 255 or newer, and unified cgroup v2.
Other distributions, architectures, libc implementations, init systems,
containers-as-hosts, WSL, and rootless installation SHALL remain unqualified.
Defining or implementing the candidate SHALL NOT establish Linux support.

#### Scenario: Unsupported host requests installation

- **WHEN** preflight observes a host outside the closed candidate matrix
- **THEN** installation fails before system or identity mutation
- **AND** diagnostics identify the unsupported dimension without claiming support

### Requirement: Linux Package And Agent Have Separate Privilege

The candidate SHALL use a Node-only Debian artifact whose system lifecycle
requires root and whose Agent runs as a dedicated non-login `orchard-node`
identity without sudo, package mutation, database credentials, or device
reconfiguration authority.
The package SHALL own `/opt/orchard/node`, `/etc/orchard/node`,
`/var/lib/orchard/node`, `/var/log/orchard/node`, `/run/orchard-node`, and its
systemd unit according to the accepted path contract.
Lifecycle tests SHALL support a relocated root that changes every owned path and
simulates systemd effects without mutating the host.

#### Scenario: Relocated-root installation runs without root

- **WHEN** the package lifecycle targets an authorized temporary root
- **THEN** all package paths and service effects remain inside that root or its simulation
- **AND** the real host installation and systemd manager remain unchanged

### Requirement: One Agent Exclusively Owns One Identity Root

One systemd system service SHALL supervise exactly one Node Agent for one Node
Identity Root. The Agent SHALL hold a process-lifetime exclusive owner-only lock
in the durable identity root and SHALL reject a second owner.
systemd process, cgroup, PID, heartbeat, and runtime-directory evidence SHALL
remain observations and SHALL NOT create current custody, dispatch authority,
or capacity release.

#### Scenario: Duplicate Agent starts for the same identity

- **WHEN** another Agent already holds the identity-root ownership lock
- **THEN** the new Agent fails before enrollment, Runtime Endpoint activation, or worker startup
- **AND** it does not adopt the existing process or identity from PID evidence

### Requirement: Linux Connectivity Uses Existing Private-Network Contracts

The candidate SHALL use production BEAM TLS Distribution with accepted Peer
Grant authorization and certificate-authenticated gRPC for enrollment,
credential lifecycle, grant recovery, diagnostics, and explicit compatibility.
It SHALL NOT add outbound-only sessions, Internet-exposed Node listeners,
automatic transport fallback, or ambiguous inference-operation replay.

#### Scenario: Private-network session reconnects

- **WHEN** the selected Runtime Endpoint transport reconnects after interruption
- **THEN** current certificate, Node, admission, target, grant, and generation authority are revalidated
- **AND** an ambiguously accepted inference operation is not automatically replayed

### Requirement: Production BEAM Requires Linux Release And Host Evidence

The Linux Node candidate SHALL NOT join production BEAM until its exact
immutable package proves first-party release authenticity, protected certificate
and Peer Grant custody, trusted names, restricted networking, systemd and
identity-root host controls, and the
`macos_controller_linux_node_model_free` acceptance profile.
Portable compilation, local package installation, a successful transport probe,
or certificate identity alone SHALL NOT satisfy this gate.

#### Scenario: Unsigned local package requests production BEAM

- **WHEN** a locally assembled candidate lacks accepted first-party release evidence
- **THEN** production BEAM admission fails closed before distribution membership
- **AND** local package or transport evidence does not substitute for authenticity

### Requirement: Linux Inventory Is Observation Only

The Linux capability provider SHALL report bounded CPU, memory, disk, OS,
kernel, network, and optional accelerator observations through provider-neutral
contracts. Accelerator identity SHALL prefer vendor-documented stable identity;
PCI address and device ordinal SHALL remain topology observations.
NVIDIA/CUDA and AMD/ROCm evidence SHALL retain distinct provenance and
qualification. Inventory SHALL NOT create a Worker Unit, Resource Allocation,
schedulable capacity, device binding, reset authority, or runtime custody.
Each bounded section and vendor provider SHALL report source, observation time,
and an observed, absent, partial, or error state without transporting raw tool
output. A device record SHALL require a vendor-stable identifier; marketing
name, device ordinal, PCI address, driver presence, container visibility, and
successful command exit SHALL NOT substitute for stable identity or establish
health, readiness, effective binding, provider support, or allocation authority.
Installed CUDA or ROCm tool/runtime evidence SHALL retain its own source and
state at provider level and SHALL NOT be represented as a device binding or
runtime-provider qualification.

#### Scenario: Stable accelerator is observed

- **WHEN** the capability provider obtains a valid vendor-stable accelerator identifier
- **THEN** it reports the bounded device observation and evidence provenance
- **AND** no scheduler or runtime authority is created from that observation

#### Scenario: Vendor evidence is incomplete

- **WHEN** vendor tooling is missing, permission-denied, malformed, duplicated, or only partially usable
- **THEN** the provider reports absent, error, or partial evidence with a bounded reason
- **AND** it does not invent a device identity, health state, runtime support, or capacity

#### Scenario: Host inventory is observed repeatedly

- **WHEN** two valid observations describe the same unchanged accelerator
- **THEN** its vendor-stable identifier remains equal while ordinal, PCI, NUMA, and visibility data remain topology observations
- **AND** each envelope carries its own observation time and observation-only authority

### Requirement: Linux Targeting Fails Closed Across Version Skew

Controller `N` MAY interoperate with Node Agent `N` and `N-1` only where the
negotiated wire and behavior contract preserves the requested operation.
Missing additive observation fields SHALL decode as absent evidence.
An operation requiring Worker Unit, Resource Allocation, incarnation,
residency, allocation, or control-generation targeting SHALL be rejected when
either participant cannot preserve the complete target and SHALL NOT downgrade
to ambiguous Node/model targeting.

#### Scenario: Older receiver lacks generation targeting

- **WHEN** a writer requests a resource-bound operation and the receiver cannot preserve its required generations
- **THEN** the receiver rejects the operation with a stable compatibility failure
- **AND** no Node/model-ambiguous mutation is attempted

### Requirement: Mixed-Platform Acceptance Includes The Linux Node

The `macos_controller_linux_node_model_free` acceptance profile SHALL pair a
qualified macOS Controller `N` with Linux Node candidate versions `N` and `N-1`.
It SHALL prove enrollment, admission, authenticated observation, exact
unit/resource targeting, cancellation, drain, Agent restart, orphan handling,
and peer isolation with model-free fixtures and independently captured evidence
from every participating host.
Unavailable macOS host evidence SHALL leave the profile unmet.

#### Scenario: Only Linux-host evidence is available

- **WHEN** candidate behavior is exercised on Linux without controlled macOS Controller evidence
- **THEN** local Linux results may be retained as candidate evidence
- **AND** mixed-platform acceptance remains unmet
