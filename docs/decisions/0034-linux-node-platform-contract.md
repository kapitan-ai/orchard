# ADR: Linux Nodes use the portable Node Agent under a qualified host profile

## Status

Accepted by the accountable owner on 2026-09-19 under KAP-77 and KAP-78.

This record does not establish support. Implementation and qualification remain
gated by the associated OpenSpec change and the acceptance profile described
below.

## Context

ADR 0023 made the Node Agent part of the portable Orchard control-plane core but
deferred Linux Node lifecycle, packaging, accelerator discovery, and host
management. Portable Linux CI proves dependency hygiene; it does not define an
installable Node or make one schedulable.

The first Linux Node slice needs one reviewable host contract. Broad claims such
as “Linux”, “CUDA”, or “vLLM” would combine unrelated distribution, lifecycle,
resource, and provider qualifications and would weaken Orchard's fail-closed
authority boundaries.

KAP-27 also records that outbound-only Runtime Endpoint sessions are outside the
current private-network product boundary. A Linux Node therefore cannot invent a
second reconnect or trust protocol.

## Decision

Define `ubuntu_24_04_x86_64_node` as an experimental platform and distribution
profile candidate. Its initial host baseline is Ubuntu Server 24.04 LTS on
x86_64, Linux kernel 6.8 or newer within the Ubuntu 24.04 hardware-enablement
line, glibc 2.39 or newer within that release, systemd 255 or newer, and unified
cgroup v2. Other distributions, architectures, libc implementations, init
systems, containers-as-hosts, WSL, and rootless installation remain unqualified.

The artifact is a versioned Node-only Debian package. Installation and package
mutation require root. The Node Agent runs as a dedicated non-login
`orchard-node` account and group with no sudo, shell, database credentials, or
accelerator reconfiguration authority. The package owns executable bytes under
`/opt/orchard/node`, root-owned configuration under `/etc/orchard/node`, durable
identity and state under `/var/lib/orchard/node`, logs under
`/var/log/orchard/node`, and runtime-only files under `/run/orchard-node`.
Package scripts must support a relocated root for unprivileged lifecycle tests.
The package bundles the exact ERTS and OTP release runtime; a host Erlang or
Elixir installation is not a prerequisite. Every remaining host dependency is
declared with an accepted version constraint in a machine-readable package
dependency manifest, and air-gap media contains that same closed dependency set.

One systemd system service owns exactly one Node Agent for the identity root.
systemd starts, stops, and restarts the Agent as one cgroup and kills remaining
children when the unit stops. A persistent owner-only lock in the identity root
prevents a second Agent from adopting that root. Restart never converts stale
process, heartbeat, PID, or device evidence into current custody or scheduling
authority.

Linux Nodes use the accepted private-network Runtime Endpoint model: production
BEAM TLS Distribution plus the scoped Peer Grant contract, with
certificate-authenticated gRPC retained for enrollment, credential lifecycle,
grant recovery, diagnostics, and explicit compatibility. No outbound-only
session, public Node listener, automatic transport fallback, or operation replay
is added.
Because distributed Erlang is a high-trust code boundary, the candidate cannot
join production BEAM until the exact immutable package proves first-party
release authenticity, certificate and Peer Grant custody, trusted names,
network restriction, host controls, and the named mixed-platform acceptance
profile. This gate extends ADR 0012's evidence standard without declaring the
candidate accepted or supported.

Host inventory is provider-neutral observation. Stable accelerator identities
come from vendor-observed immutable identifiers where available, with NVIDIA and
AMD evidence represented separately. Discovery neither creates a Resource
Allocation nor authorizes scheduling, device binding, reset, or runtime startup.

Controller `N` may operate Node Agent `N` and `N-1` only where the wire and
behavior contract is compatible. New readers must accept additive old
observations as non-authoritative missing evidence. Old readers or writers that
cannot preserve required Worker Unit, resource-allocation, incarnation, or
generation targeting must fail closed rather than issue a Node/model-ambiguous
operation.

Linux platform qualification remains separate from every runtime-provider
profile. A successful Linux install or inventory check does not qualify CUDA,
ROCm, vLLM, a model, or a Serving Profile.

Define `macos_controller_linux_node_model_free` as the first mixed-platform
acceptance topology for this candidate. A qualified macOS Controller at version
`N` operates the Linux Node candidate at `N` and `N-1` through model-free
fixtures. Enrollment, admission, authenticated observation, exact unit/resource
targeting, cancellation, drain, Agent restart, orphan handling, and peer
isolation require evidence captured independently on both hosts. Missing macOS
host evidence leaves this gate unmet rather than being simulated on Linux.

## Consequences

The first implementation can test package layout, service ownership, persistent
identity, inventory, and diagnostics without activating scheduling or a real
runtime provider. Rootless relocated-root tests provide deterministic evidence,
while real systemd, reboot, upgrade, rollback, and removal evidence still
require a separately authorized disposable or dedicated host exercise.

Ubuntu minor releases may advance the kernel and glibc within the declared
line, but another distribution or architecture requires its own qualification
evidence and an explicit contract update. Accelerator vendor stacks remain
optional observations until a separately accepted runtime-provider profile uses
them.

KAP-18 and KAP-26 remain authoritative for terminal ownership, native cessation,
request-slot release, Resource Allocation release, Worker Unit identity, and
generation fencing. This profile does not fill their unresolved semantics with
Linux process observations.

## SPEC.md impact

Update §§1.4, 4.1, 4.9, 10.6, 11, 13.4, and 14 to define the experimental Linux
Node profile and its qualification boundary without declaring support.
