## Why

Orchard's portable Node Agent compiles on Linux, but the current contract
explicitly defers Linux Node packaging, lifecycle, host inventory, security, and
qualification. Implementation without one bounded profile would turn portable
CI or accelerator observations into an unsupported platform claim.

KAP-27 has also closed outbound-only Runtime Endpoint sessions as outside the
current private-network product boundary. Linux Node work must compose existing
trust and Runtime Endpoint contracts rather than creating a parallel transport.

## What Changes

- Define one experimental Ubuntu 24.04 x86_64 Linux Node platform and
  distribution candidate with explicit kernel, libc, systemd, cgroup,
  privilege, filesystem, and network bounds.
- Define a Node-only Debian artifact, fixed FHS layout, dedicated service
  identity, systemd ownership, persistent Node Identity Root, and fail-closed
  duplicate ownership.
- Bundle the exact ERTS/OTP runtime, declare every OS prerequisite in a
  versioned dependency manifest, and use the same closed dependency set online
  and air-gapped.
- Keep private-network production BEAM and certificate-authenticated gRPC
  control as the only accepted connectivity model, gated on exact first-party
  release, credential-custody, host-control, network, and mixed-platform
  evidence.
- Define provider-neutral host and accelerator inventory as observation only,
  with NVIDIA and AMD evidence separately qualified.
- Define reader-first `N`/`N-1` behavior and fail-closed targeting when required
  Worker Unit or resource generations are unavailable.
- Define `macos_controller_linux_node_model_free` so Linux-only evidence cannot
  be misrepresented as mixed-platform acceptance.
- Stage implementation and qualification without activating scheduling,
  provider support, release, deployment, or a Linux support claim.

## Capabilities

### New Capabilities

- `linux-node-platform`: Defines the bounded Linux Node host, distribution,
  lifecycle, inventory, security, and qualification contract.

### Modified Capabilities

- `platform-profiles`: Adds an experimental Linux Node candidate without
  changing the existing Linux Controller or macOS profiles.
- `host-lifecycle-adapters`: Defines the Linux systemd adapter boundary and
  relocated-root validation requirement.
- `packaging-deployment`: Defines the candidate Node-only Debian distribution
  and FHS layout without authorizing publication.

## Impact

- `SPEC.md` gains the Linux Node candidate and qualification boundaries.
- ADR 0034 records the durable host-profile decision.
- Implementation may add Linux package, systemd, inventory, diagnostic, and
  model-free custody adapters only after this change validates and is accepted.
- KAP-18 and KAP-26 remain authoritative for release and ownership semantics;
  KAP-27 continues to prohibit outbound-only session implementation.
- No production rollout, scheduling cutover, provider activation, or blanket
  Linux support follows from this change.
