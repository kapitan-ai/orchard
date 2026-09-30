## Context

The portable Node Agent, Runtime Endpoint interface, Worker Runtime boundary, Node trust model, BEAM Peer Grant contract, and Linux portable validation lane already exist on `main`.
What is missing is one bounded Linux Node host profile that later slices can implement without inventing trust, lifecycle, or support semantics.

An earlier package-first version of this candidate contract was accepted in review but never merged.
It paired the host matrix with a Node-only Debian artifact, a fixed package filesystem layout, a package-created service account, package-owned systemd lifecycle, bundled release runtime, closed dependency manifest, and air-gapped package media.
Since then `main` has made source development the active installation path, paused native distribution under `SPEC.md` §11.0, required a fresh proposal for any new distribution channel, retired support bundles, and added two ADRs numbered 0034.
See proposal.md for motivation.

Several terms that the earlier contract used, including worker units, resource allocations, and serving profiles, are not yet defined in `SPEC.md`.
This design therefore names them only as future targeting concepts and does not define them.

## Goals / Non-Goals

**Goals:**

- Carry forward the earlier contract's host matrix, observation-only inventory, private-network trust, fail-closed targeting, provider separation, and mixed-platform gate.
- Replace every package-first assumption with the current source-development path and exact source evidence binding.
- Keep every Linux Node statement proposed, experimental, and free of support claims.
- Leave the supported macOS profile, the Distribution Pause, and the Linux Controller profile unchanged.

**Non-Goals:**

- Implementing any Linux adapter, inventory provider, credential lifecycle, custody, or compatibility behavior.
- Restating or extending the later credential lifecycle contract, whose reconciliation is a separate slice.
- Defining a coordinated single-host composition, managed local Postgres, or a Linux Controller on the candidate host.
- Defining worker-unit, resource-allocation, request-slot release, or native-cessation semantics.
- Packaging, publication, release, deployment, or host qualification.

## Decisions

### One narrow host tuple precedes a distribution family

The initial tuple stays Ubuntu Server 24.04 LTS, x86_64, glibc, systemd, and unified cgroup v2, with lower bounds matching the base release and kernel advancement allowed within the Ubuntu 24.04 kernel lines.
Ubuntu 26.04 LTS is named explicitly as unqualified because it is the nearest release a reader might assume is covered.
Generic Debian-family or Ubuntu-family compatibility from one release was rejected.

### Source development replaces the package artifact

The candidate's current path is the Node-only role of a source checkout at an exact revision with the pinned toolchain.
Replaying the Debian artifact was rejected because `SPEC.md` §11 requires a fresh accepted proposal and a separate implementing pull request for any new distribution channel, and because source development is the active installation path while §11.0 holds.
The fixed package layout, package-created account, package-owned unit, bundled runtime, dependency manifest, and air-gapped media move to a future packaging contract that needs separate owner approval.
Default package removal, purge, and reinstall semantics move with them.

### Evidence binds to an exact source revision, not to a host-wide install rule

The earlier contract bound qualification to exact immutable package bytes.
Under source development the equivalent is the exact commit and tree, clean-checkout proof, dependency locks, pinned toolchain identity, and passing generated-output drift checks.
A host-wide canonical checkout location and single-installation rule was considered and rejected for the standalone Node, because it would wrongly constrain developer worktrees, macOS hosts, and ordinary Nodes.
Qualification instead requires exactly one supervised candidate Agent on the qualification host, which is an evidence topology rather than a host-wide install rule.

### Orchard owns identity and systemd supervises processes

Each Agent holds a process-lifetime exclusive lock in its Node Identity Root, because service-manager state cannot prove that no other process uses the same identity.
For qualification, one systemd system unit supervises one Agent and its Worker Runtime descendants in one cgroup.
The unit definition and its installation mechanics belong to a future Linux host lifecycle adapter slice, and this change delivers no unit file.
An empty cgroup proves only that systemd observed process exit, not request-slot, resource, or placement release.

### Existing private-network trust is the only connectivity model

The candidate uses certificate-backed enrollment, production BEAM TLS Distribution with Peer Grants, and certificate-authenticated gRPC control.
Outbound-only sessions, tunnels, relays, NAT traversal, new transports, automatic fallback, and replay were rejected because they would bypass the private-network product boundary and the no-fallback rule.
Transitional shared-cookie operation is excluded from candidate evidence because it is visibly transitional under §10.6.
Production BEAM remains closed to source revisions because §7.5.0 limits it to signed first-party releases.
The detailed certificate lifetime, clock, overlap, reconnect backoff, and stale-connection rules belong to the separate credential lifecycle reconciliation and are not restated here.

### Inventory is typed evidence, never an allocation

The Linux capability provider emits bounded provider-neutral observations with distinct NVIDIA and AMD provenance.
Missing tools and malformed output yield absent or invalid evidence.
Discovery never binds a device, starts a runtime, or creates capacity.

### Targeted operations fail closed across skew

Readers accept additive old observations as absent evidence.
An operation whose meaning depends on a worker-unit, resource-allocation, runtime-incarnation, residency, or control-generation target is rejected when either side cannot preserve the full target.
Those targets become usable only after separately accepted contracts define them.

### Mixed-platform acceptance binds both pairings

`macos_controller_linux_node_model_free` requires `N`/`N` and `N`/`N-1` pairings with independent evidence from every participating host.
The `N-1` side must be an exact governed predecessor revision.
A first-release floor or waiver was rejected because it would let the first Linux Node revision claim a compatibility window that no predecessor has exercised.

### Diagnostics use retained generic surfaces

The earlier contract asked for offline diagnostic collection.
Support bundles are retired on `main`, so candidate diagnostics use retained generic health, log, metric, inventory, and lifecycle surfaces and add no archive format.

### ADR numbering

Both existing ADR 0034 records stay untouched.
This decision uses the next unused number, 0035.

## Risks / Trade-offs

- [The profile is too narrow] → Additional releases or distributions can be qualified later without weakening this evidence.
- [Source-development qualification is mistaken for a distribution] → Specs and docs state that no artifact, release, or support claim follows, and packaging requires fresh approval.
- [Service-manager state is mistaken for Orchard authority] → Tests and diagnostics label process and cgroup facts as observations.
- [Evidence binding is read as a host-wide install rule] → The requirement explicitly scopes binding to qualification records and excludes developer worktrees and other hosts.
- [The `N-1` gate blocks the first candidate indefinitely] → That outcome is intended until an exact governed predecessor exists, and the gate stays visibly unmet rather than waived.
- [Undefined targeting terms drift] → They remain lowercase generic concepts until an accepted contract defines them.

## Migration Plan

The contract lands before behavior and changes no code, packaging, CI, service, or host.
Later slices proceed in this order: Linux adapter and source-development Node path, observation-only inventory, credential lifecycle reconciliation, diagnostics, model-free custody, mixed-platform acceptance, and any separately authorized provider pilot.
Every slice stays default-off and additive and needs its own review.
Rollback of this change removes only unimplemented contract text.

## Open Questions

- The accountable owner must review and accept this exact revision before any implementation slice begins.
- The dedicated service-identity name and any fixed paths are deferred to a future packaging proposal and do not affect this contract.
