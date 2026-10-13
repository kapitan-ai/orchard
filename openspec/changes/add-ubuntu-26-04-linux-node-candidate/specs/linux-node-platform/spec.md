## ADDED Requirements

### Requirement: Ubuntu 26.04 Node Candidate Has A Separate Closed Host Matrix

Orchard SHALL define `ubuntu_26_04_x86_64_node` as an experimental candidate
separate from `ubuntu_24_04_x86_64_node`. It SHALL require Ubuntu Server
`ID=ubuntu` and `VERSION_ID=26.04` on x86_64, the Ubuntu 26.04 generic/server
kernel 7.0 line, glibc 2.43 within that release, systemd 259 within that release,
and unified cgroup v2. Other Ubuntu releases, cloud-image-specific package
variants, amd64v3-only variants, distributions, architectures, libc
implementations, init systems, containers-as-hosts, WSL, and rootless
installation SHALL remain unqualified. This requirement changes `SPEC.md`
§§1.4, 4.1, and 14.

#### Scenario: Ubuntu version is newer but not enumerated

- **WHEN** preflight observes an Ubuntu release other than the exact selected 24.04 or 26.04 candidate
- **THEN** installation fails before system or identity mutation
- **AND** no semantic-version range or Ubuntu-family inference admits the host

#### Scenario: Exact 26.04 candidate is proposed

- **WHEN** the 26.04 tuple is accepted but its real-host qualification is incomplete
- **THEN** it remains experimental and unsupported
- **AND** boot, compilation, or static validation does not substitute for qualification

### Requirement: Ubuntu 26.04 Qualification Is Real And Candidate-Specific

The 26.04 candidate SHALL require independently captured evidence from a signed
canonical amd64 Server image for exact host identity; package and offline
dependency closure; default-off install; paths, permissions, secret custody,
symlink refusal, and exclusive identity ownership; systemd start, stop, restart,
crash, reboot, upgrade, rollback, removal, and reinstall; cgroup-v2 process,
survivor, orphan, listener, and resource cleanup; private-network KAP-82
credential and Peer Grant behavior; redacted diagnostics; and provider-neutral
inventory. Accelerator discovery SHALL be exercised only where applicable and
SHALL NOT establish provider, runtime, allocation, scheduling, placement,
capacity, or readiness authority. This requirement changes `SPEC.md` §14.

#### Scenario: Ubuntu 24.04 evidence is presented for 26.04

- **WHEN** a qualification decision has only 24.04 lifecycle or mixed-host evidence
- **THEN** the 26.04 gate remains unmet
- **AND** shared package bytes do not make the evidence interchangeable

#### Scenario: Accelerator tooling is present on 26.04

- **WHEN** the host reports NVIDIA, CUDA, AMD, or ROCm tooling or devices
- **THEN** Orchard records only bounded provider-neutral observations with exact provenance
- **AND** no provider support or resource authority follows

### Requirement: Ubuntu 26.04 Command Dependencies Are Explicit

The 26.04 candidate SHALL have a release-specific machine-readable dependency
manifest and fail-closed preflight. Where package, inventory, lifecycle, or
diagnostic behavior relies on GNU coreutils semantics, qualification SHALL prove
an explicitly installed and invoked GNU implementation rather than infer it from
a command name, command success, or Ubuntu's default uutils package. This
requirement changes `SPEC.md` §11.

#### Scenario: Default command has unqualified semantics

- **WHEN** a required command resolves to an implementation whose semantics are not in the accepted dependency closure
- **THEN** preflight or qualification fails before Node activation
- **AND** it does not treat command presence as compatibility evidence

### Requirement: Mixed-Platform Acceptance Runs Per Linux Candidate

The `macos_controller_linux_node_model_free` acceptance profile SHALL run
independently for each enumerated Linux Node candidate with a qualified macOS
Controller `N` and that candidate's Node Agent at `N` and `N-1`. Each run SHALL
retain independently captured evidence from every participating host for the
accepted model-free lifecycle scenarios. Evidence for one Linux candidate SHALL
NOT qualify another, and unavailable direct private routing SHALL leave the
cross-host gate unmet. This requirement changes `SPEC.md` §14.

#### Scenario: One candidate passes both version directions

- **WHEN** 24.04 passes its `N` and `N-1` mixed-host matrix but 26.04 has not run
- **THEN** only the 24.04 candidate has that evidence
- **AND** 26.04 remains unqualified
