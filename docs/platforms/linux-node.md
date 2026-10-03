# Linux Node candidate profile

This document summarizes the experimental `ubuntu_24_04_x86_64_node` Linux Node candidate.
It is an accepted experimental qualification target, not a support claim.
The normative boundaries are [`SPEC.md`](../../SPEC.md) §1.4 and Milestone 9, [ADR 0035](../decisions/0035-experimental-linux-node-source-development.md), and the `reconcile-linux-node-source-dev-contract` OpenSpec change.
The Apple Silicon macOS platform profile remains the only supported platform profile.

## Host matrix

| Dimension | Candidate | Not qualified by this profile |
| --- | --- | --- |
| Distribution | Ubuntu Server 24.04 LTS | Ubuntu 26.04 LTS, every other Ubuntu release, Debian, RHEL-family, Fedora, SUSE, Arch, immutable or image-based systems |
| Architecture | x86_64 | arm64, ppc64le, s390x, RISC-V |
| Kernel | 6.8 or newer within the Ubuntu 24.04 hardware-enablement line | custom kernels without the required systemd or cgroup behavior, WSL kernels |
| libc | glibc 2.39 or newer within Ubuntu 24.04 | musl and other libc implementations |
| Init and cgroups | systemd 255 or newer as the system service manager, unified cgroup v2 | OpenRC, SysV init, user service managers, cgroup v1, containers used as the Node host |
| Privilege | root-administered setup; dedicated unprivileged non-login Agent identity | rootless installation, an Agent running as root or with sudo, or a shared interactive account |
| Filesystem | local POSIX filesystem with ownership, mode, and atomic rename enforcement for the Node Identity Root | network filesystems or filesystems that cannot enforce ownership and atomic publication |
| Network | operator-controlled private network; certificate-authenticated control plus Peer Grant-authorized TLS Distribution in a controlled model-free source-development test mesh outside production BEAM | Internet-exposed Node listeners, NAT traversal, tunnels or relays, outbound-only sessions, automatic transport fallback |
| Roles on the host | Node Agent and its Worker Runtimes only | Controller, Console, or database roles on the candidate host |

## Installation path

The candidate's proposed target installation path is source development of the Node-only role from an exact source revision with the pinned toolchain in `mise.toml`.
That path is not yet operable on a candidate host.
No Debian package, other package, container image, or other deployment artifact is defined, and executing source qualification requires no package, `Orchard.app`, or DMG build.
A future Linux Node package, fixed filesystem layout, package-created service identity, package-owned unit, closed dependency manifest, or air-gapped media requires a fresh accepted OpenSpec proposal, a separate implementing pull request, and owner approval.
The Distribution Pause in `SPEC.md` §11.0 is unaffected.
Making the Node-only source path operable on a candidate host is future implementation work, and [`local-dev.md`](../local-dev.md) does not yet describe it.

## Evidence binding

Every qualification record binds to the exact source commit and tree, clean-checkout proof, dependency locks, pinned toolchain identity, and passing generated-output drift checks.
A dirty, unidentified, or drifted checkout produces implementation evidence only.
This binding is not a host-wide install rule and does not constrain developer worktrees, macOS hosts, or other Nodes.

## Identity and lifecycle

Each Node Agent holds a process-lifetime exclusive owner-only lock in its Node Identity Root and rejects a second owner before enrollment, Runtime Endpoint activation, or Worker Runtime startup.
For qualification, one systemd system unit supervises exactly one Agent and its Worker Runtime descendants, and the qualification host runs exactly one supervised candidate Agent.
A foreground developer session produces implementation evidence only.
Unit, cgroup, PID, heartbeat, and runtime-directory facts are observations and never prove custody, release, or scheduling authority.
Source upgrade and rollback follow cordon, accepted drain, stop, switch to another exact clean revision, start, reconcile, verify, and uncordon, and uncertain survivors keep the Node unschedulable.

## Connectivity

Source qualification uses certificate-authenticated control for enrollment, credential lifecycle, Peer Grant delivery and recovery, and diagnostics.
Runtime Endpoint evidence uses Peer Grant-authorized TLS Distribution in a controlled model-free source-development test mesh outside production BEAM membership, as the [source-development BEAM Peer Grant tracer](../local-dev.md#source-dev-beam-peer-grant-tracer-experimental) does.
Every test-mesh participant, including the macOS Controller, is a source or test instance with no production BEAM membership, production credentials, or production data, so the mesh never bridges the candidate into production trust.
Shared-cookie Distribution is not a substitute, gRPC compatibility is not the default Runtime Endpoint transport, and no new transport, outbound-only session, tunnel, relay, NAT traversal, or automatic fallback is added.
Production BEAM stays limited to signed first-party releases on admitted Macs under `SPEC.md` §7.5.0, and the candidate stays outside it.

## Compatibility

Controller `N` to Node Agent `N` and `N-1` is a reader and behavior compatibility window, not shared Node Identity Root authority.
Additive observations from an older Agent decode as missing evidence.
Operations that depend on worker-unit, resource-allocation, runtime-incarnation, residency, or control-generation targeting fail closed when either side cannot preserve the full target.

## Capability evidence

CPU, memory, disk, OS, kernel, network, and accelerator inventory are bounded, redacted observations.
Stable accelerator identity uses a vendor-documented immutable identifier, and PCI address and device ordinal are topology observations only.
NVIDIA/CUDA and AMD/ROCm observations remain distinct.
Missing vendor tooling means evidence is absent, not that a device is healthy or free.
Inventory never creates schedulable capacity, allocation, device binding, runtime custody, or a runtime-provider qualification.

The Node Agent carries this inventory as the additive `StatusResponse.host_inventory` field on Runtime Endpoint status.
It is off by default; in source development, `ORCHARD_NODE_HOST_INVENTORY=linux` selects the Linux capability provider, and `ORCHARD_NODE_HOST_INVENTORY_ACCELERATORS=nvidia,amd` separately opts in to each accelerator vendor probe.
Disk capacity is observed at the configured Node Identity Root.
Probes run only allowlisted absolute executables with a cleared environment and the `C` locale, under a GNU coreutils `timeout` guardian whose identity is verified before use; a missing tool or guardian yields absent evidence, and another `timeout` implementation counts as missing.
Each section has its own time budget, so one hung probe affects only its section, and oversized or malformed output becomes error or partial evidence rather than a truncated value.
Collection is asynchronous and status reads only the last bounded snapshot, which reads as absent once it exceeds its maximum age.
Controllers drop an inventory outside the observation-only bounds on both BEAM and gRPC status, and inventory is not persisted in heartbeat payloads.
Across version skew, gRPC status keeps inventory fields added by a newer Node Agent as decoded unknown fields, while a BEAM Runtime Endpoint inventory term that carries fields this Controller does not define fails its bound check and reads as absent.
This behavior is validated against synthetic fixtures and is not host qualification.

## Redacted runtime-target diagnostics

The existing authenticated `GET /ops/v1/health` response exposes nullable `runtime.diagnostics` to cluster-scoped Operators and admins, with `Cache-Control: no-store`. It re-normalizes the diagnostics block from its single existing `OrchardConsole.Runtime.snapshot/1` read. Failed snapshots and missing/legacy or unknown-schema blocks return null, even if a failed snapshot contains positive diagnostic evidence. Diagnostics do not affect the HTTP health status or readiness result; public `/health/ready` remains status-only.

The retained `OrchardConsole.Runtime.snapshot/1` and `cluster_snapshot/1` status paths produce the block from the Agent's cached inventory. `Orchard.ClusterManagement.StatusBuilder.runtime_target_status_map/1` also carries that projection through shared NodeStatus. The projection starts no probe or additional runtime call. This tranche does not add a Console panel, route or CLI command.

Registered-node `orchardctl nodes list --json` and `nodes inspect <node-id> --json` have `status.v1` diagnostics set to null (inside each status object). Persisted Nodes and admission candidates have no volatile host-inventory source. Missing additive fields from older readers normalize to null; missing/disabled Agent inventory is `absent`. An adapter may already have dropped invalid inventory, which then also reads as absent.

The schema-version-1 block contains `authority: "observation_only"`, `runtime` and `inventory`. Runtime reports evidence `status`, `source: "runtime_endpoint"`, `observed_at_unix_ms`, `age_ms`, `health` (`ready`, `not_ready`, `unknown`) and `worker_state` (`starting`, `idle`, `busy`, `stopping`, `failed`, `stopped`, `unknown`). Inventory reports its own evidence status/time/age and fixed `cpu`, `memory`, `disk`, `platform`, `network`, `nvidia` and `amd` sections. Each section contains status, source, time, age and nullable count. Counts mean logical processors, interfaces or observed devices; memory/disk/platform counts are always null. No byte capacity is exposed. Source categories are `cpu_probe`, `memory_probe`, `disk_probe`, `platform_probe`, `network_probe`, `nvidia_probe`, `amd_probe` or `unknown`; raw probe paths and arguments are not retained.

Evidence states are `observed`, `absent`, `partial`, `error`, `invalid` and `stale`. Only fresh observed evidence contributes counts. The projection rejects future/invalid timestamps and applies the diagnostic age and traversal limits in SPEC.md §4.6.1. It recalculates ages from original timestamps on shared-status normalization, never from the time a page was read. Device counts require fresh observed evidence for every listed device and matching vendor provenance; their section timestamp is the oldest contributing provider/device timestamp so a cached count expires with its oldest evidence. Missing vendor evidence is null, not a healthy/free device or zero capacity.

The redaction guarantee covers this new block, not every pre-existing field on the surrounding status object. It excludes arbitrary health messages, identifiers, network addresses, paths, credentials, environment and unknown protobuf data. It does not change persistence, readiness, admission, scheduling, capacity, custody, release, or qualification. Public health remains status-only and support commands remain retired. This is narrow progress on inventory and runtime health/lifecycle observations; broader logs and metrics diagnostics and task 3.3 remain incomplete.

## Qualification gates

Candidate source qualification requires every applicable gate below on an exact clean source revision:

1. closed-matrix preflight that fails before mutation on unqualified hosts;
2. Node Identity Root ownership and secret-permission checks;
3. single-Agent ownership across start, stop, restart, crash, reboot, source upgrade, and source rollback;
4. provider-neutral inventory accuracy on representative CPU-only, NVIDIA, and AMD hosts without changing device configuration;
5. credential renewal and revocation, Peer Grant rotation, and private-network reconnect under the accepted transport contract, excluding shared-cookie runs;
6. redacted diagnostics through retained generic surfaces;
7. model-free custody and mixed-version tests after the required request-slot and resource release and targeting contracts are accepted; and
8. the `macos_controller_linux_node_model_free` profile for both `N`/`N` and `N`/`N-1`, including exact worker-unit and resource-allocation targeting under separately accepted contracts.

The `N-1` side is an exact commit and tree whose Product Version is earlier than and distinct from `N` and which governed previous-line evidence designates as the logical `N-1`.
An older commit with the same Product Version or an arbitrary earlier version does not qualify, and missing designation, predecessor, or macOS host evidence leaves the gate unmet with no waiver.

Passing source qualification does not make the candidate eligible for production BEAM or supported.
Either outcome needs a future separately accepted release and trust profile, exact provenance and reverification, and the accountable product owner's decision.
A one-H100 vLLM pilot needs its own separately authorized qualification of one immutable H100, vLLM, model, and serving-configuration tuple at concurrency one.
Until those steps complete, documentation and diagnostics call the profile experimental and do not claim Linux Node, distribution, CUDA, ROCm, vLLM, or model support.
