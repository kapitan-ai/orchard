## Why

Ubuntu 26.04 LTS is now Canonical's current LTS release, but Orchard's accepted
Linux Node contract names only Ubuntu Server 24.04. Treating 26.04 as compatible
because it is newer would bypass the closed-profile rule and miss material host
changes, including systemd 259 with cgroup v1 removed and uutils replacing GNU
coreutils by default.

This is a contract-first profile amendment. It does not infer support from the
host booting, static validation, Ubuntu family identity, or KAP-84 network
preflight results.

## What Changes

- Retain `ubuntu_24_04_x86_64_node` unchanged and propose the separate
  `ubuntu_26_04_x86_64_node` experimental candidate.
- Bind the new candidate to Ubuntu Server `VERSION_ID=26.04`, x86_64, the
  Ubuntu 26.04 generic/server kernel 7.0 line, glibc 2.43, systemd 259, and
  unified cgroup v2.
- Require a release-specific package dependency manifest and preflight,
  including explicit GNU coreutils custody where package or runtime behavior
  depends on GNU semantics.
- Require package, systemd, permissions, custody, networking, process cleanup,
  observation-only inventory, and mixed-host evidence independently for 26.04.
- Run `macos_controller_linux_node_model_free` at `N` and `N-1` separately for
  each enumerated Linux Node candidate; evidence for one candidate cannot
  qualify the other.
- Keep implementation, runtime qualification, and support claims blocked on
  owner acceptance and real candidate evidence.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `linux-node-platform`: Adds one separately bounded Ubuntu 26.04 candidate and
  its real-host qualification gates.
- `platform-profiles`: Enumerates two Linux Node candidates without creating a
  generic Ubuntu or Linux profile.
- `packaging-deployment`: Requires per-candidate dependency closure, preflight,
  and lifecycle qualification for the shared Node-only package design.

## Impact

- `SPEC.md` §§1.4, 4.1, 11, and 14 enumerate the proposed candidate and make
  Linux Node and KAP-84 evidence candidate-specific.
- ADR 0036 records the accepted closed profile and its acceptance boundary;
  accepted ADR 0034 remains historical and unchanged.
- `docs/platforms/linux-node.md` records the two-candidate matrix and the
  evidence still missing for 26.04.
- The accepted implementation uses candidate-specific manifests and preflights
  under `packaging/linux/node/profiles/`, explicit profile selection in
  `scripts/build-linux-node-package.sh`, and deterministic coverage in
  `scripts/test-linux-node-package.sh`.
- No general Ubuntu/Linux support, package publication, provider/model support,
  scheduling authority, deployment, or production claim follows.
