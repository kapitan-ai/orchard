# Ubuntu 24.04 single-host source-development contract

This document defines the proposed `ubuntu_24_04_x86_64_single_host` profile.
It is a contract and qualification plan, not an implementation, release, or
support claim. The Repository Owner accepted its package-first predecessor on
2026-09-20 at commit `d323cc4d03fa3d21016f6aa9a3517ea71dcf0c5f`;
source implementation and host mutation remain held. The Repository Owner
separately accepted the package-first KAP-97 normative reconciliation at exact commit
`ec21ab93729b9533a3993ed1908da8874f0df452`, whose tree
`12ee4327a98abaf3bfbfe3c945331f0c435cdf48` is preserved by the rewritten local
commit `4cfea2ea615cb26d7880390c596a3bc53349b212`. That acceptance closes KAP-97
only; it does not complete KAP-82 or authorize KAP-98 or later implementation.
The owner accepted the KAP-107 source-development amendment on 2026-09-20 at
exact commit `3b0c5ae359cbcf67da881cd29d65a7df92fe11d6`.
It preserves the historical acceptances and supersedes KAP-98 only for the
near-term milestone. KAP-98's exact package commit
`b94f506a8d96bdbee9c62e3bb088666864f7e417`, artifact evidence, and
reproducibility findings remain valid deferred packaging/release inputs.
Acceptance authorizes neither implementation nor host mutation; KAP-99 through
KAP-106 and any replacement implementation issue remain separately gated.
The owner accepted the KAP-108 inert source-preparation implementation on
2026-09-20 at exact commit `f928bc5522eda92a372d3a2422aecfb629762698`.
That acceptance completes only the default-off foundation and authorizes no
real-host execution, activation, later issue, or support claim.
The owner accepted the KAP-99 isolated source-managed PostgreSQL lifecycle on
2026-09-21 at exact commit `d23b654e0f9d5b8335204b64a4e16200e65fbbe5`.
That acceptance completes only the source-only database lifecycle and
deterministic fixture gate. Real-host PostgreSQL execution and qualification,
later composition issues, host mutation, publication, deployment, and support
remain separately gated.
The owner accepted the KAP-101 inert model-free Worker custody and cgroup-v2
source foundation on 2026-09-21 at exact commit
`2f8923b919001b1038248f292865f0ceaf014f08`. That acceptance covers only the
source-bound static policy, disabled unit boundaries, deterministic budget and
custody classification, metadata-only launch validation, and isolated fixtures.
Real-host enforcement and pressure qualification, authenticated Worker
execution, providers, models, inference, later issues, packaging, publication,
deployment, and support remain separately gated. KAP-18 and KAP-26 remain the
only authorities for their terminal, cessation, request-capacity, allocation,
residency, and device-release boundaries.
The owner accepted the KAP-28 bundle-scoped preauthorized Node Admission
contract on 2026-09-21 at exact commit
`5544533123d494d3c124e3f5c44373db74be2c96`. The owner separately accepted the
bounded KAP-109 source implementation and isolated PostgreSQL validation on
2026-09-21 at exact commit `31b7186a46decf1edd609d3bdafeb7fd76d5d690`.
The remaining exhaustive admission scenario matrix is deferred hardening and
does not block KAP-100. Acceptance does not issue or redeem real credentials,
enroll or admit the local Node, authorize KAP-100 execution, qualify the host,
or establish support.
The owner accepts KAP-82's completed local certificate and Peer Grant
implementation as sufficient dependency evidence for separately authorized
KAP-100 same-host source implementation. KAP-82 and KAP-84 remain unqualified
and In Progress; KAP-84 mixed macOS/Linux evidence remains required for later
remote-topology and separation qualification, not this same-host source slice.
The owner accepted the KAP-100 inert authenticated same-host Controller and Node
source composition on 2026-09-21 at exact commit
`ed88a5313a9e57e5c541009c1f66dd8e9fef05ce`. That acceptance covers only exact
source and role identity binding, canonical private-address BEAM names,
default-off PostgreSQL-to-Node ordering, role-custody preflight, disabled gRPC
fallback, and deterministic isolated/database-backed source evidence. Real-host
activation, credentials, Peer Grants, Enrollment, admission, reboot and
failure-order qualification, Workers, providers, models, inference, later
issues, packaging, release, deployment, publication, remote topology, and
support remain separately gated. KAP-84 remains required for mixed-host and
remote-topology qualification.
The owner accepted the KAP-102 bounded source-only integrated lifecycle,
recovery, receipt, and redacted-diagnostics implementation on 2026-09-21 at
exact commit `715654ea9680376e5c8eb504433594a5af60fee1`. That acceptance covers
deterministic observation-driven lifecycle phases, monotonic intent/state/
terminal receipts, exact-evidence resume, fail-closed ambiguous or changed
evidence, source upgrade and rollback compatibility binding, fenced restore
evidence, and allowlisted offline diagnostics. Real Ubuntu activation,
PostgreSQL or credential/grant/Node mutation, reboot/crash-loop/interruption
qualification, live cgroup or Worker enforcement, providers, models, inference,
KAP-103, packaging, release, deployment, publication, qualification, and
support remain separately gated.

## Profile boundary and authority flow

The host tuple is exactly Ubuntu Server 24.04 LTS, x86_64, the accepted 24.04
kernel and glibc line, systemd 255 or newer, unified cgroup v2, the default
AppArmor posture, a stable RFC1918 IPv4 address, and a local filesystem that
provides atomic rename, durable fsync, ownership/mode enforcement, and the
declared quota boundary. Other Ubuntu releases and generic Linux are excluded.

```diagram
                         operator HTTPS / Admin API
                                      │
                                      ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Ubuntu Server 24.04 LTS x86_64 host                                 │
│                                                                      │
│  ┌────────────────────┐       Unix socket       ┌─────────────────┐ │
│  │ Controller         │◀───────────────────────▶│ PostgreSQL 16   │ │
│  │ orchard-controller │ runtime/migrate roles   │ postgres        │ │
│  │                    │                         │ durable truth   │ │
│  └─────────┬──────────┘                         └─────────────────┘ │
│            │ production BEAM TLS Distribution                       │
│            │ stable private IPv4 + exact certificates + Peer Grant  │
│            ▼                                                         │
│  ┌────────────────────┐   authenticated UDS   ┌───────────────────┐ │
│  │ Node Agent         │──────────────────────▶│ Worker Runtime    │ │
│  │ orchard-node       │ exact execution grant │ orchard-worker    │ │
│  │ host custody       │ and generation target │ provider-local    │ │
│  └────────────────────┘                       └───────────────────┘ │
│                                                                      │
│  systemd: root lifecycle only; separate identities, roots, logs,     │
│  credentials, units, and cgroups; no locality-derived authority      │
└──────────────────────────────────────────────────────────────────────┘
```

Authority remains separated as follows:

| Authority | Owner | Locality does not authorize |
| --- | --- | --- |
| Cluster governance, admission, scheduling, audit | Active Controller under PostgreSQL advisory-lock gates | Node custody, Worker execution, or database superuser actions |
| Durable product state and migration serialization | PostgreSQL | Controller readiness, Node health, or Worker capacity |
| Host, Node identity root, Worker process custody | Node Agent | Admission, scheduling, request terminalization, or allocation release |
| Provider process and execution | Worker Runtime under Node Agent grant | BEAM membership, Node Certificate use, direct Controller access, or independent scheduling |
| Source installation and service mutation | root through bounded lifecycle operations | Product governance or reusable runtime credentials |

The local Node may use a separately accepted bundle-scoped admission
preauthorization only when it binds the exact cluster, Enrollment, Node,
installation UUID, platform profile, source manifest, admission policy, and
current trust predicates. The administrator authorizes that future admission at
bundle issuance through Action Preview and confirmation; join only redeems the
durable one-use record. If an admission-only predicate drifts, otherwise valid
Enrollment may end at registered pending review, with no dispatch policy or
Peer Grant metadata. The lifecycle lock, fixed roots, local process ownership,
same-host address, and Controller readiness never supply admission authority.
Remote expansion creates a distinct Node and installation identity and cannot
reuse the local preauthorization.

## Source installation and version manifest

Exactly one Orchard source-development installation and one Controller are
permitted on a host. The installation uses canonical checkout
`/opt/orchard/source`, configuration root `/etc/orchard`, state root
`/var/lib/orchard`, runtime root `/run/orchard`, log root `/var/log/orchard`, and
backup root `/var/backups/orchard`. Alternative checkout or state roots are not
supported installation modes.

The root-owned `/var/lib/orchard/install/manifest.json` carries one random
installation UUID; root Product Version; full Git commit and tree; clean
checkout proof; exact target profile; dependency-lock and pinned-toolchain
digests; and Worker Runtime protocol identity. Inert preparation records the
exact Runtime Endpoint contract-artifact digest but declares schema and
Controller/Node compatibility support `undeclared`; later accepted lifecycle
issues must replace those undeclared dimensions with explicit supported values
before activation. The manifest contains no reusable secret. Build caches and
generated runtime bytes do not replace Git tree, lock, toolchain, and drift
evidence as source authority.

| Component | Payload and ownership | Prepared state |
| --- | --- | --- |
| Canonical source checkout | Root-owned clean Git tree and pinned dependency/toolchain locks | Prepared; no product process or identity |
| Controller | Portable Controller/Console source and dedicated unit | Disabled; no cluster identity |
| PostgreSQL integration | Exact Ubuntu PostgreSQL 16 dependency closure, cluster config, migration/backup operations | Disabled; uninitialized |
| Node Agent | Portable Node source and dedicated unit | Disabled; unenrolled |
| Worker provider | One separately accepted immutable provider closure | Optional, disabled, unqualified until its profile passes |
| Lifecycle tools | Root-only coordinator, preflight, receipts, diagnostics, backup/restore entry points | On-demand only |

Source preparation MUST NOT enable or start a unit, initialize PostgreSQL,
create product identities, enroll or admit a Node, activate a provider or model,
or publish capacity. Only the complete managed composition defines this
profile. A source checkout alone is not an installation, and a Controller-only
host remains only a Controller Host.

The KAP-108 foundation implements this preparation boundary through
`bin/orchard-source-installation prepare`. It installs only root-owned manifests,
monotonic receipts, fixed role roots, non-login role accounts, and inert unit
definitions guarded by an absent activation marker. `classify` is read-only and
distinguishes clean, prepared, resumable exact interruption, exact stale recovery,
and blocking foreign or ambiguous state. The isolated-root proof is
`scripts/test-source-dev-installation.sh`. This implementation is not host
qualification and grants no authority to initialize, reload, enable, start, or
support the composition.

Before preparing, mutating, or starting anything, the coordinator acquires
`/var/lib/orchard/install/lifecycle.lock` and proves that the canonical manifest
owns the checkout, state, runtime names, services, ports, PostgreSQL cluster,
EPMD, and BEAM identities. Another checkout claim, installation UUID, live
Controller, process supervisor, lifecycle owner, required listener, EPMD or
BEAM name, or PostgreSQL cluster blocks the operation. Exact stale evidence may
enter `recovery_required`; live, foreign, or ambiguous evidence is never killed,
adopted, overwritten, or merged.

## Service and identity manifest

| Unit | Identity | Ordering and readiness | Restart policy |
| --- | --- | --- | --- |
| `orchard-postgresql.service` | Root lifecycle coordinator; engine commands run as `postgres:postgres` | After local filesystems; ready only after exact cluster identity, recovery state, socket, and read/write probe pass | Bounded restart; repeated failure leaves dependants stopped |
| `orchard-db-migrate.service` | Root lifecycle coordinator; migration commands run as `orchard-db-migrate:orchard-db-migrate` | After DB readiness, before Controller; one-shot under migration advisory lock | No loop; durable failed receipt requires resume or restore |
| `orchard-controller.service` | `orchard-controller:orchard-controller` | After successful compatible migration; ready requires DB, leadership/read-only role, public transport, and identity checks | Bounded backoff; crash loop closes ingress readiness |
| `orchard-node-agent.service` | `orchard-node:orchard-node` | After network-online and Controller control readiness; active only after enrollment, admission, current credentials/grant, authenticated observation | Bounded backoff; no stale capacity publication |
| `orchard-worker-launcher.socket` / `.service` | `root:root` launcher; child becomes `orchard-worker:orchard-worker` | Socket-activated narrow launcher accepts only the local `orchard-node` peer and immutable provider/generation allowed by the source manifest | No independent Worker supervision or general systemd/root API |
| `orchard-source-dev.target` | none | Starts DB → migration → Controller → Node; target is reached only when role readiness is independently true | Never converts partial health into ready |

`orchard-source-dev.target` is not enabled by source preparation. Workers are
not independent units or target dependencies. The launcher drops identity and
executes each Worker inside a delegated, generation-scoped sub-cgroup of
`orchard-node-agent.service`, with an Agent-owned authenticated lifeline and
registered process identity. It accepts no arbitrary executable, argument,
environment, device, cgroup, signal, or service-manager operation. Agent stop or
crash closes the launch gate and `KillMode=control-group` terminates the complete
Agent/Worker cgroup; exact cgroup emptiness is required before replacement Agent
activation but does not independently release Orchard capacity.

The PostgreSQL, migration, and on-demand backup units expose the root-only
lifecycle coordinator because it owns the singleton lock, receipts, custody
checks, and identity transitions. The coordinator runs each database payload as
`postgres`, `orchard-db-migrate`, or `orchard-db-backup`; those identities do not
receive root lifecycle authority.

## Filesystem and secret custody manifest

All directories reject symlink components during privileged mutation. Immutable
payloads are root-owned and not writable by service users. Secrets use atomic
owner-only publication, fsync, and generation markers where their owning
contract requires it.

| Path | Owner : group / mode | Contents |
| --- | --- | --- |
| `/opt/orchard/source` | `root:root` / `0755` | Canonical clean source checkout; service identities cannot write it |
| `/opt/orchard/workers/<provider>/<version>` | `root:root` / `0755` | Optional immutable qualified provider closure |
| `/etc/orchard` | `root:root` / `0750` | Non-secret source-install configuration and generated host manifest |
| `/etc/orchard/controller` | `root:orchard-controller` / `0750` | Controller config and public TLS references |
| `/etc/orchard/node` | Existing Linux Node contract | Node config; no enrollment token retained |
| `/var/lib/orchard/controller` | `orchard-controller:orchard-controller` / `0700` | Controller identity, authorization root, durable local generations |
| `/var/lib/orchard/node` | `orchard-node:orchard-node` / `0700` | Node Identity Root and Peer Grants; never Controller-readable |
| `/var/lib/orchard/models` | `orchard-node:orchard-worker` / `0750` | Admitted read-only Worker model inputs; no identity material |
| `/var/lib/orchard/worker` | `orchard-worker:orchard-worker` / `0700` | Provider-local state and generation-scoped scratch only |
| `/var/lib/postgresql/16/orchard` | `postgres:postgres` / `0700` | PostgreSQL data directory |
| `/var/lib/orchard/install` | `root:root` / `0700` | Installation UUID, source manifest, lifecycle lock, receipts, compatibility and recovery state; no product secrets |
| `/var/backups/orchard` | `root:root` / `0700` | Checksummed, private-key-free backup sets and manifests; this source-development milestone makes no at-rest encryption claim |
| `/run/orchard-controller` | `orchard-controller:orchard-controller` / `0700` | Runtime-only sockets/files |
| `/run/orchard-node` | Existing Linux Node contract | Runtime-only lock/socket evidence |
| `/run/orchard-worker` | `orchard-node:orchard-worker` / `0710` | Generation-scoped authenticated Worker UDS paths |
| `/var/log/orchard/{controller,node,worker,install}` | Matching service owner; root-readable | Role-scoped redacted logs and receipts |

PostgreSQL owns database `orchard`, NOLOGIN owner role `orchard_owner`, runtime
role `orchard_controller`, migration role `orchard_migrator`, and backup role
`orchard_backup`. The runtime role has no role creation, replication,
tablespace, extension-install, or schema-owner authority. Migration and backup
credentials are delivered only to their one-shot units through protected
systemd credentials and are never readable by the Controller or Node Agent.

## Network and port manifest

The source lifecycle coordinator records one stable RFC1918 host address after proving it is
locally assigned and non-loopback. The firewall permits only the declared
sources. A stale or foreign listener blocks startup; Orchard never kills or
adopts an unknown listener.

| Endpoint | Bind / port | Access and purpose |
| --- | --- | --- |
| Controller HTTPS | configured private address / TCP `8443` | Operator/API clients; direct TLS, never plaintext production ingress |
| Controller gRPC control | configured private address / TCP `8444` | Certificate-authenticated enrollment, credential, Peer Grant, diagnostics control |
| EPMD | configured private address / TCP `4369` | One host EPMD for exact first-party BEAM names; private firewall only |
| Controller BEAM distribution | configured private address / TCP `52171` | TLS distribution, exact Controller certificate and pair grant |
| Node BEAM distribution | configured private address / TCP `52172` | TLS distribution, exact Node certificate and pair grant |
| Node gRPC compatibility/control | configured private address / TCP `9444` | Explicit mTLS compatibility/control only; never automatic fallback |
| PostgreSQL | `/run/postgresql/.s.PGSQL.5432` | Unix socket only; `listen_addresses=''` |
| Worker Runtime | `/run/orchard-worker/<unit>/<generation>.sock` | Authenticated generation-scoped UDS; no TCP listener |

Canonical names are
`orchard_controller_<controller-uuid-without-hyphens>@<private-ipv4>` and
`orchard_node_agent_<node-uuid-without-hyphens>@<private-ipv4>`. Colocation does
not permit `127.0.0.1`, `localhost`, source-development names, a shared cookie,
or static target trust. Address change follows the accepted inventory, name,
certificate, grant, disconnect, and reconnect lifecycle.

## cgroup-v2 and resource manifest

Qualification requires at least 8 logical CPUs, 32 GiB RAM, and storage with an
enforceable quota boundary. Let `M` be physical RAM and
`R_os = max(4 GiB, 10% of M)` and `W = M-R_os-17 GiB`. Initialization writes the
observed topology, measured shared-device I/O floor, and calculated limits into
the signed host manifest; changes require maintenance and requalification.

| cgroup | Required controls |
| --- | --- |
| `orchard.slice` | `MemoryMax=M-R_os`; non-overcommitted `MemoryMin=9G`; `TasksMax=12544`; accounting enabled for CPU, memory, I/O, tasks |
| `orchard-control.slice` | CPUs 0–1 reserved from Workers; `CPUWeight=1000`; `MemoryMin=4G`; `MemoryMax=6G`; `IOWeight=1000` |
| `orchard-controller.service` | control CPUs; `MemoryHigh=4G`; `MemoryMax=6G`; `TasksMax=2048`; file/socket limits from host manifest |
| `orchard-database.slice` | CPUs 0–1 reserved from Workers; `CPUWeight=1000`; `MemoryMin=4G`; `MemoryMax=8G`; `IOWeight=1000` |
| `orchard-postgresql.service` | database slice; `MemoryHigh=6G`; `MemoryMax=8G`; `TasksMax=2048`; data-volume I/O priority |
| `orchard-node-agent.service` lifecycle cgroup | aggregate `MemoryMin=1G`; `MemoryMax=2G+W`; `TasksMax=8192`; no aggregate `MemoryHigh`; `KillMode=control-group`; no database path access |
| Agent-only `agent` leaf | Node Agent root/support processes only; `MemoryMin=1G`; `MemoryHigh=1G`; `MemoryMax=2G`; `TasksMax=1024`; one control CPU available |
| Agent-owned `workers` subtree and `worker/<unit>/<generation>` leaves | excludes control CPUs; aggregate `MemoryMax=W`; `TasksMax=7168`; `CPUWeight=100`; `IOWeight=100`; read/write bandwidth each capped at 50% of the qualified shared-device floor; provider-specific device allowlist |
| Lifecycle and launcher helpers | `MemoryMax=512M`; aggregate `TasksMax=256`; no reusable product credential |

If CPU numbering/topology cannot provide two stable control CPUs, if physical
RAM is below 32 GiB, or if the calculated Worker budget is non-positive,
initialization fails before services start. Child memory protections sum to the
parent's non-overcommitted 9 GiB `MemoryMin`, task maxima fit each parent
ceiling, and Worker memory plus every non-Worker maximum fits `M-R_os`. A stable
Node bootstrap creates the delegated `agent` leaf, moves the Agent root into it
before ordinary startup, and rejects startup if the Agent or any Worker can
escape its assigned leaf. If the storage stack cannot enforce the recorded
bandwidth cap, the profile requires a separate Worker block device or fails
qualification. Worker mutable data uses a project quota or fixed-size
logical volume capped at 60% of the appliance data volume; PostgreSQL and
lifecycle receipts have distinct reserved space. At 15% free space Workers stop
accepting loads; at 10% the Node is cordoned and new API admission stops; at 5%
only bounded diagnostics, backup, cleanup, and recovery are permitted. Database
ENOSPC sets Controller readiness false and requires operator recovery; it never
triggers automated deletion or a fresh cluster.

The first implementation must prove these limits under pressure. Weight-only
configuration is insufficient. Simultaneous Worker, Controller, database, and
maintenance pressure; Worker OOM; fork bomb; file/socket exhaustion; and I/O
saturation must leave bounded Controller diagnostics and PostgreSQL recovery
access available.

## Lifecycle and recovery state machine

Every mutating operation takes `/var/lib/orchard/install/lifecycle.lock`,
writes an operation UUID and intended Product Version before its first side
effect, and advances fsynced monotonic receipts. A duplicate exact operation
resumes; conflicting input fails. A receipt never substitutes for live process,
database, certificate, or grant evidence.

The source-only coordinator consumes one bounded, root-supplied observation
whose installation UUID and source commit/tree match the prepared manifest. It
allowlists exact database, Controller, Node, Worker-custody, supervisor, and
reboot fields rather than ingesting raw command output. Each transition first
records its intended prior and target phases plus the observation checksum,
then publishes a fail-closed state and terminal receipt. Exact interruption may
resume against the identical observation; changed evidence becomes
`recovery_required`. This coordinator records and validates outcomes only: it
does not itself start services, initialize PostgreSQL, issue credentials, admit
a Node, or publish Worker capacity.

```diagram
┌────────────────────┐
│ source_prepared     │
└─────────┬──────────┘
          │ initialize identities, DB, limits
          ▼
┌────────────────────┐   backup   ┌─────────────────┐
│ initialized_stopped│───────────▶│ backup_complete │
└─────────┬──────────┘            └─────────────────┘
          │ start: DB → migrate → Controller → enroll/admit Node
          ▼
┌────────────────────┐
│ ready_composed     │
└────┬─────────┬─────┘
     │ stop    │ upgrade: cordon → drain → backup → stop
     ▼         ▼
┌──────────┐  ┌─────────────────┐
│ stopped  │  │ upgrade_prepared│
└────┬─────┘  └────────┬────────┘
     │ start           │ replace → migrate → reconcile
     └────────────┐    ▼
                  │  ┌────────────────┐
                  └─▶│ ready_composed │
                     └────────────────┘

Any uncertain mutation, migration, survivor, identity, or release proof
                         │
                         ▼
                 ┌─────────────────┐
                 │ recovery_required│
                 └───────┬─────────┘
                         │ exact resume, compatible rollback,
                         │ or fenced full restore
                         └───────────────────────────────▶ stopped
```

### Deterministic start and failure ordering

1. Preflight the canonical installation UUID, clean checkout commit/tree,
   dependency/toolchain locks, paths, modes, singleton identities, address,
   listeners, EPMD/BEAM names, PostgreSQL cluster, cgroup v2 controls, space,
   clock, and lifecycle receipt.
2. Start PostgreSQL and prove the expected cluster is out of recovery and
   accepts a bounded read/write transaction. Database readiness is not
   Controller readiness.
3. Run exactly one migration unit under the migration advisory lock. A conflict
   waits within the declared bound and then fails; migration failure leaves the
   Controller and Node stopped.
4. Start the Controller. Open public readiness only after database, schema,
   identity, transport, and leadership/read-only role checks pass.
5. Start the Node Agent. It remains unschedulable until the ordinary enrollment,
   admission, current certificate, exact Peer Grant, authenticated BEAM
   connection, and fresh observation gates pass.
6. Start no Worker solely because the target is reached. A qualified provider,
   exact authorization, allocation and generation target are prerequisites.

PostgreSQL loss closes Controller readiness and new scheduling. Controller loss
causes the accepted orphan and uncertainty behavior; the local Node cannot
promote itself. Node Agent loss withdraws fresh capacity and reconciles Workers
under KAP-18/KAP-26. Worker loss affects only its accepted unit/allocation scope
and cannot release capacity from process exit alone. Repeated unit crashes use
bounded backoff and open the existing breaker. Exact stale canonical evidence
may enter `recovery_required`; live, foreign, replaced, or ambiguous process,
listener, cgroup, lock, migration, identity, database, EPMD/BEAM, or supervisor
ownership blocks without termination or adoption.

### Upgrade and rollback

Upgrade is a fenced source transition, not an apt or package transaction:

1. verify the intended Git commit/tree, clean checkout, dependency/toolchain
   locks, generated-output drift checks, compatibility manifest, and preflight;
2. cordon the local Node, stop admission, drain, and prove every applicable
   KAP-18/KAP-26 release condition;
3. close ingress and stop Worker, Node Agent, Controller, and every retained
   credential, grant, governance, and direct-database writer while PostgreSQL
   remains available, proving each required cgroup and identity-root exclusion;
4. create and verify one complete pre-upgrade recovery checkpoint, then stop
   PostgreSQL;
5. move the canonical checkout to the exact intended commit, refresh pinned
   dependencies, build and validate without starting units or changing the
   installation UUID;
6. start PostgreSQL, acquire migration ownership, apply forward migrations, and
   record schema identity;
7. start Controller then Node Agent, reauthenticate the existing distinct
   identities, reconcile, and verify; and
8. uncordon only after a fresh accepted observation and all release/profile
   gates pass.

Controller `N` may operate Node Agent `N` and `N-1` only where the complete
accepted behavior contract is preserved. The source manifest pins one Product
Version and tree; the window is a recovery and staged-expansion bridge, not a
steady mixed-version installation. An interrupted partial upgrade remains stopped
unless the compatibility manifest explicitly permits the observed tuple.

Binary rollback is allowed only when the prior release declares the current
schema, retained-state, authorization contract, every credential/governance
writer, audit semantics, ingress fence, and durable cutover state compatible.
`SPEC.md` §10.11.4 and §13.3 remain authoritative: an older binary cannot rely
on schema readability alone, incompatible writers remain isolated from the live
authority store, and a historical restore remains non-serving until accepted
restoration gates pass. Otherwise recovery is roll-forward or a complete
restore of the pre-upgrade database and matching retained state. Failed or
ambiguous migration never starts an older Controller against a newer schema and
never drops data or erases durable cutover state automatically.

### Backup and restore

A backup set contains a checksummed manifest; Product Version and commit;
schema/migration and authorization-contract identity; source tree, dependency
and toolchain locks; PostgreSQL logical dump plus global role definitions
without reusable passwords;
Controller and Node public identity metadata; non-secret configuration; and
retained lifecycle receipts. Node/Controller private keys, authorization roots,
plaintext or hashed Peer Grants, reusable database credentials, Worker scratch,
loadedness, sampled capacity, ephemeral sockets, and process state are excluded.
Backup begins only after cordon/drain, ingress closure, and proof that Controller,
Node, Worker, credential/grant, governance, and direct-database writers are
stopped or fenced. PostgreSQL remains available only to the backup unit for one
consistent snapshot. Completion requires restore validation into an isolated
non-serving target and fails if local public-generation metadata and database
authority metadata do not describe one coherent checkpoint.

Restore requires a stopped, empty target and proof that the source deployment
is fenced. It restores database and non-secret retained state first while all
ingress and writers remain closed. Existing stable Controller and Node IDs stay
non-serving until each role generates a new private key locally and completes
the accepted explicit certificate/authorization-root recovery, replacement
Peer Grant, disconnect, and reconnect lifecycle. No private key leaves its
identity root. If the original host may still run, restore remains blocked until
explicit revocation/recovery prevents concurrent identity use. A historical
authority database remains isolated until `SPEC.md` §10.11.4 restoration gates
permit access. A topology migration that intentionally creates a new Node uses
enrollment, never restore or private-key copying.

Retirement disables source-development units and preserves database files,
identities, configuration, models, logs, backups, and receipts. Re-preparation
must recognize and validate retained installation UUID and state before start.
Destructive purge and a second installation are not part of this profile.

A future packaged distribution requires a fresh accepted OpenSpec proposal and
an explicit fenced handoff. It must stop and fence this source installation,
preserve or deliberately rotate each logical identity under its owning
contract, import compatible retained state once, record the authority cutover,
and prevent source and packaged Controllers from running concurrently. This
contract does not claim package installation, qualification, publication, or
support.

## Expansion and separation

Adding a remote Node uses the normal private-network enrollment and admission
path and creates a distinct Node identity and pair grant. The local Node remains
unchanged. Capacity is never inferred from sharing the Controller host.

Controller/database separation is a planned outage in this first profile:
cordon and drain all Nodes, back up, fence the old Controller and database,
restore or migrate durable state to the accepted target, move the existing
Controller identity only after proving exclusive private-key custody, update the
trusted address/name inventory, rotate affected certificates and Peer Grants,
then reconnect each Node. The local Node keeps its Node ID and private key; a
new canonical Controller address creates the grant/name lifecycle required by
the existing contract. Retiring the local Node uses decommission and revocation,
not deletion or reuse. HA and identity cloning remain excluded.

## Diagnostics and support evidence

Each service writes structured journald events under its own unit and bounded
role logs under its own log root. Metrics identify role, Product Version,
profile, and non-secret operation/generation IDs. Audit events remain
Controller-governed durable records and are never reconstructed from debug logs.
Request capture and hidden-reasoning policy remain unchanged.

The root-only support bundle collector records the exact host/profile/source
manifest, Git commit/tree and clean-state proof, dependency/toolchain locks,
installation UUID, systemd and cgroup state, readiness, bounded PostgreSQL health and
schema identity, port ownership, certificate/grant metadata without values,
redacted role logs, lifecycle receipts, quota/space state, and checksums. It
refuses private keys, passwords, DSNs, tokens, Peer Grant values/hashes, request
bodies, model contents, raw environment, and unrestricted command output. An
offline collection path must produce the same bounded schema.

The source-only offline diagnostic command emits only the allowlisted profile,
product/source provenance, installation UUID, lifecycle classification and
checksums, component classifications, and hard-false serving/scheduling/Worker
capacity fields. It never copies the input observation, environment, logs, or
arbitrary files into its output. Full host support-bundle collection and
support qualification remain later gates.

## Qualification matrix and private-evidence plan

Raw host evidence remains private execution material. Only sanitized summaries
bound to the exact commit and tree, dependency/toolchain locks, image, kernel, glibc, systemd,
PostgreSQL, filesystem, cgroup and command identities may be promoted to a
review or issue. The kapitan host is a later qualification target, not authority
for this contract and must not be mutated under KAP-96.

| Gate | Deterministic repository/VM evidence | Later exact-host private evidence | Pass condition |
| --- | --- | --- | --- |
| Prepare/default-off | Source-manifest and isolated-root tests | Clean canonical Ubuntu Server 24.04 image | One canonical checkout/UUID; no unit enabled/running; no identity or DB initialized |
| Singleton/duplicate refusal | Duplicate checkout, UUID, PID, lock, port, EPMD/BEAM, PostgreSQL, and supervisor fixtures | Real conflicting processes and stale-state recovery | Live/foreign/ambiguous owners fail before mutation; exact stale state enters bounded recovery only |
| Identity/path negatives | Ownership, mode, symlink, hardlink, duplicate-lock fixtures | Real service users and filesystems | Every cross-role read/write and symlink substitution fails closed |
| Database | Disposable PostgreSQL 16 cluster; migration conflict/failure fixtures | Reboot, corruption copy, ENOSPC/quota exercise | Socket-only, least privilege, exclusive migration, no false readiness or deletion |
| Authenticated local BEAM | Certificate/grant/name/generation fixtures | Stable private-address same-host connection | No loopback/cookie shortcut, no fallback, forced disconnect and stale-result rejection |
| Startup/failure ordering | systemd VM fault injection | Power/reboot and crash-loop exercise | DB → migrate → Controller → Node ordering; partial failure never publishes capacity |
| Worker custody | Model-free fake providers; Agent crash/stop with survivor injection | Qualified provider later | Narrow launcher only; complete Agent cgroup cleanup before replacement; release still obeys KAP-18/KAP-26 |
| Isolation | Simultaneous multi-role cgroup pressure harness | CPU, RAM, PID, fd/socket, disk and I/O exhaustion | Hierarchical budgets hold and Controller diagnostics/DB recovery retain reserved headroom |
| Upgrade/rollback | Every source/schema/authority-compatible and incompatible tuple; crash after each receipt | Exact-commit candidate upgrade and rollback rehearsal | Incompatible binary/writer cannot access live authority store; exact recovery is deterministic |
| Backup/restore | Rotation-race and interruption fixtures; isolated restore without old private keys | Full fenced replacement-host rehearsal | One coherent checkpoint; local new-key recovery; no private-key export or concurrent clone |
| Retire/re-prepare | Isolated-root retention matrix | Retire/re-prepare/reboot | Retained data is untouched and revalidated; no destructive purge or second installation |
| Expansion | Multi-VM local plus one remote Node | Private-network remote Node | New identity/grant; local identities unchanged; no address-only trust |
| Separation | Fenced migration simulation | Dedicated approved target later | Exclusive identity custody, explicit grant/name rotation, no clone |
| Diagnostics | Golden redaction and bounded-size tests | Offline bundle under each failure | Useful provenance with no listed secret or request-content class |

The acceptance run must exercise clean source preparation; every duplicate
identity/process/lock/port/EPMD/BEAM/PostgreSQL/supervisor class; each role absent; PostgreSQL
unavailable, corrupt, and full; migration conflict and failure; stale listeners;
permission and symlink attacks; reboot during each lifecycle phase; Controller,
Node, and Worker independent restart; cancellation, drain, and orphan ambiguity;
simultaneous resource exhaustion; credential rotation during backup; rollback
after a durable authorization cutover; restore without old private keys; upgrade,
rollback, backup, restore, retirement, re-preparation, one remote Node, future
packaging-handoff fencing, and no-fallback behavior. Static validation or one
healthy boot is insufficient.

## Recommendation and stop gate

Disposition: **PROCEED with separately scoped implementation planning; HOLD
implementation and host mutation pending plan acceptance.** Inference activation
additionally waits for the applicable KAP-18/KAP-26 contracts and an accepted
Worker provider.
Any need for loopback trust, shared cookies or credentials, unrecoverable
PostgreSQL ownership, permissive mixed-version startup, unenforceable control
headroom, identity cloning, or outbound-session semantics requires revision and
keeps the hold in place.
