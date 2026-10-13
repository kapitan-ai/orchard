## 1. Contract

- [x] 1.1 Verify Ubuntu 26.04 identity, LTS status, amd64 Server image, and material platform deltas from authoritative Canonical sources.
- [x] 1.2 Inventory accepted 24.04 profile constraints in `SPEC.md`, OpenSpec, ADRs, documentation, and implementation.
- [x] 1.3 Propose ADR 0036 and reconcile `SPEC.md` and the Linux Node support matrix without claiming support.
- [x] 1.4 Strict-validate this OpenSpec change and the complete OpenSpec tree.
- [x] 1.5 Obtain explicit owner acceptance before implementation or qualification.

## 2. Candidate implementation

- [x] 2.1 Add a release-specific 26.04 dependency manifest and fail-closed preflight while preserving the 24.04 path.
- [x] 2.2 Add deterministic package tests for exact profile selection, dependency closure, uutils/GNU command provenance, malformed identity, and unsupported versions.
- [ ] 2.3 Build the exact Node-only package using the repository-pinned toolchain and retain byte, version, dependency, and provenance receipts.

## 3. Real Ubuntu 26.04 qualification

- [ ] 3.1 Verify a signed canonical amd64 Server image and record exact image, kernel, glibc, systemd, cgroup, AppArmor, Netplan, filesystem, and package identities.
- [ ] 3.2 Prove clean and offline install, default-off behavior, fixed paths, dedicated identity, permissions, secret custody, symlink refusal, and exclusive identity-root ownership.
- [ ] 3.3 Prove start, stop, restart, bounded termination, crash recovery, reboot, upgrade, rollback, removal, reinstall, retained state, and cgroup-v2 survivor/orphan cleanup.
- [ ] 3.4 Prove private-network KAP-82 credential and Peer Grant lifecycle without NAT, tunnels, proxies, or outbound-session substitution.
- [ ] 3.5 Verify provider-neutral host inventory and, only where hardware exists, stable accelerator observations without allocation or provider authority.
- [ ] 3.6 Verify redacted offline diagnostics and cleanup receipts.

## 4. Mixed-host qualification

- [ ] 4.1 Run `macos_controller_linux_node_model_free` independently for the 26.04 candidate at Node Agent `N` and `N-1` with evidence from both hosts.
- [ ] 4.2 Preserve KAP-18 and KAP-26 ownership boundaries for cancellation, drain, native cessation, request-slot release, allocation release, and runtime incarnation.
- [ ] 4.3 Record unsupported version behavior and confirm an old participant fails closed when it cannot preserve complete targeting or authority generations.

## 5. Validation and review

- [ ] 5.1 Run package, lifecycle, security, conformance, portable, and relevant full regression gates after implementation.
- [ ] 5.2 Obtain independent implementation and qualification review and resolve findings.
- [ ] 5.3 After acceptance and sync/archive, inspect generated main specs and remove placeholder prose such as `Purpose TBD`.
