# ADR 0035: Experimental Linux Node candidate uses source development

## Status

Proposed on 2026-09-30 and pending accountable owner review.

This record reconciles an earlier package-first version of the same Linux Node candidate decision that was accepted in review but never merged.
That earlier acceptance applies only to its own revision and does not accept this wording.
This record does not establish Linux Node, distribution, or runtime-provider support.

## Context

[ADR 0023](0023-platform-profiles-and-portable-core.md) made the Node Agent part of the portable Orchard control-plane core but deferred Linux Node lifecycle, packaging, accelerator discovery, and host management.
Portable Linux CI proves dependency hygiene; it does not define an installable Node or make one schedulable.

The earlier candidate contract paired one Ubuntu host tuple with a Node-only Debian artifact, a fixed package filesystem layout, a package-created service account, and package-owned systemd lifecycle.
Current `main` makes source development the active installation path, pauses native distribution under `SPEC.md` §11.0, and requires a fresh accepted proposal and a separate implementing pull request for any new distribution channel under `SPEC.md` §11.
Replaying the package-first contract would therefore restore a distribution goal that the current contract does not permit.

Broad claims such as Linux, CUDA, or vLLM support would also combine unrelated platform, lifecycle, resource, and provider qualifications and weaken Orchard's fail-closed authority boundaries.

## Decision

### Host matrix

Define `ubuntu_24_04_x86_64_node` as an experimental Linux Node platform profile candidate.
Its host baseline is Ubuntu Server 24.04 LTS on x86_64, a Linux kernel 6.8 or newer from an Ubuntu 24.04 kernel line, glibc 2.39 or newer within that release, systemd 255 or newer, and unified cgroup v2.
Ubuntu 26.04 LTS, every other Ubuntu release, other distributions, other architectures, other libc implementations, other init systems, containers used as hosts, and WSL remain unqualified.

### Source development, not a package

The candidate's current installation path is source development of the Node-only role of the portable Node Agent from an exact source revision with the pinned toolchain.
No Debian package, other package, container image, or other deployment artifact is defined.
Fixed filesystem layout, a package-created service identity, a package-owned unit, a bundled release runtime, a closed dependency manifest, air-gapped media, and package removal semantics are deferred to a future packaging contract that requires a fresh accepted proposal, a separate implementing pull request, and owner approval.

### Evidence binding

Every qualification record binds to the exact source commit and tree, clean-checkout proof, dependency locks, pinned toolchain identity, and passing generated-output drift checks.
Dirty, unidentified, or drifted checkouts produce implementation evidence only.
This binding does not impose a host-wide canonical checkout location or single-installation rule on developer worktrees, macOS hosts, or other Nodes.

### Identity, privilege, and supervision

Each Node Agent holds a process-lifetime exclusive owner-only lock in its Node Identity Root and rejects a second owner before enrollment, Runtime Endpoint activation, or Worker Runtime startup.
Qualification runs the Agent as a dedicated unprivileged non-login identity without sudo, package-mutation, database, device-reset, or device-reconfiguration authority.
For qualification, one systemd system unit supervises exactly one Agent and its Worker Runtime descendants in one cgroup, and the qualification host runs exactly one supervised candidate Agent.
Service-manager, cgroup, PID, heartbeat, runtime-directory, and device observations never prove custody, native cessation, request-slot release, resource release, or scheduling authority.
Linux lifecycle mechanics stay behind a Linux host lifecycle adapter with relocated-root tests and add no Linux or provider branches to the portable Node Agent.

### Trust and connectivity

The candidate uses only the accepted private-network model: certificate-backed enrollment, production BEAM TLS Distribution with Peer Grants, and certificate-authenticated gRPC for enrollment, credential lifecycle, Peer Grant delivery and recovery, diagnostics, and explicit compatibility.
It adds no transport, outbound-only session, public Node listener, NAT traversal, tunnel or relay substitute, automatic fallback, or replay of an ambiguously accepted inference operation.
Transitional shared-cookie operation is not candidate evidence.
Because distributed Erlang is a high-trust code boundary, the candidate cannot join production BEAM until an exact first-party release for it proves release authenticity, protected credential custody, trusted names, restricted networking, host controls, and the named mixed-platform acceptance profile.
Source-development revisions cannot satisfy that gate.
This extends the [ADR 0012](0012-scoped-beam-peer-grants.md) evidence standard without declaring the candidate accepted or supported.

### Inventory and targeting

Host inventory is provider-neutral observation with distinct NVIDIA and AMD provenance, and stable accelerator identity comes from vendor-documented identifiers where available.
Discovery never creates capacity, allocation, device binding, reset authority, or runtime custody.
Controller `N` may operate candidate Node Agent `N` and `N-1` only where the negotiated contract preserves the requested operation.
Operations that depend on worker-unit, resource-allocation, runtime-incarnation, residency, or control-generation targeting fail closed when either side cannot preserve the full target, and those targets become usable only after separately accepted contracts define them.

### Provider separation and acceptance

Linux platform qualification stays separate from every runtime-provider, model, and workload qualification.
Any runtime-provider pilot needs separate authorization and qualifies only one exact immutable hardware, provider, model, and profile tuple at concurrency one.
The `macos_controller_linux_node_model_free` acceptance profile pairs a qualified macOS Controller `N` with candidate Node Agent `N` and `N-1` using model-free fixtures and independently captured evidence from every participating host.
The `N-1` side must be an exact governed predecessor revision, and missing predecessor or macOS evidence leaves the profile unmet rather than waived.

### Scope boundary

This decision covers only a standalone candidate Node.
It defines no Linux Controller, local Postgres, or composition that places a Controller, Postgres, and Node on one candidate host.
A coordinated single-host composition requires its own accepted contract reconciled into `SPEC.md` before implementation.

## Alternatives considered

- Replay the package-first contract unchanged: rejected because it restores a distribution goal that `SPEC.md` §11 and §11.0 do not permit without fresh approval.
- Apply a host-wide canonical source installation rule to every Linux Node: rejected because it would constrain developer worktrees and ordinary Nodes; evidence binding achieves provenance without it.
- Waive the `N-1` pairing for the first Linux revision: rejected because no predecessor would have exercised the compatibility window.
- Add a relay or outbound-only session for hard-to-reach Nodes: rejected because it bypasses the private-network product boundary.

## Consequences

Later slices can implement a Linux adapter, identity ownership, inventory, and diagnostics without activating scheduling, packaging, or a runtime provider.
Relocated-root tests give deterministic evidence, while real systemd, reboot, and source upgrade and rollback evidence still require a separately authorized host exercise.
The `N`/`N-1` acceptance pairing remains unmet until an exact governed predecessor exists.
Diagnostics use retained generic surfaces because support bundles are retired.
Another distribution, architecture, or Ubuntu release requires its own evidence and an explicit contract update.

## SPEC.md impact

Update required in §1.4, §4.1, §4.9, §7.5.0, §10.6, the §11 preamble, §13.4, and a new Milestone 9 to define the experimental Linux Node candidate and its qualification boundary without declaring support.
