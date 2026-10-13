## Context

The accepted KAP-78 contract and ADR 0034 intentionally closed the first Linux
Node tuple at Ubuntu Server 24.04 LTS on x86_64. KAP-79 qualified that package
and systemd lifecycle on 24.04, KAP-80 captured provider-neutral host evidence,
and KAP-82 retained private-network credential and Peer Grant boundaries. None
of that evidence establishes behavior on a later Ubuntu release.

Canonical identifies Ubuntu 26.04 LTS as Resolute Raccoon and publishes an
official amd64 Server image. Its release notes identify Linux 7.0, glibc 2.43,
systemd 259, and removal of cgroup v1. Ubuntu 26.04 also defaults to uutils for
core utilities while Orchard's current Linux package declares GNU coreutils for
bounded inventory command supervision. These are profile-significant changes,
not an additive point-release assumption.

## Goals / Non-Goals

**Goals:**

- Add one exact Ubuntu 26.04 x86_64 candidate without changing 24.04.
- Preserve release-specific dependency closure and fail-closed preflight.
- Require independent lifecycle and mixed-host qualification per candidate.
- Keep host and accelerator discovery non-authoritative.

**Non-Goals:**

- Generic Ubuntu, future Ubuntu, Debian-family, cloud-image, amd64v3, arm64,
  non-systemd, container-host, WSL, or rootless support.
- Reusing 24.04 evidence as 26.04 evidence.
- Provider, model, scheduling, placement, capacity, or production activation.
- NAT, tunnels, proxies, outbound sessions, or a new Runtime Endpoint transport.
- Resolving KAP-18 or KAP-26 ownership and release semantics.

## Decisions

### Enumerate candidates rather than widen a version range

The candidate set is exactly `ubuntu_24_04_x86_64_node` and the proposed
`ubuntu_26_04_x86_64_node`. The new tuple requires `ID=ubuntu`,
`VERSION_ID=26.04`, x86_64, the Ubuntu generic/server kernel 7.0 line, glibc
2.43 within the 26.04 release, systemd 259 within the release, and unified
cgroup v2.

The candidate may include supported 26.04 point updates only after evidence
records the exact signed image, kernel, libc, systemd, cgroup, and package
versions exercised. A material baseline change triggers requalification. A
cloud image or amd64v3 package set is not covered by Server-image evidence.

Using “Ubuntu 24.04 or newer” was rejected because it silently includes
unreviewed releases. Replacing 24.04 was rejected because its accepted profile
and retained evidence remain valid independently.

### Share package design, not dependency assumptions

Both candidates use the Node-only Debian artifact design, fixed FHS paths,
dedicated non-login identity, systemd system service, bundled ERTS/OTP, and
retained-state contract. Each candidate needs an exact machine-readable host
dependency closure and preflight before installation.

Ubuntu 26.04's default command names may resolve to uutils. Any package,
inventory guardian, lifecycle, or diagnostic behavior that relies on GNU
semantics must install and invoke the accepted GNU implementation explicitly;
command presence or a nominal coreutils version is insufficient. The later
implementation must decide and test the concrete package and command paths from
the canonical 26.04 archive rather than changing the 24.04 manifest in place.

### Qualification is real and candidate-specific

Static checks and a successful boot establish neither lifecycle behavior nor
support. The 26.04 candidate requires a signed canonical Server image and real
systemd-capable evidence for clean and offline installation, default-off state,
start/stop/restart/crash/reboot, upgrade/rollback, removal/reinstall, retained
identity/configuration, fixed permissions, symlink refusal, exclusive identity
ownership, cgroup-v2 survivor/orphan cleanup, and resource cleanup after each
destructive edge.

Qualification also records AppArmor behavior, `/tmp` tmpfs implications,
Netplan/private-network routing, systemd 259 service semantics, and exact
command implementation provenance. KAP-82 certificate and Peer Grant behavior
must pass over a Controller-routable private network without substituting NAT,
tunnels, proxies, or outbound-session semantics.

Provider-neutral host inventory must report exact observed host facts.
Accelerator observation is exercised only where matching hardware is available
and remains distinct from CUDA, ROCm, runtime-provider, allocation, scheduling,
or readiness authority.

### KAP-84 runs per candidate

For each candidate independently, a qualified macOS Controller `N` operates
Linux Node Agent `N` and `N-1` with independently captured evidence from both
hosts. The existing model-free enrollment, admission, authenticated
observation, targeting, cancellation, drain, restart, orphan, peer-isolation,
and fail-closed version-skew scenarios remain unchanged. A pass on 24.04 does
not qualify 26.04, and a direct-routing blocker remains an unmet cross-host gate.

## Risks / Trade-offs

- **The matrix doubles.** This is intentional: distribution lifecycle evidence
  is not portable across release boundaries.
- **Point updates drift.** Receipts record exact image and package identities;
  material deltas require focused requalification.
- **GNU/uutils behavior is confused.** Dependencies and command paths are
  explicit, and tests distinguish semantics rather than trusting command names.
- **Ubuntu's accelerator packages imply support.** Inventory and package
  presence remain observations only; provider qualification stays separate.

## Migration Plan

After owner acceptance, implementation adds a separate 26.04 dependency
manifest/preflight path and deterministic fixtures without weakening 24.04
checks. Real 26.04 lifecycle qualification then precedes KAP-84 mixed-host
qualification. The candidate remains experimental until every applicable
real-host gate passes.

Rollback removes the accepted 26.04 contract and later unactivated
implementation without changing the accepted 24.04 profile or retained Node
identity.

## Qualification Inputs

The exact canonical 26.04 image digest and archive package versions are
qualification inputs. They must be captured from the real qualification
environment rather than inferred from this design.
