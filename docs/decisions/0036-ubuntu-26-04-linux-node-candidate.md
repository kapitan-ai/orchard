# ADR: Ubuntu 26.04 is a separate Linux Node candidate

## Status

Accepted by the accountable owner on 2026-09-20 under KAP-77, KAP-78, and
KAP-84 from contract commit `d8e469985c1597f3fb3cd4bf1859aa359a8260ea`.

This record does not establish Ubuntu 26.04 or general Linux support.

## Context

ADR 0034 accepted `ubuntu_24_04_x86_64_node` as a closed experimental
candidate. Its package, lifecycle, inventory, and credential evidence is tied
to Ubuntu 24.04 and cannot be generalized to a later Ubuntu release.

Canonical identifies Ubuntu 26.04 LTS as Resolute Raccoon, publishes an official
amd64 Server image, and lists the release in its LTS lifecycle. Canonical's
release notes identify Linux 7.0, glibc 2.43, systemd 259, removal of cgroup v1,
`/tmp` mounted as tmpfs by default, and uutils as the default core utilities.
These changes directly affect Orchard's host preflight, command guardian,
systemd/cgroup lifecycle, filesystem assumptions, and qualification evidence.
The release was published on 2026-04-23 and 26.04.1 is the current point release
as of this decision. The release notes say support continues until April 2031;
Canonical's lifecycle table lists standard security maintenance through May
2031. Both establish current LTS status without changing Orchard's independent
qualification requirement.

Authoritative sources:

- <https://documentation.ubuntu.com/release-notes/26.04/>
- <https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/>
- <https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/>
- <https://ubuntu.com/about/release-cycle>
- <https://releases.ubuntu.com/26.04/>

## Decision

Retain `ubuntu_24_04_x86_64_node` unchanged. Add
`ubuntu_26_04_x86_64_node` only as a separate experimental candidate requiring
Ubuntu Server `ID=ubuntu`, `VERSION_ID=26.04`, x86_64, the Ubuntu 26.04
generic/server kernel 7.0 line, glibc 2.43 within that release, systemd 259
within that release, and unified cgroup v2.

This is an enumerated closed set, not “Ubuntu 24.04 or newer.” Other Ubuntu
releases, cloud-image-specific package variants, amd64v3-only variants,
architectures, distributions, libc implementations, init systems,
containers-as-hosts, WSL, and rootless installation remain unqualified.

The two candidates may share the Node-only Debian artifact design and, after
proof, may share payload bytes. They do not share host dependency assumptions.
Each candidate requires an accepted machine-readable dependency closure,
fail-closed preflight, online/offline parity, and real systemd-capable lifecycle
evidence. On 26.04, behavior that relies on GNU coreutils semantics must install
and invoke the accepted GNU implementation explicitly rather than infer it from
the default command name or command success.

The 26.04 qualification must record the exact signed Server image, kernel,
glibc, systemd, cgroup, AppArmor, Netplan, filesystem, package, and command
implementation identities. It must prove clean and offline install,
default-off state, fixed permissions and credential custody, symlink refusal,
exclusive identity-root ownership, explicit lifecycle and reboot behavior,
upgrade/rollback/removal/reinstall, cgroup-v2 survivor and orphan cleanup,
private-network KAP-82 behavior, redacted diagnostics, and provider-neutral
inventory. Static tests and successful boot are insufficient.

`macos_controller_linux_node_model_free` runs independently for each candidate
with macOS Controller `N` and that candidate's Node Agent at `N` and `N-1`.
Evidence for one candidate cannot qualify the other. Direct private-network
unavailability remains an unmet KAP-84 gate and must not be replaced by NAT,
tunnels, proxies, outbound sessions, or single-host simulation.

Accelerator observations remain non-authoritative and separately evidenced
where hardware exists. They do not establish CUDA, ROCm, provider, model,
scheduling, placement, capacity, allocation, or production support. KAP-18,
KAP-26, and KAP-82 retain their accepted ownership boundaries.

## Consequences

Source implementation may add the separate 26.04 dependency manifest,
preflight path, explicit GNU command selection, and deterministic tests without
weakening the accepted 24.04 checks. Real 26.04 lifecycle evidence remains
required before mixed-host qualification or any support claim.

The additional matrix costs qualification time but prevents a support claim
from resting on distro-family inference. Ubuntu point updates are eligible only
within the selected release and require receipts for the exact image and package
versions exercised; material baseline changes require focused requalification.

## SPEC.md impact

Update §§1.4, 4.1, 11, and 14 to enumerate the accepted 26.04 candidate and
make package, lifecycle, and mixed-host qualification candidate-specific.
