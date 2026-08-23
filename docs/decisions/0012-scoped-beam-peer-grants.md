# ADR: Production BEAM uses scoped Peer Grants

## Status

Accepted on 2026-07-12.

## Context

ADR 0001 selects BEAM Distribution as Orchard's preferred live transport between admitted first-party Controller and Node Agent services.
PR #87 established Node Certificates with exact Node-ID and Controller-ID URI SAN validation as Orchard's durable internal identity anchors.
The packaged BEAM first cut still uses one manually distributed shared cookie and explicit target lists, which cannot provide per-Node authorization, rotation, or revocation.

Erlang/OTP 29 TLS distribution can validate certificate chains and certificate properties, and `net_kernel` can restrict claimed node names.
Those checks do not form one supported public hook that atomically correlates the peer certificate's Orchard identity, the claimed BEAM node name, and current Orchard admission state.
OTP distribution also always requires cookie authentication, `net_kernel:allow/1` is append-only, and neither certificate nor allowlist changes terminate an established connection.
The OTP cookie is therefore unavoidable transport authorization material, even though it must not become durable Node identity.

## Decision

Production first-party BEAM SHALL use OTP TLS distribution plus a scoped BEAM Peer Grant.
The Node Certificate remains the sole durable Node identity credential.
The BEAM Peer Grant authorizes one exact Controller instance and one exact admitted Node to form an OTP distribution connection for a bounded generation and time interval.
Neither the certificate nor the Peer Grant authorizes the connection alone.

The effective authorization decision is the conjunction of:

- exact Node and Controller Certificate validation;
- exact trusted-inventory BEAM names and addresses;
- an exact per-name Peer Grant cookie on both endpoints;
- current admitted grant state in Postgres;
- restricted private-network policy;
- explicit disconnection when authorization is revoked or replaced.

A BEAM Peer Grant SHALL be scoped to a version, purpose, cluster ID, Controller ID and BEAM name, Node ID and BEAM name, both certificate identifiers and fingerprints, authorization-root ID, grant ID, generation, issue time, not-before time, cutover time, and expiry time.
The initial grant validity SHALL default to 30 days with normal rotation beginning 7 days before expiry.
Only one active generation and at most one staged successor generation may exist for an exact Controller-to-Node pair.
Normal generation creation SHALL be rate-limited to protect the non-garbage-collected OTP atom table.

Each Controller instance SHALL own an independent BEAM Authorization Root with at least 256 bits of random key material.
The root SHALL remain separate from the node-signing CA, Controller Certificate private key, database credentials, and other cluster secrets.
It SHALL live in macOS Keychain or an owner-only Controller path and SHALL never be stored in Postgres or delivered to a Node.

The Controller SHALL derive the Peer Grant secret using HMAC-SHA-256 over a versioned, length-delimited canonical encoding of the complete immutable grant scope.
The encoded result SHALL be converted to an OTP cookie atom only from Controller-approved grant metadata.
Untrusted or externally supplied values SHALL never create atoms.
Postgres SHALL store the complete non-secret scope, closed lifecycle state, timestamps, delivery and activation evidence, and a SHA-256 hash of the encoded secret, never the plaintext Peer Grant or authorization root.
The lifecycle states are `pending_delivery`, `staged`, `active`, `superseded`, `revoked`, `expired`, and `delivery_failed`.
Only `active` authorizes ordinary new connections, while `staged` authorizes only its scheduled cutover.

The admission transition, decision, audit event, and one `pending_delivery` grant record per currently eligible Controller SHALL commit in one Postgres transaction or fail closed without partial state.
A Controller enrolled after admission SHALL obtain its grant through a separate leader-authorized atomic operation.
The Node SHALL retrieve each grant over certificate-authenticated control traffic only after explicit admission.
The Node SHALL store the plaintext grant atomically in its owner-only identity root, separately for each exact Controller ID and BEAM name.
Lost delivery responses SHALL be safely retryable because the same authorized generation derives the same secret.
A registered but unadmitted Node SHALL receive no production BEAM Peer Grant.

Rotation SHALL stage the successor on both endpoints, cut over at the agreed time, deliberately disconnect the existing distribution connection, and require the successor generation on reconnect.
Revocation SHALL update Postgres authority immediately, replace the exact-name cookie mapping, disconnect the peer, exclude its Runtime Endpoint from scheduling and queue capacity, and append a sanitized cluster-scoped audit event.
Revocation SHALL remain visibly incomplete until disconnection succeeds or the affected distribution process is restarted.
`net_kernel:allow/1` SHALL NOT be treated as a revocation mechanism.

Certificate renewal SHALL create a new Peer Grant generation bound to the renewed certificate identifiers and fingerprints.
Certificate renewal therefore drives Peer Grant rotation and a staged reconnect.
Re-admission SHALL create a new grant ID and generation after current trust and admission requirements succeed.
Decommission SHALL revoke every Peer Grant involving the Node, revoke its Node Certificate, disconnect it from every reachable Controller, and prevent reuse of the same Node ID, BEAM name, certificate, or grant.
Loss of a Controller's BEAM Authorization Root SHALL require explicit root recovery or creation of a new root followed by reissuance of every affected pair through certificate-authenticated control traffic.

## Active/Standby Controllers

Each Controller instance SHALL have a distinct stable Controller ID, Controller Certificate URI SAN, BEAM node name, BEAM Authorization Root, and Peer Grant with each admitted Node.
Active and Standby Controllers SHALL never share a Controller-to-Node Peer Grant.
Both Controllers may keep authenticated distribution connections for liveness, status, and explicitly read-only diagnostics.
Only the Active Leader may initiate inference execution, model mutation, cancellation, or lifecycle writes, enforced by the existing Postgres advisory-lock write gate before the operation leaves the Controller.

A Peer Grant proves Controller-instance membership, not current leadership.
The Node Agent cannot cryptographically prove that a connected Controller holds the Postgres advisory lock.
Orchard SHALL NOT invent a certificate field, cookie field, or Node-local leader flag that claims otherwise.
Failover SHALL require the promoted Controller to prove leadership through the Controller write gate before runtime mutation, but it SHALL NOT require Node re-enrollment or a new Peer Grant.

## Trusted Names And Targets

The enrolled product path SHALL derive canonical BEAM names and targets from trusted Controller and Node inventory.
Node Agent names SHALL use the complete Node ID without hyphens in the service component and the validated private IPv4 address in the host component.
Controller names SHALL use the complete Controller ID without hyphens in the service component and the validated private IPv4 address in the host component.
An address or BEAM name match alone SHALL never establish identity, admission, or Peer Grant authority.
Changing an advertised address changes the canonical BEAM name and requires a certificate-authenticated inventory update, a new Peer Grant, and deliberate reconnect.

Static target lists and shared cookies MAY remain in the documented Source-dev BEAM Operating Model and explicit compatibility paths.
They SHALL NOT establish trust or authorization for the enrolled Production BEAM Operating Model.

## High-trust boundary

Distributed Erlang membership is a high-trust code boundary, not a per-function capability sandbox.
A scoped Peer Grant reduces credential blast radius and cross-Node impersonation, but it does not restrict an authenticated peer to the `Orchard.Node.RuntimeEndpoint` facade.
The current BEAM adapter uses `:rpc.call`, and a connected peer can exercise broader distributed Erlang primitives.

Production BEAM is therefore limited to signed first-party Orchard releases on operator-controlled, admitted Macs inside restricted private networks.
External providers, third-party adapters, tenant-controlled compute, and partially trusted machines SHALL remain outside the BEAM mesh and use gRPC/mTLS or another explicit protocol adapter.
A compromised trusted Controller or admitted Node Agent remains inside this residual trust boundary.

## Alternatives rejected

### Enrollment PKI without a scoped Peer Grant

TLS verification is necessary but does not atomically bind the certificate's Orchard Node ID to the claimed BEAM node name and current admission through one supported OTP authorization hook.
OTP also still requires a cookie, so treating one shared cookie as a non-identity constant preserves excessive blast radius without closing the binding gap.

### One shared cluster cookie

A shared cookie grants cluster-wide symmetric authority, cannot be revoked per Node, and turns compromise of any copy into a cluster-wide credential event.
It remains a transitional source-development and packaged first-cut mechanism only.

### Random recoverable per-pair secrets

Random per-pair credentials would require plaintext or recoverably encrypted secrets in Postgres, or would make Controller restart and disaster recovery depend on unrecoverable local state.
Deterministic derivation preserves hash-only Postgres storage and lets each Controller rematerialize only its own authorized grants.

### A separate BEAM PKI

A second PKI would duplicate identity, renewal, revocation, and recovery surfaces while increasing drift from the enrollment identity established by PR #87.

### A custom distribution carrier

A custom carrier would add a large security-critical handshake and compatibility surface without turning distributed Erlang into a method-level authorization system.
The selected model keeps stock OTP TLS distribution and makes Orchard's additional authorization explicit.

## Platform portability scope

ADR 0023 accepts a Linux Controller as the first platform-expansion target, but this decision does not yet admit that profile to production BEAM Distribution.
Before support is declared, the Linux Controller release must prove immutable build provenance, exact release identity, protected certificate and Peer Grant custody, trusted BEAM names, network restriction, host controls, and mixed Linux Controller/macOS Node acceptance.

The first Linux Controller target remains a Controller Host and is not a schedulable Node unless a separately admitted local Node Agent satisfies the complete Node contract.
No shared cookie, certificate-only authorization, provider identifier, or successful transport probe may substitute for the scoped Peer Grant and durable admission requirements.

## Consequences

Production BEAM gains exact pair-scoped authorization, per-pair rotation, revocation, Active/Standby isolation, deterministic recovery, and visible failure without weakening Node Certificate identity.
Credential rotation and revocation cause a deliberate brief disconnect because OTP supports only one effective cookie per remote node name.
Orchard must supervise expiry, staging, cutover, disconnection, and recovery because OTP cookies have no native lifecycle.
The gRPC/mTLS control path remains required for enrollment, certificate lifecycle, Peer Grant delivery and recovery, explicit Runtime Endpoint compatibility, diagnostics, external adapters, and operator opt-out.
None of those roles permits automatic retry of a failed BEAM Runtime Endpoint operation through gRPC.
The Python and MLX Worker Runtime remains a Node Agent-local subprocess and never receives a Node Certificate, Peer Grant, or BEAM membership.

This decision does not close the packaged two-Mac smoke gap from PR #87.
Root-owned CLI, launchd, separate release processes, restart and reconnection, and the real two-Mac grant journey still require explicit packaged acceptance evidence.

## SPEC.md impact

`SPEC.md` requires updates to define the two-layer production BEAM identity and authorization model, Active/Standby pair grants, trusted target derivation, lifecycle and failure semantics, the high-trust boundary, retained gRPC roles, and the no-fallback rule.
The `operator-first-run-journey` OpenSpec package requires matching Section 3 tasks and acceptance scenarios before implementation begins.

## External grounding

This decision is grounded in the current Erlang/OTP 29 documentation for [TLS distribution](https://www.erlang.org/doc/apps/ssl/ssl_distribution.html), the [distribution handshake](https://www.erlang.org/docs/29/apps/erts/erl_dist_protocol.html), [`net_kernel`](https://www.erlang.org/doc/apps/kernel/net_kernel.html), [per-node cookies](https://www.erlang.org/doc/apps/erts/erlang.html), and [TLS hardening and revocation](https://www.erlang.org/docs/29/apps/ssl/ssl_hardening.html).
