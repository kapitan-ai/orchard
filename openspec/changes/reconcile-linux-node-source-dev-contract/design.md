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
- Keep every Linux Node statement experimental and free of support claims.
- Leave the supported macOS profile, the Distribution Pause, and the Linux Controller profile unchanged.

**Non-Goals:**

- Implementing any Linux adapter, inventory provider, credential lifecycle, custody, or compatibility behavior.
- Defining detailed credential lifecycle rules, which belong to a future credential lifecycle OpenSpec change reviewed under `docs/process.md`.
- Defining a coordinated single-host composition, managed local Postgres, or a Linux Controller on the candidate host.
- Defining worker-unit, resource-allocation, request-slot release, or native-cessation semantics.
- Packaging, publication, release, deployment, or host qualification.
- Widening the production BEAM trust boundary or formulating the future release and trust profile that Linux Node production eligibility would need.

## Decisions

### One narrow host tuple precedes a distribution family

The initial tuple stays Ubuntu Server 24.04 LTS, x86_64, glibc, systemd, and unified cgroup v2, with lower bounds matching the base release and kernel advancement allowed within the Ubuntu 24.04 hardware-enablement line.
Rootless installation stays unqualified, because qualification needs root-administered setup of the dedicated identity and system unit even though the Agent itself runs unprivileged.
Ubuntu 26.04 LTS is named explicitly as unqualified because it is the nearest release a reader might assume is covered.
Generic Debian-family or Ubuntu-family compatibility from one release was rejected.

### Source development replaces the package artifact

The candidate's proposed target path is the Node-only role of a source checkout at an exact revision with the pinned toolchain.
That path is not yet operable on a candidate host, and making it operable is the first implementation slice.
Replaying the Debian artifact was rejected because `SPEC.md` §11 requires a fresh accepted proposal and a separate implementing pull request for any new distribution channel, and because source development is the active installation path while §11.0 holds.
The fixed package layout, package-created account, package-owned unit, bundled runtime, dependency manifest, and air-gapped media move to a future packaging contract that needs separate owner approval.
Default package removal, purge, and reinstall semantics move with them.

### Evidence binds to an exact source revision, not to a host-wide install rule

The earlier contract bound qualification to exact immutable package bytes.
Under source development the equivalent is the exact commit and tree, clean-checkout proof, dependency locks, pinned toolchain identity, and passing generated-output drift checks.
A host-wide canonical checkout location and single-installation rule was considered and rejected for the standalone Node, because it would wrongly constrain developer worktrees, macOS hosts, and ordinary Nodes.
That rejection is limited to the standalone Node, and a coordinated single-host composition may define its own installation rule under its own accepted contract without being overruled here.
Qualification instead requires exactly one supervised candidate Agent on the qualification host, which is an evidence topology rather than a host-wide install rule.

### Orchard owns identity and systemd supervises processes

Each Agent holds a process-lifetime exclusive lock in its Node Identity Root, because service-manager state cannot prove that no other process uses the same identity.
For qualification, one systemd system unit supervises one Agent and its Worker Runtime descendants in one cgroup.
The unit definition and its installation mechanics belong to a future Linux host lifecycle adapter slice, and this change delivers no unit file.
An empty cgroup proves only that systemd observed process exit, not request-slot, resource, or placement release.

### Existing private-network trust is the only connectivity model

Source qualification uses the transports that already exist for source development: certificate-authenticated control for enrollment, credential lifecycle, Peer Grant delivery and recovery, and diagnostics, plus Peer Grant-authorized TLS Distribution in a controlled model-free test mesh outside production BEAM membership, as the documented source-development Peer Grant tracer does.
Shared-cookie Distribution was rejected as a substitute because it is visibly transitional under §10.6, and gRPC compatibility was rejected as a default because ADR 0029 proposes deprecating it as the first-party Runtime Endpoint transport.
Outbound-only sessions, tunnels, relays, NAT traversal, new transports, automatic fallback, and replay were rejected because they would bypass the private-network product boundary and the no-fallback rule.
The production BEAM boundary in §7.5.0 and ADR 0012 stays Mac-only and unchanged, and the candidate stays outside it.
Generalizing that boundary to any host profile that passes evidence gates was considered and rejected, because it would widen a high-trust boundary beyond this standalone Node scope.
Source-qualification evidence is therefore distinct from production eligibility and support, which require a future separately accepted release and trust profile, exact provenance and reverification, and an owner decision.
Running source qualification does not require restoring a package, `Orchard.app`, or DMG build and adds no distribution goal.
Detailed certificate lifetime, clock, overlap, reconnect backoff, and stale-connection rules are left to a future credential lifecycle OpenSpec change and are not restated here.

### Inventory is typed evidence, never an allocation

The Linux capability provider emits bounded provider-neutral observations with distinct NVIDIA and AMD provenance.
Missing tools and malformed output yield absent or invalid evidence.
Discovery never binds a device, starts a runtime, or creates capacity.

### Targeted operations fail closed across skew

Readers accept additive old observations as absent evidence.
An operation whose meaning depends on a worker-unit, resource-allocation, runtime-incarnation, residency, or control-generation target is rejected when either side cannot preserve the full target.
Those targets become usable only after separately accepted contracts define them.

### Mixed-platform acceptance binds both pairings

`macos_controller_linux_node_model_free` requires `N`/`N` and `N`/`N-1` pairings with independent evidence from every participating host, including exact worker-unit and resource-allocation targeting, so the profile stays unmet until those targeting contracts are accepted.
The `N-1` side must be an exact commit and tree whose Product Version is earlier than and distinct from `N` and which governed previous-line evidence designates as the logical `N-1` of §13.1.
An older commit with the same Product Version or an arbitrary earlier version was rejected, because §13.1 keeps the Product Version across ordinary commits and `N-1` means the previous supported line.
This change does not define the designation mechanism, which stays with pending release-line governance, and the pairing stays unmet until that governance is accepted.
A first-release floor or waiver was rejected because it would let the first Linux Node revision claim a compatibility window that no predecessor has exercised.

### Diagnostics use retained generic surfaces

The earlier contract asked for offline diagnostic collection.
Support bundles are retired on `main`, so candidate diagnostics use retained generic health, log, metric, inventory, and lifecycle surfaces and add no archive format.

### Recorded deviations from the earlier contract

These deviations were introduced by this revision, are not covered by the earlier acceptance, and were accepted with this revision through pull request #464.

- Ubuntu 26.04 LTS is named explicitly as unqualified, which narrows nothing that the closed tuple already covered.
- The package-owned lifecycle, fixed layout, service-account name, air-gapped media, and removal semantics are deferred to a future packaging contract.
- Qualification hosts run no Controller, Console, or database role, carried from the earlier Node-only artifact closure rather than invented here.
- The Node Identity Root filesystem bound moves from the earlier support matrix into the normative contract.
- The one-H100 vLLM pilot keeps its scope, but its tuple names a serving configuration because `SPEC.md` does not define a serving profile.
- The earlier generalized production BEAM sentence is not carried forward, so the Mac-only boundary stays verbatim.
- Offline diagnostic collection becomes retained generic diagnostic surfaces because support bundles are retired.

### ADR numbering

Both existing ADR 0034 records stay untouched.
This decision uses the next unused number, 0035.

## Risks / Trade-offs

- [The profile is too narrow] → Additional releases or distributions can be qualified later without weakening this evidence.
- [Source-development qualification is mistaken for a distribution] → Specs and docs state that no artifact, release, or support claim follows, and packaging requires fresh approval.
- [Service-manager state is mistaken for Orchard authority] → Tests and diagnostics label process and cgroup facts as observations.
- [Evidence binding is read as a host-wide install rule] → The requirement explicitly scopes binding to qualification records and excludes developer worktrees and other hosts.
- [The `N-1` gate blocks the first candidate indefinitely] → That outcome is intended until governed previous-line evidence designates an earlier distinct Product Version, and the gate stays visibly unmet rather than waived.
- [Undefined targeting terms drift] → They remain lowercase generic concepts until an accepted contract defines them.

## Migration Plan

The contract lands before behavior and changes no code, packaging, CI, service, or host.
Later slices proceed in this order: Linux adapter and source-development Node path, observation-only inventory, credential lifecycle reconciliation, diagnostics, model-free custody, mixed-platform acceptance, and any separately authorized provider pilot.
Every slice stays default-off and additive and needs its own review.
Observation-only inventory may be implemented and validated against synthetic fixtures before the source-development Node path and lifecycle slices, because it is default-off and creates no authority; real host qualification still requires every source-path, lifecycle, and mixed-platform gate, and that ordering delivers none of those tasks.
Rollback of this change removes only unimplemented contract text.

## Open Questions

- Resolved: the accountable owner accepted this exact reviewed revision on 2026-09-30, and each implementation slice still needs its own review.
- The future release and trust profile that could make a Linux Node eligible for production BEAM or support is not formulated here and stays open for a later product decision.
- The dedicated service-identity name and any fixed paths are deferred to a future packaging proposal and do not affect this contract.
