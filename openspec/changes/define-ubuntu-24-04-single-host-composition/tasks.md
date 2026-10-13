## 1. Contract acceptance

- [x] 1.1 Record the Repository Owner's 2026-09-20 acceptance of ADR 0037, the platform manifest, and this OpenSpec change at commit `d323cc4d03fa3d21016f6aa9a3517ea71dcf0c5f`.
- [x] 1.2 Reconcile accepted behavior into `SPEC.md` §§1.1, 1.4–1.5, 2, 4.1–4.9, 7.5, 10.5–10.7, 11–13, and Milestones 8–9 and the synchronized main OpenSpec capabilities without changing support status. The Repository Owner accepted the exact result under KAP-97 at commit `ec21ab93729b9533a3993ed1908da8874f0df452`; review-history refactor commit `4cfea2ea615cb26d7880390c596a3bc53349b212` preserves its tree `12ee4327a98abaf3bfbfe3c945331f0c435cdf48`.
- [x] 1.3 Resolve the KAP-82 repository-status conflict and predecessor synchronization while retaining KAP-27 as canceled.
- [ ] 1.4 Obtain real KAP-84 mixed-host qualification before representing the private-network credential/Peer Grant dependency as qualified for remote-topology or separation work; it is not a prerequisite for the bounded same-host source implementation.
- [x] 1.5 Record the Repository Owner's 2026-09-20 acceptance of the KAP-107 amendment at exact commit `3b0c5ae359cbcf67da881cd29d65a7df92fe11d6`.
- [x] 1.6 Record the Repository Owner's 2026-09-21 bounded disposition that KAP-82's completed local certificate and Peer Grant implementation is sufficient dependency evidence for separately authorized KAP-100 source implementation, without marking KAP-82 or KAP-84 qualified or authorizing KAP-100 execution.

## 2. Superseded package foundation and source replacement

- [x] 2.1 Preserve KAP-98's exact compatibility metadata and coordinated default-off package source/evidence as deferred packaging work; it is not current installation authority.
- [x] 2.2 After KAP-107 acceptance, close KAP-98 as superseded for the near-term milestone while preserving exact commit `b94f506a8d96bdbee9c62e3bb088666864f7e417`, artifact evidence, and deferred packaging/release findings.
- [x] 2.3 Implement one canonical source checkout, installation UUID, fixed roots, exclusive lifecycle lock, and deterministic duplicate checkout/process/state/port/EPMD/BEAM/PostgreSQL/supervisor refusal in separately authorized KAP-108.
- [x] 2.4 Prove through isolated-root deterministic fixtures that source preparation creates no cluster, Node Admission, enabled unit, provider activation, or support claim; exact-host execution remains separately gated.
- [x] 2.5 Record the Repository Owner's 2026-09-20 acceptance of the KAP-108 inert source-preparation implementation at exact commit `f928bc5522eda92a372d3a2422aecfb629762698`; acceptance does not authorize real-host execution, activation, later program issues, or support.

## 3. PostgreSQL and Controller lifecycle

- [x] 3.1 Implement socket-only PostgreSQL 16 cluster ownership and separate runtime, migration, and backup roles under KAP-99; real-host execution remains separately gated.
- [x] 3.2 Implement exclusive migration, corruption/disk-full failure, writer-fenced private-key-free backup, explicit new-key restore recovery, retention, and re-preparation behavior under KAP-99 using isolated deterministic fixtures only.
- [x] 3.3 Record the Repository Owner's 2026-09-21 acceptance of the KAP-99 isolated source-managed PostgreSQL lifecycle at exact commit `d23b654e0f9d5b8335204b64a4e16200e65fbbe5`; real-host execution, qualification, later issues, publication, deployment, and support remain separately gated.
- [x] 3.4 Implement source-only Controller startup/readiness outcome validation and stale-listener refusal after database/schema checks; real service activation remains under task 7.2.

## 4. Authenticated local Node composition

- [x] 4.0 Record the Repository Owner's 2026-09-21 acceptance of the bounded KAP-109 preauthorized Node Admission source implementation and isolated PostgreSQL validation at exact commit `31b7186a46decf1edd609d3bdafeb7fd76d5d690`; the remaining exhaustive security matrix is deferred hardening and does not block KAP-100, whose execution remains separately gated.
- [x] 4.1 Implement the inert KAP-100 source composition with canonical private-address Controller and Node names, exact installation and role identities, role-custody paths, deterministic PostgreSQL-to-Node ordering, and no loopback, static-cookie, static-target, address-only trust, or automatic gRPC fallback.
- [x] 4.2 Prove the KAP-100 source wiring against the accepted enrollment, admission, certificate and Peer Grant lifecycle through deterministic isolated-root and database-backed security, reconnect, rotation, revocation, forced-disconnect, stale-observation-fencing, and no-fallback tests. This source evidence does not satisfy real-host or mixed-host qualification.
- [x] 4.3 Prove independent Controller, Node Agent, database, and reboot failure ordering without false capacity in deterministic source-only fixtures; real reboot and crash-loop qualification remains under task 7.2.
- [x] 4.4 Record the Repository Owner's 2026-09-21 acceptance of the bounded KAP-100 inert authenticated same-host source composition at exact commit `ed88a5313a9e57e5c541009c1f66dd8e9fef05ce`; acceptance does not authorize or qualify real-host activation, credentials/grants, Enrollment/admission, reboot/failure ordering, Workers/providers/models, inference, KAP-102, packaging, publication, release, deployment, remote or mixed-host topology, or support, and KAP-84 remains the later remote-topology gate.

## 5. Isolation and Worker prerequisites

- [ ] 5.1 Enforce and simultaneously pressure-test the hierarchical cgroup-v2 CPU, memory, task, file/socket, hard I/O, quota, OS, and reserved-headroom budget on the exact host; source-only static evidence does not complete this gate.
- [ ] 5.2 Keep Worker/provider startup and capacity disabled until the applicable KAP-18 and KAP-26 contracts and one provider profile are accepted.
- [ ] 5.3 Complete the authenticated narrow Worker execution boundary and real Agent crash/stop, survivor, model-free cancellation, drain, orphan, restart, and uncertain-release tests without granting general root or systemd authority.
- [x] 5.4 Record the Repository Owner's 2026-09-21 acceptance of the KAP-101 inert model-free Worker custody and cgroup-v2 source foundation at exact commit `2f8923b919001b1038248f292865f0ceaf014f08`; acceptance is limited to source-manifest custody, static budgets, disabled unit boundaries, metadata-only validation, fail-closed classification, and isolated fixtures, and does not authorize or qualify real-host enforcement, authenticated Worker execution, providers/models, inference, later issues, packaging, publication, deployment, or support.

## 6. Lifecycle, recovery, and topology qualification

- [ ] 6.1 The source-only lifecycle now uses one interruption-safe intent/terminal receipt path and proves exact resume versus fail-closed changed evidence; complete exact-host interruption injection after every prepare/start/source-upgrade/rollback/backup/restore/retire phase remains required under task 7.2.
- [ ] 6.2 Qualify schema, retained-state, authorization-contract, writer, audit, ingress, and cutover compatibility across mixed-version and forward-migration rollback tuples.
- [ ] 6.3 Prove retirement/re-preparation retention, one new remote Node, fenced Controller/database separation, and a future packaging handoff that cannot run two Controllers or clone identity.
- [x] 6.4 Produce deterministic allowlisted offline source diagnostics for every source-observation failure class; journald and real-host support-bundle evidence remains under task 7.2.
- [x] 6.5 Record the Repository Owner's 2026-09-21 acceptance of the bounded KAP-102 source-only integrated lifecycle, recovery, receipt, and redacted-diagnostics implementation at exact commit `715654ea9680376e5c8eb504433594a5af60fee1`; real Ubuntu activation, PostgreSQL/credential/grant/Node mutation, reboot/crash-loop/interruption qualification, live cgroup/Worker enforcement, providers/models, inference, KAP-103, packaging, publication, release, deployment, qualification, and support remain separately gated.

## 7. Validation and support gate

- [ ] 7.1 Run strict OpenSpec validation and the applicable Elixir, source-lifecycle, security, static, and coverage workflows.
- [ ] 7.2 Run the exact private qualification matrix on canonical Ubuntu Server 24.04 LTS x86_64 and retain raw evidence privately.
- [ ] 7.3 Obtain independent security/lifecycle review bound to the exact candidate commit/tree, dependency/toolchain locks, and installation UUID.
- [x] 7.4 After synchronization, review the affected main specs for incomplete prose such as `Purpose TBD` and run strict validation for all specs.
- [ ] 7.5 Require a separate explicit support, publication, release, and deployment decision; contract or qualification success alone is insufficient.
