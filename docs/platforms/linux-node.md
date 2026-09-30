# Linux Node candidate profile

This document summarizes the experimental `ubuntu_24_04_x86_64_node` Linux Node candidate.
It is a proposed qualification target, not a support claim.
The normative boundaries are [`SPEC.md`](../../SPEC.md) §1.4 and Milestone 9, [ADR 0035](../decisions/0035-experimental-linux-node-source-development.md), and the `reconcile-linux-node-source-dev-contract` OpenSpec change.
The Apple Silicon macOS platform profile remains the only supported platform profile.

## Host matrix

| Dimension | Candidate | Not qualified by this profile |
| --- | --- | --- |
| Distribution | Ubuntu Server 24.04 LTS | Ubuntu 26.04 LTS, every other Ubuntu release, Debian, RHEL-family, Fedora, SUSE, Arch, immutable or image-based systems |
| Architecture | x86_64 | arm64, ppc64le, s390x, RISC-V |
| Kernel | 6.8 or newer from an Ubuntu 24.04 kernel line | custom kernels without the required systemd or cgroup behavior, WSL kernels |
| libc | glibc 2.39 or newer within Ubuntu 24.04 | musl and other libc implementations |
| Init and cgroups | systemd 255 or newer as the system service manager, unified cgroup v2 | OpenRC, SysV init, user service managers, cgroup v1, containers used as the Node host |
| Privilege | dedicated unprivileged non-login Agent identity | root, sudo, or a shared interactive account |
| Filesystem | local POSIX filesystem with ownership, mode, and atomic rename enforcement for the Node Identity Root | network filesystems or filesystems that cannot enforce ownership and atomic publication |
| Network | operator-controlled private network with production BEAM TLS Distribution and certificate-authenticated gRPC control | Internet-exposed Node listeners, NAT traversal, tunnels or relays, outbound-only sessions, automatic transport fallback |
| Roles on the host | Node Agent and its Worker Runtimes only | Controller, Console, or database roles on the candidate host |

## Installation path

The candidate's current installation path is source development of the Node-only role from an exact source revision with the pinned toolchain in `mise.toml`.
No Debian package, other package, container image, or other deployment artifact is defined.
A future Linux Node package, fixed filesystem layout, package-created service identity, package-owned unit, closed dependency manifest, or air-gapped media requires a fresh accepted OpenSpec proposal, a separate implementing pull request, and owner approval.
The Distribution Pause in `SPEC.md` §11.0 is unaffected.
Making the Node-only source path operable on a candidate host is future implementation work, and [`local-dev.md`](../local-dev.md) does not yet describe it.

## Evidence binding

Every qualification record binds to the exact source commit and tree, clean-checkout proof, dependency locks, pinned toolchain identity, and passing generated-output drift checks.
A dirty, unidentified, or drifted checkout produces implementation evidence only.
This binding is not a host-wide install rule and does not constrain developer worktrees, macOS hosts, or other Nodes.

## Identity and lifecycle

Each Node Agent holds a process-lifetime exclusive owner-only lock in its Node Identity Root and rejects a second owner before enrollment, Runtime Endpoint activation, or Worker Runtime startup.
For qualification, one systemd system unit supervises exactly one Agent and its Worker Runtime descendants, and the qualification host runs exactly one supervised candidate Agent.
A foreground developer session produces implementation evidence only.
Unit, cgroup, PID, heartbeat, and runtime-directory facts are observations and never prove custody, release, or scheduling authority.
Source upgrade and rollback follow cordon, accepted drain, stop, switch to another exact clean revision, start, reconcile, verify, and uncordon, and uncertain survivors keep the Node unschedulable.

## Compatibility

Controller `N` to Node Agent `N` and `N-1` is a reader and behavior compatibility window, not shared Node Identity Root authority.
Additive observations from an older Agent decode as missing evidence.
Operations that depend on worker-unit, resource-allocation, runtime-incarnation, residency, or control-generation targeting fail closed when either side cannot preserve the full target.

## Capability evidence

CPU, memory, disk, OS, kernel, network, and accelerator inventory are bounded, redacted observations.
Stable accelerator identity uses a vendor-documented immutable identifier, and PCI address and device ordinal are topology observations only.
NVIDIA/CUDA and AMD/ROCm observations remain distinct.
Missing vendor tooling means evidence is absent, not that a device is healthy or free.
Inventory never creates schedulable capacity, allocation, device binding, runtime custody, or a runtime-provider qualification.

## Qualification gates

Support requires every applicable gate on an exact clean source revision:

1. closed-matrix preflight that fails before mutation on unqualified hosts;
2. Node Identity Root ownership and secret-permission checks;
3. single-Agent ownership across start, stop, restart, crash, reboot, source upgrade, and source rollback;
4. provider-neutral inventory accuracy on representative CPU-only, NVIDIA, and AMD hosts without changing device configuration;
5. credential renewal and revocation, Peer Grant rotation, and private-network reconnect under the accepted transport contract, excluding shared-cookie runs;
6. redacted diagnostics through retained generic surfaces;
7. model-free custody and mixed-version tests after the required release and targeting contracts are accepted;
8. first-party release authenticity plus protected credential custody, trusted names, network restriction, and host controls before production BEAM admission; and
9. the `macos_controller_linux_node_model_free` profile for both `N`/`N` and `N`/`N-1`, where `N-1` is an exact governed predecessor revision and missing predecessor or macOS host evidence leaves the gate unmet.

Runtime-provider work, such as CUDA, ROCm, or vLLM, needs its own separately authorized qualification of one exact hardware, provider, model, and profile tuple.
Until every applicable gate passes, documentation and diagnostics call the profile experimental and do not claim Linux Node, distribution, CUDA, ROCm, vLLM, or model support.
