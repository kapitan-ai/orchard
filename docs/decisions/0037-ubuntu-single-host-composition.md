# ADR: Compose Ubuntu single-host roles with one source-development installation

## Status

The package-first predecessor of this decision was accepted by the Repository
Owner on 2026-09-20 under KAP-96 at contract commit
`d323cc4d03fa3d21016f6aa9a3517ea71dcf0c5f`.

The Repository Owner accepted its KAP-97 package-first normative `SPEC.md` and
OpenSpec reconciliation on 2026-09-20 at exact commit
`ec21ab93729b9533a3993ed1908da8874f0df452`. An owner-authorized review-history
refactor replaced that commit with
`4cfea2ea615cb26d7880390c596a3bc53349b212`; both commits identify the exact tree
`12ee4327a98abaf3bfbfe3c945331f0c435cdf48`.

That acceptance closed KAP-97 only and did not satisfy or authorize completion
of KAP-82 or any implementation child.

This record does not establish support, authorize package publication, or reopen
the canceled outbound-session work in KAP-27.

On 2026-09-20 the Repository Owner accepted the KAP-107 amendment at exact
commit `3b0c5ae359cbcf67da881cd29d65a7df92fe11d6`. It replaces the
near-term coordinated Debian-package decision with one canonical
source-development installation per host while preserving the historical
KAP-96 and KAP-97 acceptances above. KAP-98 is superseded for the near-term
milestone, not discarded or invalidated; its exact package source at
`b94f506a8d96bdbee9c62e3bb088666864f7e417`, artifact evidence, and
reproducibility findings remain deferred packaging/release inputs.

KAP-107 acceptance authorizes neither source implementation nor host mutation.
KAP-99 through KAP-106 remain Backlog, and any replacement source-development
implementation issue requires separate owner authorization.

On 2026-09-21 the Repository Owner accepted KAP-82's completed local
certificate and Peer Grant implementation as sufficient dependency evidence for
separately authorized KAP-100 same-host source implementation. KAP-82 and
KAP-84 remain In Progress and unqualified; KAP-84 mixed macOS/Linux evidence
remains a later remote-topology and separation gate. This disposition preserves
certificate, Peer Grant, Runtime Endpoint, and no-locality-shortcut requirements
and does not itself authorize KAP-100 execution.

On 2026-09-20 the Repository Owner accepted the KAP-108 inert
source-development lifecycle foundation at exact commit
`f928bc5522eda92a372d3a2422aecfb629762698`. This acceptance completes the
default-off foundation only. It does not authorize real-host execution, service
activation, PostgreSQL initialization, credentials, Worker/provider/model
activation, inference, later program issues, publication, or support.

On 2026-09-21 the Repository Owner accepted the KAP-99 isolated
source-managed PostgreSQL lifecycle implementation at exact commit
`d23b654e0f9d5b8335204b64a4e16200e65fbbe5`. This acceptance completes the
source-only database lifecycle gate and its deterministic isolated fixtures. It
does not authorize real-host PostgreSQL initialization or execution, kapitan
mutation, full database-backed qualification, KAP-100, KAP-101, publication,
deployment, or support.

On 2026-09-21 the Repository Owner accepted the KAP-101 inert model-free Worker
custody and cgroup-v2 source foundation at exact commit
`2f8923b919001b1038248f292865f0ceaf014f08`. This acceptance completes only the
source-manifest custody, static resource-budget, disabled unit-boundary,
fail-closed classification, and deterministic isolated-fixture gate. It does
not authorize real-host cgroup or service enforcement, authenticated Worker
execution, providers, models, inference, KAP-100, KAP-102, packaging,
publication, deployment, or support, and it does not satisfy KAP-18 or KAP-26
release authority.

On 2026-09-21 the Repository Owner accepted the KAP-100 inert authenticated
same-host Controller and Node source composition at exact commit
`ed88a5313a9e57e5c541009c1f66dd8e9fef05ce`. This acceptance completes only
the exact source identity, private-address BEAM name, default-off ordering,
role-custody preflight, no-fallback, and deterministic isolated/database-backed
source-test gate. It does not authorize or qualify real Ubuntu activation,
credentials, Peer Grants, Enrollment, admission, reboot or failure-order
execution, Workers, providers, models, inference, KAP-102, packaging,
publication, release, deployment, remote or mixed-host topology, or support.
KAP-84 remains the later remote-topology qualification gate.

On 2026-09-21 the Repository Owner accepted the KAP-102 bounded source-only
integrated lifecycle, recovery, receipt, and redacted-diagnostics implementation
at exact commit `715654ea9680376e5c8eb504433594a5af60fee1`. This acceptance
completes only deterministic observation-driven phase validation, monotonic
receipt and exact-resume behavior, fail-closed recovery, source upgrade and
rollback compatibility binding, fenced restore evidence, and allowlisted
offline diagnostics. It does not authorize or qualify real Ubuntu activation,
PostgreSQL or credential/grant/Node mutation, reboot/crash-loop/interruption
qualification, live cgroup or Worker enforcement, providers, models, inference,
KAP-103, packaging, release, deployment, publication, or support.

## Context

Orchard has a portable Controller target, an experimental
`ubuntu_24_04_x86_64_node` candidate, a provider-neutral Worker Runtime boundary,
and private-network certificate and Peer Grant contracts. It does not yet have a
Linux distribution that composes a Controller, managed PostgreSQL, Node Agent,
and Worker Runtime on one host.

Colocation creates correlated failure and lifecycle ordering, but it must not
collapse role identity or authority. A localhost address, Unix account, process,
systemd dependency, database row, or successful probe cannot replace Node
Enrollment, Node Admission, a Node Certificate, a scoped Peer Grant, Controller
leadership, Worker authorization, or the release boundaries owned by KAP-18 and
KAP-26.

## Decision

Define `ubuntu_24_04_x86_64_single_host` as a proposed distribution and
acceptance profile over the exact Ubuntu Server 24.04 LTS x86_64 host tuple. It
composes one Controller instance, one locally managed PostgreSQL 16 cluster, one
separately enrolled and admitted local Node Agent, and zero or more qualified
Node Agent-owned Worker Runtimes. It does not broaden the existing Linux Node
candidate or qualify Ubuntu 26.04, generic Linux, a runtime provider, model, or
Serving Profile.

For the near-term milestone, use exactly one source-development installation per
host rather than Debian packages. Its root-owned canonical checkout is
`/opt/orchard/source`; its fixed configuration, state, runtime, log, and backup
roots are `/etc/orchard`, `/var/lib/orchard`, `/run/orchard`,
`/var/log/orchard`, and `/var/backups/orchard`. A root-owned installation
manifest binds one random installation UUID, exact Git commit and tree, clean
checkout proof, Product Version, dependency locks, pinned toolchain, and Worker
Runtime protocol identity. Inert preparation records the exact Runtime Endpoint
contract-artifact digest while declaring schema and Controller/Node support
undeclared; activation requires later accepted lifecycle work to publish
explicit supported values. Source provenance replaces package byte identity for
this milestone; byte-for-byte BEAM and package reproducibility are deferred to a
future packaging/release contract.

KAP-108 implements only the inert source-preparation foundation: canonical
provenance and installation manifests, exclusive lock and monotonic prepare
receipts, fixed roots, role accounts, guarded unit definitions, duplicate-owner
refusal, and exact stale-state classification. It neither implements later
database/authenticated-composition/Worker gates nor qualifies a host. The
prepared units remain disabled and additionally refuse activation until a later
accepted issue supplies the missing authority and lifecycle behavior.

There is exactly one lifecycle owner, one installation UUID, and one Controller
per host. A second checkout, Controller, installation/state identity, lifecycle
owner, service supervisor, EPMD or BEAM name, PostgreSQL cluster, or required
listener is not an alternate installation mode. Preflight fails before mutation
or start when any such owner is live, foreign, or ambiguous. Exact stale state
may enter explicit recovery; Orchard never kills, adopts, overwrites, or merges
an unknown owner. Preparing the checkout and inert service definitions does not
initialize a cluster, enroll or admit a Node, enable a provider, start
inference, or publish capacity.

Use Ubuntu's PostgreSQL 16 engine from the exact source-development dependency
closure. Orchard owns a dedicated cluster configuration, database, roles,
migration operation, backup contract, and lifecycle receipts; PostgreSQL
retains the `postgres` service identity and engine-file ownership.
PostgreSQL listens on its Unix-domain socket only. Runtime, migration, and backup
credentials are distinct. The Controller never receives superuser, package, or
database-cluster lifecycle authority.

The Controller runs as `orchard-controller`, the Node Agent as `orchard-node`,
the Worker Runtime as `orchard-worker`, and PostgreSQL as `postgres`. All are
non-login service identities. No two roles share a writable state directory,
private key, Peer Grant, database credential, or generic service account. A
root-owned source lifecycle coordinator may perform checkout, toolchain,
PostgreSQL, and systemd lifecycle operations, but it is not a long-running
product authority and cannot issue
Node, Controller, Worker, or database governance decisions.

Production Controller-to-Node traffic uses the existing private-network BEAM
profile even when both processes are on one host. Both canonical names use the
host's validated stable RFC1918 IPv4 address and their complete, distinct UUIDs.
Loopback names, a static/shared cookie, certificate-only trust, address-only
trust, and automatic gRPC fallback are prohibited. Enrollment, admission,
certificate issuance, Peer Grant delivery, rotation, revocation, forced
disconnect, reconnect, and stale-connection fencing remain unchanged. The gRPC
control path retains only its accepted certificate-authenticated roles.

Place services under one appliance slice with separate control, database, Node
Agent, and Worker cgroups. Admission requires unified cgroup v2 and enforceable
CPU, memory, task, file, socket, I/O, and mutable-storage limits. The generated
host manifest reserves control-plane headroom before any Worker budget is
calculated. Worker exhaustion cannot consume the reserved Controller,
PostgreSQL, or operating-system budgets. cgroup emptiness is process-custody
evidence only; it does not prove public terminal delivery, native execution
cessation, request-slot release, or Resource Allocation release.

Worker processes remain descendants in delegated sub-cgroups of the Node Agent
unit. A narrowly authorized root launcher may drop to `orchard-worker` and exec
only an immutable provider named by the active compatibility manifest; it grants
no shell, arbitrary command, package, systemd, device-reconfiguration, or
general root authority. Agent stop or crash closes the launch gate and systemd
kills the complete unit cgroup before a replacement Agent may start.

Represent prepare, initialization, migration, start, drain, upgrade, rollback,
backup, restore, and retirement as durable phases with an exclusive installation
lifecycle lock and receipts. There is no false whole-host transaction. A phase
failure keeps dependent services stopped or unschedulable and directs the
operator to an idempotent resume, compatible rollback, or explicit restore.
Forward-only schema migration may make binary rollback unavailable; rollback is
permitted only when the compatibility manifest proves schema, retained-state,
authority-contract, writer, audit, ingress, and credential-cutover compatibility,
or by restoring the complete pre-upgrade backup into a fenced non-serving
recovery deployment. `SPEC.md` §10.11.4 recovery and restoration gates remain
authoritative and a historical restore cannot erase a durable authority cutover.

Expansion does not reinterpret the local Node as the Controller. A remote Node
is enrolled and admitted with a new Node ID, private key, certificate, canonical
name, and pair grant. Separating the Controller or database preserves stable
logical identity only through an explicit fenced migration that rotates names,
addresses, certificates or grants where their accepted contracts require it.
Private keys and identities are never copied to create a concurrent clone.

The detailed source, service, filesystem, port, cgroup, lifecycle, recovery,
diagnostic, and qualification contract is in
`docs/platforms/ubuntu-single-host.md` and the subordinate OpenSpec change.

## Consequences

The composition has more accounts, units, roots, and explicit phases than a
single process, but failures and privileges stay attributable to their owning
roles. Local operation follows the same trust path needed for later remote
Nodes and Controller separation.

The fixed private-address requirement means a host address change is an
identity-bound migration, not transparent roaming. Single-host operation also
has one correlated failure domain and no HA claim. Backup and rollback require
planned downtime for the first profile.

KAP-18 remains authoritative for bounded delivery, cancellation, drain, native
cessation, and request-capacity release. KAP-26 remains authoritative for Worker
Unit identity, runtime incarnation, Resource Allocation, residency, and device
release. Until their applicable contracts are accepted and implemented, the
composition may qualify source preparation and model-free role lifecycle but cannot
activate inference or claim schedulable Worker capacity.

## Alternatives Rejected

**Multiple source checkouts or Controllers on one host** were rejected because
they make installation, process, state, port, database, and BEAM authority
ambiguous and permit two local claimants to one host composition.

**Coordinated Debian role packages for the near-term milestone** were superseded
by the owner-approved source-development direction. KAP-98 preserves the exact
experimental package work for a future packaging proposal; it is not current
installation or qualification authority.

**One monolithic service account** was rejected because it merges payload,
credential, lifecycle, and retirement custody.

**Operator-provided external PostgreSQL** remains the accepted Linux Controller
profile but does not satisfy this appliance's locally managed database outcome.

**A bundled opaque PostgreSQL tree** was rejected because Ubuntu's supported
PostgreSQL packages provide a reproducible engine baseline without transferring
database superuser authority to the Controller.

**Loopback BEAM with a shared cookie** was rejected because locality is not
identity or authorization and would make later separation a new architecture.

**gRPC as an automatic local fallback** was rejected because it can duplicate
an ambiguously accepted Runtime Endpoint operation and violates the selected
transport contract.

**Identity cloning during separation or restore** was rejected because two live
hosts with one Controller or Node private key destroy custody and revocation
meaning.

## Accountable Recommendation

**PROCEED with owner review of the KAP-107 amendment; HOLD implementation and
host mutation pending acceptance of its exact commit and separate implementation
authorization.** The amended contract retains the applicable private-network
credential gates and keeps inference disabled until KAP-18 and KAP-26 close the
release and allocation boundaries used by the selected Worker profile.

## SPEC.md Impact

KAP-107 amends §§1.4–1.5, 2, 4.1–4.9, 7.5, 10.5–10.7, 11, 12.1–12.7,
13.1–13.8, and Milestones 8–9 to replace near-term package authority with the
singleton source-development installation while retaining local managed
PostgreSQL, authenticated same-host topology, isolation, recovery, and later
separation contracts. It changes neither current support claims nor the
existing `ubuntu_24_04_x86_64_node` identity or product behavior.
