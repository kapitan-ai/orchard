## ADDED Requirements

### Requirement: Operator Journey Separates Current And Target Behavior

Orchard documentation and setup surfaces SHALL distinguish current supported behavior from target product intent.
Current behavior SHALL NOT claim that app-guided setup, Bootstrap Token exchange, Node Certificate issuance, dynamic Runtime Endpoint discovery, controller-hosted model distribution, or Managed Database Mode exists before each capability is implemented and validated.
The durable journey SHALL cover all-in-one, Controller-only, and Controller-plus-worker paths and SHALL link to current runbooks for detailed commands.
This refines `SPEC.md` §1.1, §2.3, §4, §6, §10, §11, and §14.

#### Scenario: Current multi-Mac path is described accurately

- **WHEN** an operator reads the current Controller-plus-worker journey
- **THEN** Orchard describes manual shared-cookie provisioning and explicit Runtime Endpoint targets as current compatibility or first-cut behavior
- **AND** Orchard does not describe that behavior as Node Enrollment, Node registration, Node Admission, or certificate bootstrap

#### Scenario: Target journey is visibly aspirational

- **WHEN** documentation describes importing a model once and distributing it to admitted Nodes
- **THEN** the documentation labels that flow as target product intent until controller-hosted distribution is implemented
- **AND** the current local-file and pre-staging limitations remain visible

### Requirement: Node Enrollment Bundle Is Per-Node And Short-Lived

Orchard SHALL define a Node Enrollment Bundle as a versioned, per-Node, one-use, short-lived bootstrap artifact.
The bundle SHALL include stable cluster, Controller, and Node identifiers, a Controller address, a Controller trust pin or public trust-anchor material, one Bootstrap Token, and issued and expiry timestamps.
The default expiry SHALL be one hour and the accepted maximum expiry SHALL be 24 hours.
The Controller SHALL persist the Bootstrap Token secret only as a hash and prefix.
The Controller SHALL also persist the enrollment id, allocated Node reference, creator, lifecycle state and timestamps, expected Controller identity, CSR fingerprint after redemption begins, certificate issuance outcome, resume metadata, and sanitized audit context.
The bundle SHALL be treated as sensitive One-time Secret Output.
This refines `SPEC.md` §4.1, §10.1, §10.5, §10.6, §11.7, and §11.9.

#### Scenario: Controller creates one bundle for one Node

- **WHEN** an authorized local Controller operator creates a Node Enrollment Bundle with a preflighted output path
- **THEN** Orchard allocates one stable Node id and one `provisioned` Node placeholder
- **AND** Orchard writes one bundle for that Node through exclusive owner-only output creation
- **AND** Orchard persists no plaintext Bootstrap Token
- **AND** Orchard records a cluster-scoped audit event without secret material

#### Scenario: Local clock shows that the bundle expired

- **WHEN** a Node Agent imports a bundle whose expiry has passed according to the local clock
- **THEN** Orchard refuses registration
- **AND** Orchard does not transmit the Bootstrap Token
- **AND** Orchard creates no additional Node identity or Node Certificate

#### Scenario: Controller rejects an expired bundle at redemption

- **WHEN** local clock skew allows a Node Agent to submit a bundle that is expired under Controller-authoritative time
- **THEN** the Controller refuses redemption
- **AND** the Controller does not consume the token as a successful registration
- **AND** Orchard creates no additional Node identity or Node Certificate

### Requirement: Enrollment Bundle Excludes Durable And Shared Secrets

A Node Enrollment Bundle SHALL NOT contain a BEAM cookie, cluster-admin credential, operator credential, tenant credential, inference credential, database credential, DSN, CA private key, Node private key, long-lived Node Certificate, or static Runtime Endpoint target list.
Node Enrollment SHALL NOT treat a shared transport secret as durable Node identity.
This refines `SPEC.md` §1.2, §4.1, §10.1, §10.2, §10.5, §10.6, and §11.4.

#### Scenario: Current BEAM cookie is not enrollment material

- **WHEN** Orchard creates a Node Enrollment Bundle for a packaged Node Agent
- **THEN** the bundle contains no current shared BEAM cookie material
- **AND** extracting or redeeming the bundle does not grant cluster-wide BEAM mesh authority

### Requirement: Node Validates Controller Before Sending Join Credential

The Node Agent SHALL validate the bundle's pinned Controller identity and presented certificate chain before transmitting the Bootstrap Token.
Orchard SHALL NOT provide a join mode that sends the Bootstrap Token after implicitly trusting the first Controller response.
This refines `SPEC.md` §10.5 and §10.6.

#### Scenario: Controller trust pin does not match

- **WHEN** the Node Agent connects to a Controller whose trust material does not match the bundle
- **THEN** Orchard refuses before transmitting the Bootstrap Token, CSR, or private inventory
- **AND** the bundle remains unconsumed unless separately expired or revoked

### Requirement: Node Private Key Is Generated Locally

The Node Agent SHALL generate its Node private key locally and persist it atomically in protected Node Agent state before transmitting the Bootstrap Token.
The Node private key SHALL NOT be generated by the Controller, embedded in the Node Enrollment Bundle, persisted in Postgres, or returned through audit, logs, or support bundles.
The Node Agent SHALL submit a CSR bound to the allocated Node id and persisted local key.
The Node Agent SHALL persist the issued Node Certificate, internal runtime trust chain, and expected stable Controller identity atomically beside the local private key before reporting registration complete.
This refines `SPEC.md` §4.1, §10.5, §10.6, and §10.8.

#### Scenario: Successful registration establishes Node identity

- **WHEN** a Node Agent validates the Controller, redeems a valid bundle, and submits a CSR matching the allocated Node id
- **THEN** Orchard atomically consumes the Bootstrap Token
- **AND** Orchard issues a Node Certificate bound to that Node id
- **AND** Orchard transitions the Node from `provisioned` to `registered`
- **AND** Orchard reports that Node Admission remains required

### Requirement: Registration Retry Is Identity-Bound

Bootstrap Token consumption SHALL be atomic under concurrent registration attempts.
If a successful token consumption response is lost, Orchard SHALL allow a bounded resume only when the enrollment id, durably held Node key, and persisted CSR fingerprint match the consumed attempt.
A retry using different key material after consumption SHALL fail closed.
The Controller SHALL persist enough certificate issuance state to distinguish a crash before issuance, after issuance, and before response delivery without minting a second Node identity.
This refines `SPEC.md` §3.7, §4.4, §10.5, and §12.7.

#### Scenario: Concurrent redemption has one winner

- **WHEN** two registration attempts concurrently redeem the same Node Enrollment Bundle
- **THEN** at most one attempt establishes the Node identity
- **AND** the other attempt cannot create another Node row or Node Certificate

#### Scenario: Lost response resumes with the same identity

- **WHEN** the Controller consumes the Bootstrap Token and issues a Node Certificate but the response is lost
- **AND** the Node Agent retries with the same enrollment id, local key, and CSR fingerprint
- **THEN** Orchard resumes or returns the same established identity without creating a duplicate

#### Scenario: Lost response retry changes key material

- **WHEN** a consumed enrollment is retried with a different Node key or CSR fingerprint
- **THEN** Orchard refuses the retry
- **AND** Orchard does not replace or add Node Certificate state

### Requirement: Registration Does Not Imply Admission

Successful Node registration SHALL leave the Node non-schedulable in `registered` state until explicit administrator Node Admission succeeds.
Admission SHALL reuse the shared Action Preview, leader-only write gate, inventory, trust, pool, policy, confirmation, and cluster-scoped audit contracts.
A fresh healthy authenticated Runtime Endpoint observation SHALL advance `admitted -> active` only after admission.
This refines `SPEC.md` §4.2 through §4.6, §5.5, §7.4.1, and §11.9.

#### Scenario: Registered Node waits for approval

- **WHEN** a Node completes certificate-backed registration
- **THEN** Console and CLI show the Node as registered and pending admission
- **AND** the scheduler and queue consume no capacity from that Node

#### Scenario: Admission activates only after authenticated health

- **WHEN** an administrator admits a registered trusted Node
- **THEN** Orchard transitions it to `admitted`
- **AND** Orchard does not make it schedulable until a fresh healthy authenticated observation advances it to `active`

### Requirement: Product Runtime Targets Derive From Trusted Node Inventory

The enrolled product path SHALL derive Runtime Endpoint targets from trusted Node inventory rather than requiring an operator to edit a static Controller target list for each Node.
Target derivation SHALL validate that observed endpoint identity matches the persisted Node and Node Certificate identity.
For production first-party BEAM, a derived Runtime Endpoint target SHALL additionally require an `admitted` or `active` Node with an exact `active` Peer Grant, or an exact `staged` Peer Grant only at its scheduled cutover.
Registered-but-unadmitted inventory, address or BEAM-name equality, certificate identity, and source-development or compatibility overrides SHALL NOT by themselves authorize a production target.
Source-development and explicit compatibility target overrides MAY remain separately documented and SHALL NOT establish Node trust.
This refines `SPEC.md` §1.2, §4.1, §4.6.1, §5.4, §5.5, §7.5, §8, and §10.6.

#### Scenario: Target address alone cannot reconcile identity

- **WHEN** an observed Runtime Endpoint uses the same address or target string as a provisioned or registered Node but cannot prove the matching Node Certificate identity
- **THEN** Orchard does not reconcile the observation to that Node
- **AND** Orchard does not publish scheduling capacity from the observation

#### Scenario: Certificate identity without an active grant cannot authorize a target

- **WHEN** a registered or admitted Node has valid trusted inventory and matching Node Certificate identity but no exact `active` Peer Grant, or only a `staged` grant before its scheduled cutover
- **THEN** Orchard does not authorize a production BEAM Runtime Endpoint target for that Node
- **AND** Orchard publishes no schedulable capacity from that endpoint

### Requirement: Runtime Controller Identity Is Bound During Enrollment

Node Enrollment SHALL establish the exact stable Controller identity and internal trust authority expected by the Node Agent for later runtime mTLS.
The Node Agent SHALL accept a runtime Controller client certificate only when it chains to the enrolled internal trust authority and carries the exact Controller-id SAN established by the bundle and registration result.
The Controller SHALL accept a Node runtime certificate only when it chains to the internal trust authority and carries the exact persisted Node-id SAN.
This refines `SPEC.md` §4.1, §7.5, §10.5, and §10.6.

#### Scenario: Runtime Controller certificate has the wrong identity

- **WHEN** a runtime Controller client certificate chains to the enrolled internal CA but carries a different Controller-id SAN
- **THEN** the Node Agent refuses the runtime connection
- **AND** Orchard does not publish an authenticated healthy observation

#### Scenario: Runtime Node certificate has the wrong identity

- **WHEN** a Node runtime certificate chains to the internal CA but carries a different Node-id SAN from the trusted Node record
- **THEN** the Controller refuses the Runtime Endpoint identity
- **AND** Orchard does not activate the Node or publish its capacity

### Requirement: Production BEAM Requires Certificate Identity And A Scoped Peer Grant

Production first-party BEAM Distribution SHALL use TLS distribution with exact Node and Controller Certificate identity validation plus one active BEAM Peer Grant for the exact Controller-to-Node pair.
The Peer Grant SHALL be scoped to immutable cluster, Controller, Node, certificate, canonical BEAM-name, generation, and validity identifiers.
A registered but unadmitted Node SHALL receive no production Peer Grant.
Postgres SHALL retain grant scope, state, lifecycle evidence, and a secret hash but SHALL NOT retain the plaintext pair secret or a BEAM Authorization Root.
Each Controller instance SHALL own a distinct protected authorization root and SHALL derive only its own pair secrets.
Postgres SHALL retain durable Controller-instance identity and a grant record whose closed lifecycle state is `pending_delivery`, `staged`, `active`, `superseded`, `revoked`, `expired`, or `delivery_failed`.
Only `active` SHALL authorize ordinary new connections, and `staged` SHALL authorize only its scheduled cutover.
A database uniqueness constraint SHALL permit at most one active and at most one staged generation for an exact cluster, Controller, Node, and purpose scope.
This refines `SPEC.md` §3.3, §7.5, §8, §10.5, §10.6, and §10.8 and ADR 0012.

#### Scenario: Admission authorizes one exact pair

- **WHEN** an administrator admits a registered Node whose Node Certificate and trusted inventory remain valid
- **THEN** Orchard commits the admission transition, decision, audit event, and one `pending_delivery` grant record per currently eligible Controller in one Postgres transaction
- **AND** each grant uses the exact Controller identity, Node identity, certificate scope, canonical BEAM names, generation, and validity window
- **AND** the Node retrieves that generation only through certificate-authenticated control traffic
- **AND** a lost delivery response can be retried only after the complete immutable scope is revalidated

#### Scenario: Admission cannot persist every initial grant

- **WHEN** Orchard cannot persist the admission transition, decision, audit event, and every required initial grant record atomically
- **THEN** admission fails closed
- **AND** Orchard retains no partial admission and no orphaned grant metadata

#### Scenario: Pair material is presented for another identity

- **WHEN** a peer presents a valid Orchard certificate but claims the wrong BEAM name or presents another Controller-to-Node pair secret
- **THEN** Orchard refuses production BEAM authorization
- **AND** Orchard publishes no authenticated Runtime Endpoint observation

### Requirement: BEAM Peer Grant Lifecycle Fails Closed

The initial BEAM Peer Grant validity SHALL be 30 days and normal rotation SHALL begin 7 days before expiry.
An exact pair SHALL have at most one active generation and one staged successor.
Rotation SHALL stage the successor at both endpoints, cut over deliberately, disconnect the old connection, and require the successor generation on reconnect.
Revocation SHALL remove Postgres authority and Runtime Endpoint eligibility immediately and SHALL remain visibly incomplete until the connected peer is disconnected or the distribution process is restarted.
Certificate renewal, re-admission, decommission, and Controller authorization-root loss SHALL require the reissuance or revocation behavior defined by ADR 0012.
This refines `SPEC.md` §4.2 through §4.6, §7.5, §10.6, and §12.7.

#### Scenario: Revocation occurs while the peer remains connected

- **WHEN** an operator revokes an active pair grant while its distributed Erlang connection remains established
- **THEN** Orchard immediately excludes that Runtime Endpoint from new work
- **AND** Orchard reports revocation as incomplete until deliberate disconnect or process restart succeeds
- **AND** Orchard does not retry failed BEAM Runtime Endpoint work through gRPC

#### Scenario: Controller loses its authorization root

- **WHEN** a Controller cannot recover its BEAM Authorization Root
- **THEN** Orchard cannot rematerialize that Controller's existing pair secrets from Postgres
- **AND** Orchard requires explicit root restoration or a new root followed by certificate-authenticated reissuance for every affected pair

### Requirement: Active And Standby Controllers Use Distinct BEAM Authorization

Active and Standby Controller instances SHALL use distinct stable Controller IDs, Controller Certificates, canonical BEAM names, BEAM Authorization Roots, and pair grants with each admitted Node.
Both instances MAY maintain authenticated connections for liveness, status, and explicitly read-only diagnostics.
Only the Active Leader SHALL originate mutating runtime operations, enforced by the Postgres advisory-lock write gate before the operation leaves the Controller.
A Node Agent SHALL NOT treat a valid pair grant as proof that the connected Controller currently owns the advisory lock.
This refines `SPEC.md` §3.2, §3.3, §7.5, and §10.6.

#### Scenario: Standby is authenticated but is not leader

- **WHEN** a Standby Controller has a valid certificate and pair grant but does not own the Postgres advisory lock
- **THEN** it may perform allowed liveness, status, or read-only diagnostic operations
- **AND** its Controller-side write gate refuses mutating runtime operations before they leave the Controller

### Requirement: Production BEAM Is A High-Trust First-Party Boundary

Production distributed Erlang SHALL be limited to signed first-party Orchard services on admitted operator-controlled Macs inside restricted private networks.
A BEAM Peer Grant SHALL authorize membership in that high-trust relationship and SHALL NOT be described as method-level or per-function authorization.
gRPC/mTLS SHALL remain available for enrollment, certificate lifecycle, Peer Grant delivery and recovery, diagnostics, explicit Runtime Endpoint compatibility, external adapters, and operator opt-out.
Orchard SHALL NOT automatically retry a failed BEAM inference or Runtime Endpoint operation through gRPC.
The Python/MLX Worker Runtime SHALL remain a Node Agent-local subprocess and SHALL receive no Node Certificate, Peer Grant, or BEAM membership.
This refines `SPEC.md` §1.2, §7.5, §10.1, §10.5, and §10.6.

#### Scenario: BEAM transport fails after operation dispatch

- **WHEN** a first-party Runtime Endpoint operation fails through BEAM after dispatch begins
- **THEN** Orchard reports a stable BEAM transport or authorization failure
- **AND** Orchard does not replay that operation through the gRPC compatibility adapter

### Requirement: Model Distribution Uses Admitted Node Identity

Controller-hosted model distribution SHALL authorize only admitted Nodes through authenticated Node identity.
One verified Artifact Bundle import SHALL be distributable to selected admitted Nodes without per-worker manual source staging.
The Node Agent SHALL verify artifact hashes and optional signatures before changing Placement State.
Distribution progress and failure SHALL remain distinct from Node lifecycle and health.
This refines `SPEC.md` §6.5 through §6.8, §7.5, §10.5, and §10.6.

#### Scenario: Observed endpoint cannot download a model

- **WHEN** a Runtime Endpoint Admission Candidate is reachable but is not an admitted authenticated Node
- **THEN** Orchard refuses controller-hosted Artifact Bundle distribution to that endpoint
- **AND** Orchard does not treat reachability as model-placement authority

#### Scenario: Active Node has no model yet

- **WHEN** a Node is active but the requested Artifact Bundle is not verified and ready on its Runtime Endpoint
- **THEN** Orchard shows the Node as active
- **AND** Orchard separately shows the model as unavailable, transferring, verifying, or failed

### Requirement: Setup Completes With Verified Inference

The target first-run journey SHALL end with a real inference request through Playground or the Public Inference API.
Completion SHALL require an active Node, an active model, a ready Model Placement, a valid inference credential, and a successful terminal response.
The completion result SHALL identify the selected Node and model version and SHALL provide stable remediation when scheduling fails.
This refines `SPEC.md` §5, §6, §7.2, §11.8, and Milestones 1, 3, and 4.

#### Scenario: Green services are not first-run completion

- **WHEN** the Controller and Node Agent processes are running but no model-ready active Node can serve the request
- **THEN** Orchard does not report first-run inference as complete
- **AND** Orchard identifies the missing activation, model, placement, credential, or scheduling boundary

### Requirement: Setup Is Resumable At The Failed Boundary

Guided setup SHALL preserve completed work and resume at the failed boundary after recoverable license, database, transport, enrollment, admission, model, or service errors.
Setup SHALL NOT require the operator to restart the entire journey after a recoverable failure.
Failure output SHALL distinguish blockers, operator responsibilities, safe remediation, and retained state.
This refines `SPEC.md` §11, §12, and §13.

#### Scenario: External Postgres fails during Controller setup

- **WHEN** guided setup cannot reach the configured external Postgres server
- **THEN** Orchard preserves prior install and configuration work
- **AND** Orchard reports the database boundary and safe validation steps
- **AND** rerunning setup resumes at database validation or the next incomplete step

### Requirement: Operator Friction Is Measured Consistently

Orchard SHALL track manual root-owned file edits, root-authorized workflows, cross-Mac secret transfers, static target edits, machines touched, external prerequisites, model staging operations, and secret custody events for each supported topology.
Time-to-Console SHALL run from verified app setup launch to authenticated Console readiness.
Time-to-first-worker-ready SHALL run from Node Enrollment Bundle creation to a fresh healthy authenticated observation on an admitted Node.
Time-to-first-inference SHALL run from first Console readiness to a successful Playground terminal response.
Operator-active time SHALL be the intervals inside each named boundary when setup awaits required operator input or the operator performs a required action.
Complete elapsed time, operator-active time, model-byte transfer, automated processing, and administrator waiting SHALL be reported separately without changing the named boundaries.
Machine-specific evidence SHALL live in implementation PRs or issues rather than durable journey docs.
This refines `SPEC.md` §11, §12, §13, and §14.

#### Scenario: Model transfer does not hide setup friction

- **WHEN** Orchard measures time-to-first-inference for a large Model Bundle
- **THEN** the result reports operator-active setup time separately from model-byte transfer time
- **AND** the durable repo document retains the measurement definition without machine-specific logs or paths
