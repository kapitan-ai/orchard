# Linux Node candidate profiles

This document is the support matrix for the experimental Linux Node candidate
profiles. It is a qualification target, not a support claim. The accepted
`ubuntu_24_04_x86_64_node` contract remains unchanged. The separate
`ubuntu_26_04_x86_64_node` candidate is accepted in ADR 0036 and the
`add-ubuntu-26-04-linux-node-candidate` OpenSpec change. Its deterministic
packaging path is implemented, but real qualification remains incomplete.

## Host matrix

| Dimension | `ubuntu_24_04_x86_64_node` | `ubuntu_26_04_x86_64_node` | Not qualified |
| --- | --- | --- | --- |
| Status | Experimental accepted candidate; support gates remain profile-specific | Experimental accepted candidate with source packaging implemented; no real-host qualification or support claim | Any family or range inferred from these rows |
| Distribution | Ubuntu Server 24.04 LTS, `ID=ubuntu`, `VERSION_ID=24.04` | Ubuntu Server 26.04 LTS (Resolute Raccoon), `ID=ubuntu`, `VERSION_ID=26.04` | Other Ubuntu releases; Debian, RHEL-family, Fedora, SUSE, Arch, immutable/image-based systems |
| Architecture | x86_64 | x86_64; canonical amd64 Server image, not cloud-image-specific or amd64v3-only evidence | arm64, ppc64le, s390x, RISC-V |
| Kernel | Ubuntu 6.8 or newer kernel within the 24.04 hardware-enablement line | Ubuntu generic/server kernel 7.0 line; exact observed package and release recorded | custom kernels without required systemd/cgroup behavior, WSL kernels |
| libc | glibc 2.39 or newer within Ubuntu 24.04 | glibc 2.43 within Ubuntu 26.04; exact observed package recorded | musl and other libc implementations |
| Init and cgroups | systemd 255 or newer, system service manager, unified cgroup v2 | systemd 259 within Ubuntu 26.04, system service manager, unified cgroup v2; cgroup v1 is absent | OpenRC, SysV init, user services, cgroup v1, containers used as the Node host |
| Command baseline | Accepted 24.04 dependency closure including GNU coreutils | Release-specific closure; explicitly installed and invoked GNU implementation wherever Orchard relies on GNU semantics because Ubuntu defaults to uutils | Inferring semantics from command names or successful exit |
| Privilege | root package lifecycle; dedicated non-login `orchard-node` runtime identity | Same contract, independently qualified | rootless install, runtime sudo, shared interactive account |
| Filesystem | local POSIX filesystems with atomic rename, owner/mode enforcement, and sufficient durable space | Same contract plus qualification of `/tmp` as tmpfs by default | identity roots on NFS or filesystems that cannot enforce required ownership and atomic publication |
| Mandatory access control | Ubuntu's default AppArmor posture; package must not disable it | Ubuntu 26.04 AppArmor posture recorded and exercised; package must not disable it | custom enforcing policy is operator-owned until separately qualified |
| Network | operator-controlled private network; production BEAM TLS Distribution and certificate-authenticated gRPC control | Same private-network contract with Netplan/routing facts independently captured | Internet-exposed Node listeners, NAT traversal, tunnels, proxies, outbound-only sessions, automatic transport fallback |

Canonical identifies Ubuntu 26.04 LTS as Resolute Raccoon, publishes an official
amd64 Server image, and lists it in the LTS lifecycle. The release notes name
Linux 7.0, glibc 2.43, systemd 259, unified cgroup v2 only, `/tmp` tmpfs by
default, and uutils as the default core utilities. These sources establish the
candidate identity and risks, not Orchard support. The release was published on
2026-04-23; 26.04.1 is the current point release as of this amendment. Ubuntu's
release notes state support until April 2031, while its lifecycle table records
standard security maintenance through May 2031:

- <https://documentation.ubuntu.com/release-notes/26.04/>
- <https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/>
- <https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/>
- <https://ubuntu.com/about/release-cycle>
- <https://releases.ubuntu.com/26.04/>

## Owned layout

| Path | Ownership and purpose |
| --- | --- |
| `/opt/orchard/node` | root-owned immutable release payload selected by the active package receipt |
| `/etc/orchard/node` | root-owned configuration; service-readable only where required; no enrollment token |
| `/var/lib/orchard/node` | durable state and Node Identity Root; private key material is owner-only |
| `/var/log/orchard/node` | service logs subject to local rotation; secrets and request bodies are prohibited |
| `/run/orchard-node` | tmpfs runtime directory for lock, PID-observation, and local sockets; never durable authority |

The package owns only these names and its systemd unit. Default removal deletes
package-owned executable and service state while retaining identity, operator
configuration, logs, models, and diagnostic receipts. Purge is a distinct,
explicit destructive operation and is outside the first slice.

## Lifecycle and compatibility

The package installs one Node-only OTP release and one systemd system unit.
Identity survives service restart, host reboot, package upgrade, rollback, and
default removal/reinstall. A process lock plus systemd ownership rejects a
second Agent for the same identity root. Upgrade is sequential: cordon, prove
drain under the accepted KAP-18 contract, stop, replace atomically, start,
reconcile, verify, and only then uncordon. Uncertain survivors keep the Node
unschedulable.

Controller `N` to Node Agent `N` and `N-1` is a compatibility window, not shared
identity-root authority. Additive observations from an older Agent decode as
missing evidence. Any operation requiring Worker Unit, resource, incarnation,
residency, allocation, or control-generation targeting fails closed when either
side cannot preserve that target.

Air-gap media must contain the same immutable package bytes, package metadata,
checksums, runtime dependencies, and trust material used online for the selected
candidate. The package bundles its exact ERTS and OTP release runtime and does
not require host Erlang or Elixir. Every OS-supplied prerequisite has an
accepted version constraint in a candidate-specific machine-readable dependency
manifest; preflight fails before mutation when that closed dependency set or
required command implementation is incomplete. No install or runtime step may
require public network egress. Package publication, repository hosting, and
public support remain separate release decisions.

## Capability evidence

CPU, memory, disk, OS, kernel, network, and accelerator inventory are bounded,
redacted observations. Stable accelerator identity uses vendor UUID or another
vendor-documented immutable identifier; PCI address and device ordinal are
topology observations, not identity substitutes. NVIDIA/CUDA and AMD/ROCm
observations remain distinct. Missing vendor tooling means evidence is absent,
not that a device is healthy or free.

The additive inventory envelope is explicitly observation-only. Every host
section and accelerator provider records bounded provenance, observation time,
and an observed, absent, partial, or error state; raw command output is not
transported. Accelerator records without a vendor-stable identity are omitted.
Marketing names, ordinals, PCI/NUMA topology, visibility environment, driver
presence, and successful tool execution are not identity, health, readiness,
runtime qualification, effective Orchard binding, or allocation evidence.
Installed CUDA or ROCm tool/runtime versions carry their own provider-level
evidence and are never copied into a device binding; toolkit presence alone is
not proof that any observed device can execute it.

Inventory probes run under the package-declared GNU coreutils command guardian
with bounded output, a TERM deadline, and KILL escalation. Collection is
asynchronous and serves only the last complete snapshot, so absent or blocked
host tooling cannot delay Node startup, runtime status, or custody processes.

Inventory never creates schedulable capacity, a Worker Unit, a Resource
Allocation, runtime custody, or a Serving Profile qualification. The one-H100
vLLM candidate is gated on provider-neutral contracts and separately accepted
provider qualification.

## Qualification gates

Qualification requires all of the following independently for each exact
candidate artifact and dependency closure:

1. a verified signed canonical Server image and reproducible clean-host and
   air-gapped install with exact image, kernel, glibc, systemd, cgroup,
   filesystem, network, AppArmor, package, and command identities retained;
2. exact filesystem ownership and secret-permission checks;
3. single-Agent ownership across start, stop, restart, reboot, crash, upgrade,
   rollback, default removal, and reinstall;
4. persistent identity and fail-closed uncertain-survivor reconciliation;
5. deterministic provider-neutral CPU, NVIDIA, and AMD inventory fixtures plus
   real read-only accelerator evidence where matching hardware is available,
   without changing device configuration;
6. credential renewal/revocation and private-network reconnect behavior under
   the accepted transport contract;
7. redacted offline diagnostics and cleanup;
8. deterministic model-free custody and mixed-version tests aligned with
   KAP-18 and KAP-26; and
9. first-party release authenticity plus protected certificate and Peer Grant
   custody, trusted names, network restriction, and systemd/identity-root host
   controls before production BEAM admission; and
10. the `macos_controller_linux_node_model_free` profile run separately for the
    selected candidate with a qualified macOS Controller `N` and that Linux
    Node candidate at `N` and `N-1`, proving enrollment,
    admission, authenticated observation, exact unit/resource targeting,
    cancellation, drain, Agent restart, orphan handling, and peer isolation
    from independently captured evidence on both hosts. Evidence for one Linux
    candidate does not qualify another; unavailable direct private routing or
    macOS host evidence leaves that candidate's gate unmet.

For 26.04 specifically, the real systemd-capable matrix must also prove systemd
259 and cgroup-v2 survivor/orphan cleanup, `/tmp` tmpfs implications, explicit
GNU command provenance, Netplan/private-network behavior, and exact release
dependency closure. Static tests and a successful boot do not satisfy these
gates.

Until every applicable gate passes, documentation and diagnostics must call the
profile experimental and must not claim blanket Linux, CUDA, ROCm, vLLM, or
model support.
