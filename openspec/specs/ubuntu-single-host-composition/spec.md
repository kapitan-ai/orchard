# ubuntu-single-host-composition Specification

## Purpose

Defines the accepted, unimplemented composition, authority, database, isolation,
lifecycle, recovery, topology-expansion, and qualification contract for the
exact Ubuntu Server 24.04 LTS x86_64 single-host Orchard profile without
creating a release, deployment, publication, or support claim.

## Requirements

### Requirement: Single-Host Composition Preserves Role Authority

The accepted `ubuntu_24_04_x86_64_single_host` profile SHALL compose one
Controller, one locally managed PostgreSQL 16 cluster, one separately enrolled
and admitted Node Agent, and only separately qualified Worker Runtimes on the
exact Ubuntu Server 24.04 LTS x86_64 host tuple.
Controller, PostgreSQL, Node Agent, and Worker Runtime SHALL retain distinct
non-login identities, writable roots, credentials, units, logs, cgroups, and
operational ownership.
Colocation MUST NOT create enrollment, admission, leadership, dispatch,
execution, capacity, database-superuser, or release authority.

#### Scenario: Controller and Node are healthy on one host

- **WHEN** every local process and database readiness check succeeds
- **THEN** the Node remains unschedulable until its independent enrollment, admission, credential, Runtime Endpoint observation, lifecycle, health, and capacity gates pass
- **AND** PostgreSQL readiness does not become Controller or Node readiness

#### Scenario: One role attempts another role's state

- **WHEN** a service identity attempts to read or mutate another role's private state, secret, or writable root
- **THEN** host permissions reject access
- **AND** locality supplies no alternate shared credential or directory

### Requirement: Source Installation Is Canonical And Exclusive

The profile SHALL permit exactly one root-owned source checkout at
`/opt/orchard/source`, one installation UUID, one fixed configuration/state/
runtime identity, one lifecycle owner, and one Controller per host.
The source manifest SHALL bind exact Git commit/tree, clean-checkout proof,
dependency/toolchain locks, generated-output drift status, schema, and protocol
compatibility.
Before mutation or start, preflight SHALL reject another or ambiguous checkout,
installation/state identity, Controller process, lifecycle lock, required
listener/port, EPMD/BEAM name, PostgreSQL cluster, or supervisor.
It MUST NOT kill, adopt, overwrite, or merge a live, foreign, replaced, or
ambiguous owner. Only exact stale evidence owned by the canonical installation
MAY enter bounded recovery.

#### Scenario: A second Controller installation is attempted

- **WHEN** another checkout, installation UUID, state root, or Controller process claims the host
- **THEN** preparation and startup fail before mutation
- **AND** neither installation is treated as an alternate supported instance

#### Scenario: Canonical stale evidence remains after a crash

- **WHEN** the manifest and receipts prove stale evidence belongs to the canonical installation and no owner remains live
- **THEN** the lifecycle enters explicit recovery rather than creating a second identity
- **AND** ambiguous evidence still blocks

### Requirement: Appliance Database Has Reproducible Local Custody

The profile SHALL use the exact Ubuntu PostgreSQL 16 dependency closure locked
by its source manifest and SHALL bind PostgreSQL only to its local Unix-domain
socket.
It SHALL define a dedicated database, NOLOGIN owner, distinct runtime,
migration, and backup roles, exclusive advisory-lock migration, durable schema
identity, bounded readiness, backup, fenced restore, corruption and ENOSPC
behavior, and default data retention.
The Controller MUST NOT receive PostgreSQL superuser, package mutation,
replication, tablespace, role-creation, or cluster lifecycle authority.

#### Scenario: Database is unavailable or full

- **WHEN** PostgreSQL cannot durably commit because it is unavailable, corrupt, in recovery, or out of space
- **THEN** Controller readiness is false and new scheduling and governance writes stop
- **AND** Orchard neither initializes a replacement cluster nor deletes data automatically

#### Scenario: Migration fails

- **WHEN** the exclusive migration unit fails or cannot prove compatible schema identity
- **THEN** Controller and Node startup remain blocked
- **AND** the durable receipt permits only exact resume, compatible rollback, roll-forward, or full fenced restore

### Requirement: Same-Host Runtime Endpoint Uses Production Authentication

The colocated Controller and Node Agent SHALL use their distinct stable IDs,
exact certificates, ordinary Node Admission, one active scoped BEAM Peer Grant,
current credential and connection generations, and canonical BEAM names on the
host's validated stable RFC1918 IPv4 address.
Loopback names, localhost trust, shared or static cookies, certificate-only
trust, address-only trust, and automatic gRPC Runtime Endpoint fallback MUST NOT
authorize the relationship.
The existing forced disconnect, reconnect, stale-observation, and no-replay
contracts SHALL remain applicable.
Implementation and qualification SHALL remain held while their credential
lifecycle decision, OpenSpec package, and required evidence disagree or remain
incomplete.

#### Scenario: Local address or process is present without current authority

- **WHEN** the expected local listener exists but admission, certificate, Peer Grant, name, or generation authority is absent or stale
- **THEN** production BEAM connection and Runtime Endpoint work fail closed
- **AND** the operation is not retried through gRPC automatically

#### Scenario: Controller address changes during separation

- **WHEN** the Controller moves to a new private address
- **THEN** trusted inventory, canonical name, affected certificate/grant generations, deliberate disconnect, and reconnect follow the accepted lifecycle
- **AND** neither the Controller ID nor any private key is cloned onto concurrent live hosts

### Requirement: Startup And Failure Ordering Are Deterministic

The composition SHALL start PostgreSQL readiness, exclusive compatible migration,
Controller readiness, and Node Agent in that order.
Source preparation SHALL leave every unit disabled and SHALL NOT initialize a
cluster, enroll or admit a Node, start a Worker, or publish capacity.
Exact stale canonical evidence MAY enter recovery. A live, foreign, replaced,
or ambiguous listener, process, cgroup member, lifecycle receipt, migration
owner, identity root, checkout, installation UUID, port, EPMD/BEAM name,
PostgreSQL cluster, or supervisor SHALL fail closed rather than be adopted.
Worker, Node, Controller, and database failure SHALL remain independently
visible and MUST NOT manufacture health, readiness, or released capacity.

#### Scenario: Clean source preparation completes

- **WHEN** the canonical source tree, installation manifest, accounts, roots, and inert unit files are prepared successfully
- **THEN** exact source provenance and one installation UUID are recorded
- **AND** no Orchard unit, database cluster, product identity, provider, or model is active

#### Scenario: Node Agent crashes while a Worker may survive

- **WHEN** the Node Agent exits and Worker execution or occupancy cannot be proved terminated and released
- **THEN** the Node remains unschedulable and affected capacity remains unavailable
- **AND** a process or cgroup observation does not independently clear KAP-18 or KAP-26 authority

### Requirement: Worker Pressure Cannot Starve Recovery Authority

The profile SHALL require unified cgroup v2, at least 8 logical CPUs and 32 GiB
RAM, and two Worker-excluded control CPUs.
For physical RAM `M`, the appliance parent SHALL be capped at
`M-max(4 GiB, 10% of M)` and SHALL provide non-overcommitted hierarchical
`MemoryMin` protection of 4 GiB for Controller, 4 GiB for database, and 1 GiB
for an Agent-only leaf.
With `W=M-max(4 GiB, 10% of M)-17 GiB`, the Node lifecycle cgroup SHALL have an
aggregate maximum of `2 GiB + W` and no aggregate `MemoryHigh`; its disjoint
Agent leaf SHALL have 1 GiB `MemoryHigh`, 2 GiB `MemoryMax`, and 1,024 tasks,
while its Worker subtree SHALL have `MemoryMax=W`, no protected memory, and
7,168 tasks.
A stable bootstrap SHALL place the Agent root and support processes in the Agent
leaf before ordinary startup and SHALL reject a process outside its assigned
leaf. Child task ceilings SHALL fit every parent ceiling. Worker I/O SHALL have
enforced read/write bandwidth ceilings against a qualified shared-device floor
or use a separate block device. Separate file/socket and mutable-storage bounds
SHALL remain enforceable.
Initialization SHALL fail before service start when it cannot enforce positive
Worker capacity and the complete control-plane reserve.
cgroup emptiness MUST NOT prove request-slot or Resource Allocation release.

#### Scenario: Worker exhausts a resource

- **WHEN** Workers and control-plane roles simultaneously pressure CPU, memory, process, file/socket, I/O, or storage boundaries
- **THEN** the Worker is contained and the Node reports bounded failure evidence
- **AND** Controller diagnostics and PostgreSQL recovery retain their reserved headroom

#### Scenario: Host is too small or lacks controls

- **WHEN** preflight cannot enforce the required cgroup controllers, CPU reserve, memory reserve, or storage boundary
- **THEN** appliance initialization fails before any service starts
- **AND** the host is not represented as a qualified appliance

### Requirement: Lifecycle Recovery Uses Durable Explicit Phases

Source preparation, initialization, start, stop, drain, upgrade, rollback,
backup, restore, retirement, and re-preparation SHALL serialize through one root-owned lifecycle lock and
fsynced monotonic operation receipts.
The appliance SHALL NOT claim a whole-host atomic transaction.
An interrupted operation SHALL resume idempotently from exact inputs or enter
`recovery_required` with services stopped or the Node unschedulable.
Binary rollback SHALL occur only when the source manifest declares the
current schema, retained state, authorization contract, every credential and
governance writer, audit semantics, ingress fence, and durable cutover state
compatible.
`SPEC.md` §10.11.4 and §13.3 SHALL remain authoritative; otherwise recovery
SHALL roll forward or restore the complete pre-upgrade set into an isolated
non-serving environment until the accepted restoration gate passes.

#### Scenario: Source upgrade stops after schema migration

- **WHEN** checkout transition and forward migration commit but later startup fails
- **THEN** the receipt records the exact current commit/tree, dependency/toolchain locks, installation UUID, and schema identity
- **AND** an incompatible old Controller is not started against the new schema

#### Scenario: Schema-compatible binary predates authorization cutover

- **WHEN** an older Controller or retained CLI writer can read the schema but cannot enforce the durable authorization contract
- **THEN** ingress and writer launch gates keep it isolated from the live authority store
- **AND** restoring historical data does not erase the cutover or reopen general serving

#### Scenario: Reboot interrupts any mutating phase

- **WHEN** the host reboots after a phase's first side effect but before terminal success
- **THEN** startup detects the nonterminal receipt and keeps unsafe dependants stopped
- **AND** only an exact resume, compatible rollback, or fenced restore may advance it

### Requirement: Backup Restore And Separation Prevent Identity Cloning

A complete backup SHALL use a consistent database snapshot after cordon, drain,
ingress closure, and fencing of Controller, Node, Worker, credential/grant,
governance, and direct-database writers.
It SHALL bind Product Version, source commit/tree, dependency/toolchain locks,
installation UUID, schema and authorization contract, non-secret configuration,
lifecycle receipts, and public identity metadata in a checksummed manifest.
It MUST NOT contain Controller or Node private keys, authorization roots,
plaintext or hashed Peer Grants, or reusable database credentials.
A successful backup-completion receipt SHALL require validation by restoring
the database and corresponding local public-generation metadata as one coherent
checkpoint into an isolated non-serving target.
Missing or failed validation, or disagreement between database authority and
local public-generation metadata, SHALL leave the backup incomplete.
Restore SHALL require a stopped empty target and proof that the source deployment
is fenced before existing Controller or Node identity is activated.
Stable IDs SHALL remain non-serving while each role generates a new key locally
and completes the accepted explicit certificate, authorization-root, replacement
grant, disconnect, and reconnect recovery.
Adding a remote Node SHALL use a new enrollment and identity; moving an existing
Controller or Node SHALL preserve exclusive private-key custody and apply every
required name, certificate, grant, and reconnect transition.

#### Scenario: Restore target cannot prove source fencing

- **WHEN** a restore would activate an existing Controller or Node identity while the source may still run
- **THEN** restore remains non-serving and fails closed
- **AND** credentials are not copied into a concurrent clone

#### Scenario: Replacement host restores without old private keys

- **WHEN** database and non-secret retained state are restored onto a fenced replacement host
- **THEN** no old private key is present or imported
- **AND** the stable Controller and Node IDs remain unschedulable until explicit new-key recovery and replacement Peer Grants complete

#### Scenario: Credential rotation overlaps backup request

- **WHEN** credential or Peer Grant rotation is active or begins before every relevant writer is fenced
- **THEN** backup does not declare a complete checkpoint
- **AND** interruption between database and local metadata capture cannot produce a successful incoherent set

#### Scenario: Isolated validation restore fails

- **WHEN** the backup cannot restore its database and corresponding local public-generation metadata coherently into an isolated non-serving target
- **THEN** no successful backup-completion receipt is recorded
- **AND** the candidate set is not eligible as a complete restore point

#### Scenario: One remote Node is added

- **WHEN** the single-host Controller expands to one remote private-network Node
- **THEN** the remote Node receives a distinct Node ID, private key, certificate, canonical name, admission decision, and pair grant
- **AND** local Controller and Node identities remain unchanged

### Requirement: Qualification Evidence Is Exact Bounded And Private

Qualification SHALL cover default-off clean source preparation; every role unavailable;
database unavailable, corrupt, and full; migration conflict/failure; permission
and symlink negatives; stale listeners; authenticated local BEAM; cancellation,
drain, orphan ambiguity; resource pressure; reboot; upgrade/rollback;
backup/restore; retirement/re-preparation; duplicate checkout/process/state/
lock/port/EPMD/BEAM/PostgreSQL/supervisor refusal; diagnostics; one remote Node;
Controller separation; and future packaging-handoff fencing.
Raw host evidence SHALL remain private and SHALL be bound to the exact source
commit/tree, dependency/toolchain locks, installation UUID, Ubuntu image,
kernel, glibc, systemd, PostgreSQL, filesystem, cgroup, and command identities.
Static validation, a successful boot, or contract acceptance MUST NOT establish
support.

#### Scenario: Only static validation has passed

- **WHEN** the OpenSpec package and repository checks pass without exact-host qualification
- **THEN** the contract may proceed to owner review
- **AND** implementation, release, deployment, and support remain unauthorized

#### Scenario: Support bundle is collected

- **WHEN** diagnostics are collected online or offline
- **THEN** the bundle contains bounded role, installation UUID, source, lifecycle, cgroup, port, database-health, and credential-metadata provenance
- **AND** it excludes private keys, passwords, DSNs, tokens, Peer Grant values or hashes, request bodies, model contents, raw environment, and unrestricted command output

### Requirement: Future Packaging Requires A Fenced Handoff

Debian package installation, qualification, publication, and support SHALL
remain outside this source-development profile. A future packaged distribution
SHALL require a fresh accepted OpenSpec change and a one-way handoff that fences
the source installation, imports compatible state once, records the authority
cutover, and prevents concurrent source and packaged Controllers.
Byte-for-byte BEAM or package reproducibility MUST NOT block this source profile
when exact Git tree, clean-checkout, dependency/toolchain lock,
generated-output drift, and runtime receipt evidence pass.

#### Scenario: A packaged migration is attempted without a handoff contract

- **WHEN** package tooling would install beside or adopt the source installation
- **THEN** the operation fails before identity or state mutation
- **AND** source qualification is not represented as package qualification
