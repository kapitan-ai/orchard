## Context

Orchard targets one to four Apple Silicon Macs and supports all-in-one, Controller-plus-worker, and Active/Standby topologies.
The current build has several pieces of a first-run experience, but no single durable journey explains their order or status.

Current app and packaging behavior includes:

- A verified app-primary DMG and app-owned root-authorized `install`, `update`, `uninstall`, and `status` lifecycle.
- Universal `all`, `controller`, and `node-agent` Install Roles.
- A guided packaged CLI sequencer through `orchardctl init` and its `orchardctl first-run` alias.
- External Postgres as a current Controller prerequisite.
- A local, one-shot, audited `orchardctl cluster init` first-admin credential path.
- Console and CLI node admission review, Action Preview, rejection history, and lifecycle actions.
- A packaged multi-Mac BEAM first cut using a manually shared root-owned cookie and explicit Controller targets.
- A secure enrollment tracer with Node Enrollment Bundles, pinned HTTPS redemption, Node Certificates, exact Node-ID and Controller-ID SAN validation, explicit admission, and authenticated gRPC compatibility activation.
- Local model import and lower-level worker acquisition paths without a finished controller-hosted distribution experience.

The selected target contract includes Bootstrap Tokens, locally generated Node keys, controller-signed Node Certificates, explicit Node Admission, authenticated Runtime Endpoint observations, controller-hosted artifacts, guided app onboarding, and Playground inference.
Those target pieces are not all implemented.

## Goals

- Give operators and contributors one durable path from release media to first inference.
- Prevent current compatibility and rehearsal behavior from being presented as finished enrollment or model distribution.
- Make trust boundaries and retained state explicit at every stage.
- Define observable target outcomes without forcing UI details before domain operations exist.
- Order implementation slices so each one is a coherent end-to-end improvement.
- Make the first recommended product-code slice specific enough to implement and review independently.

## Non-Goals

- Product implementation beyond the first narrow Section 3 task 3.2 tracer does not belong in this change.
- This change does not make Node Admission implicit.
- This change does not make Runtime Endpoint observation a trust proof.
- This change does not change the packaged BEAM-first direction.
- This change implements only the one-Controller/one-Node task 3.2 tracer of the node-bound production BEAM identity and authorization design.
- This change does not enter the remaining Section 3 custody, connected-peer revocation, rotation, operational-surface, Active/Standby, packaging, or two-Mac slices.
- This change does not promise model transfer time independent of artifact size or network throughput.

## Decision 1: Use One Three-Layer Journey Document

The durable document has three explicit layers:

1. Current supported journey, written in present tense and linked to runbooks.
2. Target operator journey, written as product intent and observable outcomes.
3. Gap map and ordered improvement slices, including recovery and measurement boundaries.

Topology differences appear in one shared document rather than separate runbooks.
This keeps common prerequisites, trust boundaries, and terminology consistent while allowing all-in-one, Controller-only, and Controller-plus-worker paths to diverge where necessary.

Detailed commands stay in existing packaging and local-development runbooks.
The journey document summarizes outcomes and links to those commands.

## Decision 2: Enroll A Node, Not A Worker Runtime

The product may use the action label **Add a worker**, but the durable domain resource is a Node running the Node Agent.
The Worker Runtime remains a local subprocess supervised by the Node Agent.
It does not receive enrollment material or join the cluster independently.

The canonical term is **Node Enrollment Bundle**.
It is distinct from a Bootstrap Token, Node Certificate, Node Admission, API Token, and BEAM cookie.

## Decision 3: Keep Enrollment, Admission, Activation, And Readiness Separate

The target state progression is:

```text
installed
  -> provisioned
  -> registered
  -> admitted
  -> active
  -> model-ready
  -> inference-verified
```

`installed`, `model-ready`, and `inference-verified` are journey milestones rather than new Node Lifecycle State values.
The existing Node Lifecycle State machine continues to own `provisioned`, `registered`, `admitted`, and `active`.

A successful transport connection or Runtime Endpoint observation never skips registration or Node Admission.
A registered Node remains visibly pending until an administrator admits it.
An admitted Node becomes active only after a fresh healthy authenticated observation.

## Decision 4: Node Enrollment Bundle Is A Narrow One-Time Trust Artifact

One bundle enrolls exactly one Node.
The target bundle is versioned, one-use, short-lived, inspectable, revocable, and auditable.

It contains:

- Bundle format and enrollment identifier.
- Stable cluster identifier and optional human-readable cluster name.
- Stable Controller identifier that will be required in the later runtime mTLS client certificate SAN.
- Allocated stable Node identifier.
- Controller HTTPS address.
- Controller trust pin or public trust-anchor material.
- One one-time Bootstrap Token.
- Issued and expiry timestamps.
- Optional intended display name, pool, or bounded policy hints.

It never contains:

- A BEAM cookie.
- A cluster-admin, operator, tenant, or inference credential.
- A Controller or node-signing CA private key.
- A Node private key.
- A long-lived Node Certificate.
- A database credential or DSN.
- A static Runtime Endpoint target list.

The Controller stores the Bootstrap Token secret only as a hash and prefix.
It also persists the enrollment identifier, allocated Node reference, creator, lifecycle timestamps and state, expected Controller identity, CSR fingerprint after redemption begins, certificate issuance outcome, and sanitized audit context required for safe resume and review.
The Node private key is generated and retained only on the Node Agent host.

The default expiry is one hour and the maximum accepted expiry is 24 hours.
The implementation may later tighten those values based on supported deployment evidence without weakening one-use behavior.

## Decision 5: Authenticate The Controller Before Sending The Bootstrap Token

The joining Node Agent validates the pinned Controller trust material before transmitting the Bootstrap Token.
There is no short-token mode that silently trusts the first Controller response.

The target join exchange is:

1. Parse and validate the bundle locally.
2. Reject unsupported format, wrong cluster, wrong Node, or local expiry before network access.
3. Generate the Node keypair locally and persist it atomically in protected Node Agent state before any redemption request.
4. Create a CSR bound to the allocated Node identifier and the persisted local key.
5. Connect to the bundle's Controller address.
6. Validate the Controller trust pin and presented chain.
7. Submit the Bootstrap Token, CSR, bounded inventory, and advertised endpoint metadata.
8. Atomically consume the Bootstrap Token.
9. Issue a Node Certificate bound to the Node identifier and return the internal runtime trust chain plus the expected stable Controller identifier.
10. Persist the Node Certificate, internal trust chain, and expected Controller identifier atomically beside the local private key.
11. Transition `provisioned -> registered`.
12. Report that administrator admission remains required.

The Controller never reconciles Node identity from hostname, IP address, display name, BEAM node name, or target string alone.
The Node Agent accepts later runtime mTLS only when the Controller client certificate chains to the enrolled internal trust authority and carries the exact stable Controller-id SAN established by the bundle and registration result.

## Decision 6: Secure Enrollment Was The First Implementation Slice

Three sequences were considered.

### Guided Setup First

This sequence would immediately reduce Controller setup friction.
It was not selected first because the UI or sequencer would still stop at manual worker cookie distribution and static targets or would encode those temporary mechanics into the product flow.

### Controller-Hosted Model Distribution First

This sequence would remove a major first-inference blocker.
It was not selected first because secure distribution needs an authenticated admitted Node identity and channel, while current pre-staging remains an explicit workaround.

### Secure Node Enrollment First

This sequence gives existing admission review a trusted registered Node, removes the largest security ambiguity, and creates the authenticated identity needed by later model distribution.
It is selected.

The first product-code tracer covers one configured Controller and one Node Agent.
It starts after app or PKG role installation and ends when the Node is `active` through a fresh authenticated Runtime Endpoint observation.
It excludes model transfer, Playground, multi-Node bulk issuance, Managed Database Mode, and app UI.
PR #87 delivered that tracer through certificate-backed gRPC compatibility activation.
The post-merge smoke passed focused and full validation, coverage, real ephemeral HTTPS, and certificate-backed mTLS gRPC paths.
Root-owned packaged CLI, launchd, separate release processes, restart and reconnection, and a two-Mac enrollment journey remain an explicit acceptance gap.

## First Tracer Interfaces

The exact command spelling remains implementation-reviewable, but the shaped command family is:

```text
orchardctl nodes enrollment create --output PATH [--expires-in DURATION] [--node-name LABEL] [--pool-id ID]
orchardctl node join --enrollment-bundle PATH
```

Controller-side issuance:

1. Preflights exclusive owner-only output creation before mutation.
2. Uses the local Controller runtime authority boundary and leader-only write gate.
3. Requires stable cluster identity, Controller HTTPS identity, and an initialized or imported internal node-signing authority.
4. Creates a `provisioned` Node placeholder with a stable Node identifier.
5. Creates one Bootstrap Token scoped to that Node and cluster.
6. Stores only the secret hash and prefix.
7. Writes the bundle once to the chosen path.
8. Records a cluster-scoped audit event without secret material.
9. Records a safe output-failure state if committed issuance cannot be delivered.

Node-side join follows Decision 5 and leaves the Node `registered`.
Existing admission preview and execution then move it to `admitted`.
Dynamic target resolution derives the Runtime Endpoint from trusted Node inventory.
A fresh healthy authenticated observation moves the Node to `active`.

## Runtime Transport For The Secure Enrollment Tracer

The first certificate-authenticated Runtime Endpoint proof extended the existing gRPC compatibility adapter with the mTLS behavior required by `SPEC.md` §10.6.
PR #87 added the Node Agent TLS listener, Controller client credentials, CA validation, and exact Node-ID and Controller-ID SAN validation against the identities persisted during enrollment.
The enrollment identity, certificate, admission, and dynamic target work remain transport-independent.

This tracer does not change the packaged BEAM-first direction.
ADR 0012 now defines the node-bound, revocable production authorization model before the enrolled product path uses BEAM without reintroducing a cluster-wide cookie as identity.

## Registration Retry And Concurrency

Bootstrap Token consumption is atomic.
Concurrent first use permits at most one successful Node identity.

If the Controller consumes the token and the response is lost, the join may resume only with the same enrollment identifier, durably held Node key, and persisted CSR fingerprint.
A retry with different key material fails closed.

The enrollment record persists certificate issuance state so a crash before issuance, after issuance, or before response delivery can be distinguished without minting a second identity.
The Node Agent persists its key before redemption and persists the returned certificate and runtime trust binding atomically before reporting registration complete.

Expired, consumed, revoked, wrong-cluster, or wrong-Node bundles do not create additional Node rows or Node Certificates.
Standby or leadership-unproven Controllers reject issuance and registration mutations through the existing write-path semantics.

An observation that arrives before registration remains a Runtime Endpoint Admission Candidate.
Registration may reconcile earlier candidate evidence only through the certified Node identity.
Target-string equality is never reconciliation authority.

## Decision 7: Production BEAM Uses Scoped Peer Grants

Production first-party BEAM uses OTP TLS distribution plus one BEAM Peer Grant for each exact Controller-to-Node pair.
The Node Certificate remains the durable Node identity anchor.
The Peer Grant is bounded transport authorization and is invalid without the corresponding Node and Controller Certificates.

This choice resolves an OTP 29 limitation rather than replacing certificate trust.
TLS certificate verification can inspect the peer certificate, and `net_kernel` can restrict claimed node names, but stock OTP exposes no supported public hook that atomically correlates the certificate's Orchard Node ID, the claimed BEAM node name, and current Orchard admission state.
OTP also always requires a cookie for distribution.
The complete Orchard authorization decision is therefore the conjunction of exact certificate validation, an inventory-derived BEAM name, an exact per-name Peer Grant cookie, current admitted grant state, private-network policy, and explicit disconnection on revocation.

Each Controller instance owns a separate BEAM Authorization Root with at least 256 bits of random key material.
The root is separate from the node-signing CA and Controller Certificate private key, lives in protected Controller-local storage, never enters Postgres, and is never delivered to a Node.
The Controller derives each pair secret with HMAC-SHA-256 over a versioned, length-delimited encoding of the grant's immutable Controller, Node, certificate, name, generation, and time scope.
Postgres stores durable Controller-instance identity plus each grant's non-secret scope, closed lifecycle state, lifecycle evidence, and encoded-secret hash rather than the plaintext secret or root.
Grant state is `pending_delivery`, `staged`, `active`, `superseded`, `revoked`, `expired`, or `delivery_failed`; only `active` authorizes ordinary new connections and `staged` authorizes only its scheduled cutover.

The admission transition, decision, audit event, and one `pending_delivery` grant record per currently eligible Controller commit in one Postgres transaction or fail closed without partial admission.
A Controller enrolled after admission obtains its grant through a separate leader-authorized atomic operation.
The Node retrieves the authorized generation through certificate-authenticated control traffic and stores it atomically in owner-only identity state.
Deterministic derivation makes a lost delivery response safely retryable after the identities, certificates, admission, generation, and expiry are revalidated.
A registered but unadmitted Node receives no production Peer Grant.

The initial validity is 30 days, with normal rotation beginning 7 days before expiry.
Only one active generation and at most one staged successor generation may exist for an exact pair.
Rotation stages the successor on both endpoints, cuts over at an agreed time, deliberately disconnects the old connection, and requires the new generation on reconnect.
Revocation updates Postgres authority immediately, excludes the Runtime Endpoint, replaces the exact-name cookie mapping, disconnects the peer, and remains visibly incomplete until disconnection succeeds or the distribution process is restarted.
`net_kernel:allow/1` is not a revocation mechanism because its allowlist is append-only and it does not terminate established connections.

Certificate renewal creates a new Peer Grant generation bound to the renewed certificate identifier and fingerprint.
Re-admission creates a new grant ID and generation after current trust and admission succeed.
Decommission revokes every grant involving the Node, revokes its Node Certificate, disconnects it from every reachable Controller, and prevents identity or grant reuse.
Loss of a Controller's BEAM Authorization Root requires explicit restoration or a new root followed by reissuance of every affected pair through certificate-authenticated control traffic.

Active and Standby Controllers have distinct stable Controller IDs, Certificate URI SANs, canonical BEAM names, BEAM Authorization Roots, and grants with every admitted Node.
Both may keep authenticated connections for liveness, status, and explicitly read-only diagnostics.
Only the Active Leader may send mutating runtime operations, enforced by the Postgres advisory-lock write gate before the operation leaves the Controller.
A Peer Grant proves Controller-instance membership, not advisory-lock leadership.
The Node Agent cannot cryptographically prove that a connected Controller owns the Postgres advisory lock, and the product must not claim otherwise.

The enrolled product derives canonical Node Agent and Controller BEAM names from complete stable UUIDs plus validated private IPv4 inventory.
It derives Runtime Endpoint targets only from current trusted inventory and active or staged-for-cutover grant state.
An address or name match alone never establishes identity or authorization.
Static target lists and shared cookies remain limited to documented source-development and compatibility operation.

Distributed Erlang membership is a high-trust code boundary, not a per-function capability sandbox.
The current BEAM adapter uses `:rpc.call`, so a Peer Grant limits who may enter the relationship but does not constrain the admitted peer to individual Runtime Endpoint functions.
Production BEAM is limited to signed first-party Orchard services on operator-controlled admitted Macs inside restricted private networks.
External providers, third-party adapters, tenant-controlled compute, and partially trusted machines stay outside the BEAM mesh.

gRPC/mTLS remains for enrollment, certificate lifecycle, Peer Grant delivery and recovery, diagnostics, explicit Runtime Endpoint compatibility, external adapters, and operator opt-out.
Recovery control traffic is not permission to retry a failed BEAM Runtime Endpoint operation through gRPC.
The Python/MLX Worker Runtime remains a Node Agent-local subprocess and never receives a Node Certificate, Peer Grant, or BEAM membership.

## First Section 3 Implementation Tracer

The first Section 3 product-code tracer uses one Controller and one Node Agent with real separate BEAM nodes and real TLS distribution.
It proves that no grant exists before admission, admission authorizes one exact pair grant, certificate-authenticated delivery is retryable, the BEAM target derives from trusted inventory without a static product target, and an authenticated BEAM status observation advances `admitted -> active`.

The public-interface security matrix includes wrong Node Certificate SAN or fingerprint, wrong BEAM name, wrong or another Node's pair secret, missing grant, expired grant, revoked grant, wrong generation, unadmitted Node, static target without trusted inventory, revocation while connected, incomplete disconnection, lost delivery response, lost Controller root, and BEAM failure without gRPC fallback.

The tracer excludes Active/Standby failover, automated normal rotation, Controller Certificate and authorization-root rotation, multi-Node issuance, dynamic address roaming, app UI, model distribution, external Runtime Endpoints, Worker Runtime changes, and any claim of per-function BEAM sandboxing.
The separate packaged acceptance gap covers root-owned CLI, launchd, separate releases, restart and reconnection, and a two-Mac journey.

## Model Distribution And First Inference

Controller-hosted model distribution follows secure enrollment and production transport hardening.
The Controller stores one verified Artifact Bundle and authorizes selected admitted Nodes to fetch it over an authenticated internal channel.
Node Agents verify hashes and optional signatures before changing Placement State.

Console shows distribution, verification, placement, and load progress separately from Node activation.
A Node can be active while no requested model is available.

The first-inference tracer follows model distribution.
It completes one Playground request and exposes the chosen Node, model version, placement, request state, and scheduler explanation.

## Guided App Setup

App-guided setup is implemented after the domain and CLI operations stabilize.
It composes:

- Install Role authorization through the app-owned lifecycle.
- License status and activation guidance.
- External Postgres validation until Managed Database Mode exists.
- Public transport configuration.
- Migrations.
- First-admin credential initialization.
- Separate internal Node trust initialization or import.
- Node Enrollment Bundle creation and import.
- Node Admission status.
- Model import and distribution progress.
- Playground verification.

The app delegates privileged service mutations to `orchard-service` and uses the same domain operations as CLI and APIs.
It does not create UI-only mutation paths.

## Trust Boundaries And Responsibilities

| Boundary | Operator responsibility now | Target Orchard responsibility |
|---|---|---|
| System-root mutation | Authorize app or PKG lifecycle and protect root-owned configuration. | Present explicit role and mutation scope, preserve state, and resume safely after failure. |
| External Postgres | Provision, secure, back up, and keep PostgreSQL reachable. | Validate configuration clearly until Managed Database Mode owns the lifecycle. |
| Licensing | Supply activation material out of band and protect it. | Validate before useful work without embedding customer material in the release. |
| Public transport | Choose direct HTTPS, reverse proxy, or explicit lab-local TLS. | Validate mode and certificate state without mutating trust stores implicitly. |
| First admin | Protect one-time output and replace bootstrap use with named credentials. | Keep initialization local, one-shot, audited, leader-gated, and credential-only. |
| Node Enrollment | Transfer one sensitive short-lived bundle per Node. | Pin Controller identity, consume once, issue Node identity, audit, expire, revoke, and resume safely. |
| Node Admission | Review registered identity, inventory, compatibility, pool, and policy. | Keep admission explicit and preserve decision history. |
| Runtime transport | Protect current shared-cookie compatibility material and private network. | Use TLS distribution, trusted inventory, exact certificates, and scoped revocable BEAM Peer Grants without automatic gRPC fallback. |
| Model availability | Pre-stage remote artifacts in the current build. | Import once, authorize distribution, verify on each Node, and expose progress. |
| API credentials | Protect one-time API Token output. | Store only hashes/prefixes and expose clear rotation and revocation. |
| Retained state | Back up config, database, models, bundles, and support state. | Preserve documented operator-owned paths and coordinate safe upgrades. |

## Friction Measurement

Durable docs record structural friction, measurement definitions, and acceptance budgets.
Machine-specific timings belong in implementation PR or issue evidence.

Structural measures include:

- Manual root-owned file edits.
- Root-authorized workflows.
- Cross-Mac secret transfers.
- Static target-list entries.
- Macs requiring hands-on steps.
- External prerequisites.
- Secret custody events.
- Model imports and per-worker staging operations.

Time boundaries are:

- Time-to-Console from verified app setup launch to authenticated Console readiness.
- Time-to-first-worker-ready from bundle creation to a fresh healthy authenticated observation on an admitted Node.
- Time-to-first-inference from first Console readiness to a successful Playground terminal response.
- Operator-active time as the intervals inside each named boundary when setup awaits required operator input or the operator performs a required action.

Complete elapsed time, operator-active time, model-byte transfer, automated processing, and administrator waiting are reported as separate components without changing the named metric boundaries.

## Failure And Recovery Model

Every setup stage reports the failed boundary, preserves prior completed work, and provides a safe resume action.

Required failure classes include:

- License invalid or missing.
- External Postgres unavailable or migrations behind.
- Partial TLS state or public transport mismatch.
- App/PKG ownership conflict.
- Enrollment bundle malformed, expired, consumed, revoked, wrong-cluster, or wrong-Node.
- Controller trust-pin mismatch before credential submission.
- Registration response lost after token consumption.
- Registration complete but admission pending or rejected.
- Node Certificate issuance, persistence, renewal, or revocation failure.
- Runtime transport unreachable or identity mismatch.
- Model source unavailable, transfer interrupted, checksum mismatch, disk exhaustion, or load failure.
- Upgrade preflight, drain, update, health verification, or resume failure.

Secrets, private keys, DSNs, raw local evidence, and machine-specific paths never enter audit logs, support bundles, or durable docs.

## Ordered Slices

1. Secure one-Controller, one-Node enrollment tracer.
2. Enrollment hardening and production BEAM identity binding.
3. Controller-hosted model distribution.
4. First-inference Playground tracer.
5. App-guided Controller and worker setup.
6. Managed Database Mode.
7. Coordinated upgrade and drain.

Each slice has explicit tasks in `tasks.md`.

## Alternatives Rejected

### Use Enrollment PKI Without A Scoped Peer Grant

Exact certificate validation remains mandatory, but stock OTP does not atomically correlate the certificate's Orchard Node ID, the claimed BEAM name, and current admission through one supported authorization hook.
OTP also still requires a cookie, so leaving that cookie shared preserves excessive blast radius without closing the binding gap.

### Store Random Recoverable Pair Secrets

Random pair credentials would require plaintext or recoverably encrypted secrets in Postgres or would make Controller restart and recovery depend on unrecoverable local state.
Deterministic derivation preserves hash-only Postgres storage and lets each Controller rematerialize only its own authorized grants.

### Build A Custom Distribution Carrier

A custom carrier would add a large security-critical handshake and compatibility surface without turning distributed Erlang into a method-level authorization system.
The selected model keeps stock OTP TLS distribution and makes Orchard's additional authorization explicit.

### Put The Shared BEAM Cookie In An Expiring Bundle

This reduces manual steps but does not reduce the extracted cookie's cluster-wide authority or blast radius.
It conflates enrollment authorization, durable Node identity, and runtime transport access.
The current shared-cookie path remains documented as compatibility and rehearsal behavior, not Node Enrollment.

### Make Admission Automatic

This would collapse registration and administrator trust review and contradict the current Node Lifecycle contract.
Explicit admission remains the default.

### Build App UI Before CLI And Domain Operations

This would create UI-only orchestration or encode current manual mechanics.
The app follows stable domain operations.

### Distribute Models To Observed Endpoints

Observation is not trust.
Distribution waits for an admitted authenticated Node.

## Contract Reconciliation

`SPEC.md` §10.6 previously said the internal Controller CA was generated by `cluster init` or imported by an administrator.
ADR 0011 and `SPEC.md` §11.9 define `orchardctl cluster init` as credential-only.
This change resolves the contradiction by requiring explicit separate node-trust initialization or admin import.

ADR 0012 and `SPEC.md` §7.5 and §10.6 now select the production BEAM Peer Grant model and close the previously deferred Section 3 identity and authorization decision.
The OpenSpec requirements and tasks now include the completed first narrow Section 3 product-code tracer while keeping every broader hardening and acceptance slice explicit and unchecked.
No `docs/DESIGN.md` change is needed before app-guided setup defines reusable UI patterns.

## External Grounding

The design borrows interaction principles without copying deployment assumptions:

- Tailscale separates device registration, optional approval, key expiry, and revocation, but Orchard must remain sovereign and on-prem.
- K3s secure tokens pin cluster CA identity before sending join credentials and its bootstrap tokens are describable, expiring, listable, and revocable, but Orchard does not reuse an all-powerful server token.
- Syncthing treats device identity as cryptographic and mutual rather than hostname-based, but Orchard centralizes admission instead of requiring bilateral manual configuration.
- Nomad separates shared gossip encryption from mTLS-secured RPC and one-shot ACL bootstrap, reinforcing that a shared transport key is not Node identity.
- Erlang/OTP 29 documents that TLS distribution still uses cookies, that certificate verification and `net_kernel` name authorization are separate surfaces, and that revocation requires application-managed certificate and connection lifecycle.

The Orchard-specific result remains subordinate to `SPEC.md` and existing ADRs.
