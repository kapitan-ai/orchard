## Context

The accepted Linux Controller target assumes operator-provided external
PostgreSQL. The experimental `ubuntu_24_04_x86_64_node` candidate is Node-only.
The proposed appliance must compose those role semantics with a local database
without inventing a second architecture or treating localhost as authority.

KAP-18 still owns bounded delivery, drain, native cessation, and request-slot
release. KAP-26 still owns Worker Unit, runtime incarnation, Resource
Allocation, residency, and device release. The private-network credential and
Peer Grant lifecycle remains a prerequisite. This design therefore closes the
composition contract while holding source implementation and inference
activation behind their owners.

## Goals / Non-Goals

**Goals:**

- Preserve distinct role identity, authority, custody, and failure semantics.
- Make source preparation, boot, readiness, failure, upgrade, rollback, backup,
  restore, retirement, and expansion deterministic and testable.
- Reserve enforceable control-plane resources before Worker capacity.
- Permit a later remote Node or Controller/database separation without identity
  reinvention or cloning.

**Non-Goals:**

- Source implementation, package build/publication, host mutation, or support.
- Generic Linux, Ubuntu 26.04, HA, NAT traversal, or outbound sessions.
- Provider/model qualification or inference activation.
- Redefining KAP-18 or KAP-26 release and allocation semantics.

## Decisions

### One canonical source installation preserves role ownership

Exactly one root-owned checkout at `/opt/orchard/source`, one installation UUID,
and one Controller are permitted per host. Fixed `/etc/orchard`,
`/var/lib/orchard`, `/run/orchard`, `/var/log/orchard`, and
`/var/backups/orchard` roots preserve separate role identities, credentials,
cgroups, logs, and retirement behavior. The source manifest pins exact Git
commit/tree, clean-checkout proof, dependency/toolchain locks, Worker Runtime
protocol identity, and the exact Runtime Endpoint contract-artifact digest.
Inert preparation declares schema and Controller/Node support undeclared until
later accepted lifecycle work publishes explicit supported values. Preparation
is default-off and creates no cluster or Node authority.

The lifecycle coordinator fails before mutation or start when another checkout,
Controller, installation/state identity, lock owner, listener, EPMD/BEAM name,
PostgreSQL cluster, or supervisor is live, foreign, or ambiguous. Exact stale
evidence may enter recovery, but unknown owners are never killed or adopted.
Multiple checkouts and Controllers were rejected because they make local
authority ambiguous. Coordinated Debian packages are deferred; KAP-98 retains
their experimental source and evidence for future packaging work.

### PostgreSQL is locally managed but not Controller-owned

Use PostgreSQL 16 from the exact Ubuntu dependency closure in the source manifest.
PostgreSQL retains its service identity and data ownership. Orchard owns a
dedicated local cluster contract, socket-only access, database and role layout,
one-shot migration/backup units, lifecycle receipts, and recovery flow. Runtime,
migration, and backup credentials remain separate; the Controller is never a
database superuser or host lifecycle manager.

An external database does not meet the single-host managed outcome. Bundling an
opaque database engine duplicates Ubuntu lifecycle and security ownership.

### Same-host BEAM uses production identity, not localhost trust

Controller and Node names use their distinct persisted UUIDs and the host's
validated stable RFC1918 IPv4 address. Production TLS Distribution requires
exact certificates, admission, one active scoped Peer Grant, current
generations, and forced disconnect obligations. Loopback names, shared/static
cookies, address-only trust, and automatic gRPC fallback are invalid.

This costs an address-bound migration when the Controller moves, but proves the
same path used by a later remote Node. Loopback BEAM was rejected because it
would require identity reinvention during separation.

### systemd orders roles but does not create authority

The start order is PostgreSQL readiness, exclusive compatible migration,
Controller readiness, then Node Agent. The Node still passes enrollment,
admission, credential, Peer Grant, authenticated observation, lifecycle,
health, and capacity gates. Worker processes start only under separately
accepted authorization. A dependency edge or green unit never creates product
readiness or scheduling capacity.

Workers are not sibling systemd units. A narrow root launcher authenticates the
local Node Agent, accepts only an immutable provider and generation from the
active compatibility manifest, drops to `orchard-worker`, and execs the process
inside a delegated sub-cgroup of `orchard-node-agent.service`. It exposes no
general command, environment, signal, device, cgroup, service-manager, package,
or root API. Agent stop or crash closes the launch gate and
`KillMode=control-group` must prove every Worker descendant gone before a
replacement Agent activates. That proof remains separate from KAP-18/KAP-26
release authority.

### cgroup v2 reserves the control plane

The exact profile requires at least 8 logical CPUs and 32 GiB RAM. Let `M` be
physical RAM, `R_os = max(4 GiB, 10% of M)`, and `W = M-R_os-17 GiB`. The parent
appliance slice is capped at `M-R_os` and carries a non-overcommitted
`MemoryMin` equal to the sum of its 4 GiB Controller, 4 GiB database, and 1 GiB
Agent protections. The Node lifecycle cgroup is capped at `2 GiB + W` without
an aggregate throttle; its disjoint Agent leaf has 1 GiB `MemoryMin`, 1 GiB
`MemoryHigh`, 2 GiB `MemoryMax`, and 1,024 tasks, while the Worker subtree has
`MemoryMax=W`, no protected memory, and 7,168 tasks. A stable bootstrap moves
the Agent into its leaf before startup. Worker I/O has a hard read/write
bandwidth ceiling against the qualified shared-device floor, or uses a separate
block device when that ceiling cannot be enforced. Separate file/socket and
mutable-storage bounds complete the budget. Initialization records the
calculated topology in the host manifest and fails when any control, consistent
hierarchy, or positive headroom cannot be enforced.

cgroup emptiness remains process evidence only. It cannot satisfy KAP-18 or
KAP-26 release conditions.

### Durable phases replace false appliance atomicity

A root-only coordinator serializes mutations with one lock and fsynced monotonic
receipts. Every phase is idempotently resumable or terminates in
`recovery_required`. Forward-only migrations make some binary rollback
impossible; the compatibility manifest authorizes a prior binary only when
schema, retained state, authorization contract, every writer, audit, ingress,
and durable cutover state remain compatible. `SPEC.md` §10.11.4 and §13.3
override schema readability. Otherwise recovery requires roll-forward or an
isolated, non-serving full pre-upgrade restore through the accepted restoration
gate.

### Source upgrade and future packaging remain fenced

An upgrade moves only the canonical clean checkout to one exact commit after
cordon, drain, writer fencing, and a verified recovery checkpoint. It refreshes
pinned dependencies, builds without starting units or changing the installation
UUID, then restores PostgreSQL, migration, Controller, and Node ordering.
Rollback uses the same schema, retained-state, authorization, writer, audit,
ingress, and cutover gates as before.

A future packaged distribution requires a fresh accepted OpenSpec proposal and
one-way handoff that fences the source installation, imports compatible state
once, records the cutover, and prevents concurrent source and packaged
Controllers. Exact Git tree, clean checkout, dependency/toolchain locks,
generated-output drift, and runtime receipts provide source provenance;
byte-for-byte BEAM/package reproducibility is deferred packaging/release work.

### Restore and separation require exclusive identity custody

Backup is a consistent checksummed set created after cordon/drain and fencing
every product and credential writer. It contains no private keys, authorization
roots, Peer Grant values or hashes, or reusable database credentials. Restore
requires a stopped empty target and proof that the source is fenced. Stable IDs
remain non-serving while each role creates a new local key and completes the
accepted explicit credential and grant recovery. Preserving one logical
Controller or Node identity is migration, not key copying or cloning. Adding a
Node always creates a new identity. Address/name changes follow the accepted
certificate and grant lifecycle.

## Normative synchronization and credential dependency

KAP-97 synchronizes the owner-accepted composition contract directly into
`SPEC.md` and the five affected main OpenSpec capabilities without archiving
this still-unimplemented change. The active deltas therefore become full
`MODIFIED` requirements over the synchronized baseline and remain open for the
implementation tasks below.

This synchronization binds same-host authentication to the current normative
§7.5.0 contract. ADR 0035, the accepted authenticated-connection amendment,
`SPEC.md`, and synchronized OpenSpec capabilities now agree, and the accepted
Linux Node predecessor is synchronized. KAP-82 nevertheless remains open
because real KAP-84 mixed-host `N` and `N-1` qualification is incomplete.
The Repository Owner accepts KAP-82's completed local certificate and Peer Grant
implementation as sufficient for separately authorized KAP-100 same-host source
implementation. KAP-84 evidence remains required for remote-topology and
separation qualification; neither KAP-82 nor KAP-84 is globally qualified or
complete.

## Risks / Trade-offs

- **Single correlated failure domain:** the profile claims no HA; failure
  correlation must never manufacture health or free capacity.
- **Resource limits may reject small hosts:** enforceable recovery headroom is
  preferred over an appliance that deadlocks under Worker pressure.
- **PostgreSQL lifecycle is substantial:** exact backup/restore and disk-full
  evidence is required before implementation can claim reproducibility.
- **Address-bound identity complicates moves:** explicit migration is safer than
  hidden localhost trust or cloned keys.
- **Dependency contracts are not all accepted:** implementation remains held;
  model-free contract validation can precede Worker activation later.

## Migration Plan

There is no accepted Linux single-host installation to migrate. After owner
acceptance, work must be split into separately reviewed implementation slices:
singleton source preparation and preflight, PostgreSQL lifecycle, Controller
service, authenticated local Node,
resource isolation, recovery/diagnostics, model-free Worker custody, and later
provider qualification. Each slice remains default-off and cannot claim
support.

Expansion and Controller/database separation are qualification scenarios, not
automatic implementation in the first slice.

## Open Questions

- Which accepted Worker provider and exact resource/device profile will be the
  first appliance inference qualification target?
- Which KAP-18 terminal condition will authorize request-slot release?
- Which KAP-26 allocation/incarnation contract will authorize Worker and device
  reuse after restart or uncertainty?
- What future packaging and publication policy will be proposed after
  source-development implementation and qualification? This contract does not
  answer or authorize it.
