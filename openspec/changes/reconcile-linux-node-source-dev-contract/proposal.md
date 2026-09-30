## Why

Orchard's portable Node Agent compiles and tests on Linux, but `SPEC.md` still defers every Linux Node platform, lifecycle, inventory, trust, and qualification decision.
An earlier package-first Linux Node candidate contract was accepted in review but never merged, and it assumed a Debian artifact, a fixed package filesystem layout, and package-owned lifecycle that conflict with the current source-development installation path and with the §11 rule that any new distribution channel needs a fresh proposal.
This change proposes a bounded reconciliation of that contract onto current `main` so that later Linux Node implementation slices have one reviewable, source-development-first contract that makes no support claim.

The earlier acceptance applies only to its own revision.
It does not accept the wording in this change, which remains proposed and pending accountable owner review.

## What Changes

- Reserve `ubuntu_24_04_x86_64_node` as an experimental Linux Node platform profile candidate with a closed host matrix: Ubuntu Server 24.04 LTS on x86_64, kernel 6.8 or newer within the Ubuntu 24.04 hardware-enablement line, glibc 2.39 or newer within that release, systemd 255 or newer, and unified cgroup v2.
  Ubuntu 26.04 LTS, rootless installation, and every other host variant remain unqualified.
- Make source development of the Node-only role from an exact clean source revision with the pinned toolchain the candidate's proposed target path, which is not yet operable.
  No Debian package, other package, container image, or other deployment artifact is defined, and any future Linux Node package requires a fresh accepted proposal, a separate implementing pull request, and owner approval.
- Bind every candidate qualification record to the exact source commit and tree, clean-checkout proof, dependency locks, pinned toolchain identity, and passing generated-output drift checks, without imposing a host-wide canonical checkout rule on developer worktrees, macOS hosts, or other Nodes.
- Require exclusive Node Identity Root ownership, a least-privilege Agent identity, and one systemd-supervised Agent per Node Identity Root for qualification, while keeping service-manager, process, and cgroup facts as observations that create no custody, release, or scheduling authority.
- Keep the accepted private-network certificate and Peer Grant model as the only connectivity model, with no new transport, shared-cookie substitute, gRPC compatibility default, outbound-only session, tunnel, NAT traversal, public listener, automatic fallback, or replay.
  Source qualification uses certificate-authenticated control plus Peer Grant-authorized TLS Distribution in a controlled model-free source-development test mesh outside production BEAM membership.
- Keep the production BEAM boundary Mac-only and unchanged, keep the candidate outside it, and state that production eligibility or support needs a future separately accepted release and trust profile, reverification, and an owner decision.
- Define provider-neutral host and accelerator inventory as observation only, with distinct NVIDIA and AMD provenance.
- Require targeted operations to fail closed across Controller `N` and Node Agent `N-1` skew rather than downgrade to ambiguous Node or model targeting.
- Keep Linux platform qualification separate from every runtime-provider, model, and workload qualification.
- Define the `macos_controller_linux_node_model_free` acceptance profile with binding `N`/`N` and `N`/`N-1` pairings and exact worker-unit and resource-allocation targeting under separately accepted contracts.
  The `N-1` side must be an exact revision whose earlier, distinct Product Version is designated as the logical `N-1` by governed previous-line evidence, and the pairing cannot be waived.
- Keep the current Apple Silicon macOS support status, the Distribution Pause, and the Milestone 8 Linux Controller profile unchanged.
- State that this standalone Node contract defines no Controller, local Postgres, or single-host composition on the candidate host.

## Capabilities

### New Capabilities

- `linux-node-platform`: the bounded experimental Linux Node host matrix, source-development path, evidence binding, identity ownership, trust, inventory, compatibility, provider separation, and acceptance contract.

### Modified Capabilities

- `platform-profiles`: adds a requirement reserving the experimental Linux Node candidate separately from supported profiles and from the Linux Controller profile.
- `host-lifecycle-adapters`: adds a requirement keeping Linux Node candidate service-manager mechanics inside a Linux host lifecycle adapter with relocated-root validation.
- `packaging-deployment`: adds a requirement that the candidate defines no distribution artifact and that future Linux Node packaging requires fresh approval.

## Impact

- `SPEC.md` impact: amends §1.4, §4.1, §4.9, §7.5.0, §10.6, the §11 preamble, and §13.4, and adds Milestone 9 for experimental Linux Node qualification.
  The currently supported Apple Silicon macOS platform profile, the macOS native distribution design and its pause, and the Milestone 8 Linux Controller profile are unchanged.
- Decisions: adds proposed ADR 0035.
  Both existing ADR 0034 records are unchanged.
- Docs: adds `docs/platforms/linux-node.md` and updates orientation references that list current and proposed profiles, including the `AGENTS.md` milestone table row for Milestone 9.
- Code, packaging, CI, services, databases, and hosts are unchanged.
  No implementation, host qualification, package build, release, publication, or support claim follows from this change.
