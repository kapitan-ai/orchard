## ADDED Requirements

### Requirement: Dedicated Node Distribution Has A Distinct Profile And Exclusive Ownership

The dedicated Apple Silicon macOS Node distribution SHALL use the proposed distribution-profile identifier `dedicated_apple_silicon_macos_node` after owner acceptance.
It SHALL compose the existing Apple Silicon macOS platform profile and macOS MLX Node runtime profile without modifying the all-in-one macOS native distribution profile or the experimental `managed_apple_silicon_macos_node` profile.
It SHALL use `Orchard Node.app`, bundle identifier `com.orchard.node`, `/Applications/Orchard Node.app`, `/Library/Application Support/Orchard Node/`, service identity `_orchardnode`, daemon `com.orchard.node.agent`, helper `com.orchard.node.lifecycle`, and `/usr/local/bin/orchard-node` after those identifiers are accepted.
It SHALL NOT replace `Orchard.app`, `orchardctl`, their paths, their services, or their role-selected lifecycle.
Initial installation SHALL reject conflicting Orchard or Node ownership, legacy package receipts, Controller-bearing hosts, retained Node state, and competing Node or Worker Runtime processes before mutation.
It SHALL perform no automatic takeover, adoption, dual installation, or Controller-to-Node conversion.

#### Scenario: Clean dedicated host is provisioned

- **WHEN** an operator installs verified dedicated Node bytes on a compatible host with no conflicting ownership, retained state, or process
- **THEN** installation creates only the dedicated profile's owned paths and services
- **AND** neither a source checkout nor a local Controller is required
- **AND** the all-in-one installation remains unchanged

#### Scenario: Existing ownership is detected

- **WHEN** preflight detects an all-in-one app, Controller service, occupied command or service path, legacy package receipt, retained Node state, or competing Node process
- **THEN** installation fails before mutation with a specific ownership or repair blocker
- **AND** it does not convert or adopt the host

### Requirement: Node Payload Proves Controller-Free Closure

The final app SHALL contain only the explicit Node OTP release, pinned ERTS, Node Agent, Node-local client, MLX Worker Runtime provider, required tokenizer and native artifacts, and necessary shared portable libraries.
Its release application metadata, boot terms, compiled module inventory, dynamic references, runtime process starts, native executable references, linked Mach-O libraries, bundled interpreters, and generated artifacts SHALL exclude Controller applications and RPC bridges, Repo startup, migrations, database services, Console and HTTP server code, CA issuance, trust administration, Controller executables, policy mutation, and unrelated native payloads.
Validation SHALL inspect assembled bytes and runtime behavior and SHALL NOT infer closure from role selection or absence of a Controller release directory.
The generic-secret scan SHALL include implicit Mix `releases/COOKIE`, default or generated OTP cookies, embedded environment files, and test credentials.
No reusable shipped credential may authorize a production peer.
Production distribution authorization SHALL arrive only through a scoped Peer Grant out of band.
Shared utility use such as `Ecto.UUID` SHALL be evaluated by actual module and startup closure rather than library name alone.

#### Scenario: Node CLI retains Controller code

- **WHEN** an assembled Node app contains or loads Controller modules through its client or dependency closure
- **THEN** closure validation fails and Stage A remains incomplete

#### Scenario: Release tooling emits a reusable cookie

- **WHEN** assembled bytes contain `releases/COOKIE`, a generated OTP cookie, or another reusable peer credential
- **THEN** generic-secret validation fails before candidate qualification
- **AND** the credential cannot authorize startup

### Requirement: Node Client Preserves Complete Identity Validation With Minimal Authority

The Node-local client SHALL preserve key and CSR generation, `certificate_identity/2`, `validate_issued_identity/1`, certificate and key matching, URI SAN validation, Controller identity validation, protected Store staging, atomic finalization, and their complete client-required dependency closure.
It SHALL expose only `orchard-node node join --enrollment-bundle PATH`, local identity and status diagnostics, help, and version.
It SHALL exclude Controller CA private keys, certificate issuance, trust administration, direct Repo access, policy mutation, admission, lifecycle mutation, and unrelated operator commands.
Client extraction SHALL include regression evidence for invalid certificates, identity mismatch, interrupted finalization, permission failure, no Repo start, and no Controller module load.

#### Scenario: Controller returns an invalid issued identity

- **WHEN** the enrollment response contains an invalid, mismatched, or wrongly bound issued identity
- **THEN** the client rejects Store finalization under the existing identity-validation semantics
- **AND** remote registration alone does not authorize serving

#### Scenario: Client runs on a clean Node host

- **WHEN** the packaged join command executes without a Controller release or database
- **THEN** key generation, CSR creation, response validation, and protected Store finalization remain available
- **AND** no Controller module or Repo starts

### Requirement: Enrollment And Runtime Share One Provisioning Configuration

The Node lifecycle SHALL own one schema-versioned root-owned `config/node.json`.
It SHALL record the selected profile, Controller endpoint and bootstrap trust reference, advertised private address and control port, fixed Node Identity Root, service UID and GID, BEAM-first transport policy, and app-specific release-trust reference.
It SHALL contain no enrollment token, private key, Peer Grant plaintext, database secret, or customer credential.
The app, join client, non-serving certificate-control bootstrap, and runtime SHALL consume the same configuration without caller-environment, inherited-environment, argument, wrapper-default, identity-root, or transport overrides.
An explicit root-authorized configuration operation SHALL atomically replace the complete configuration before enrollment.
Before redemption, the client SHALL prove agreement among the bundle endpoint and trust, persisted configuration, installed profile, effective and consuming identities, advertised address, identity root, path permissions, transport, installed release, and current activation authority.
Disagreement SHALL fail before token spend.

The helper SHALL use an authenticated, versioned, fixed-operation protocol bound to the signed app and dedicated profile.
Signed code identity SHALL NOT authorize a privileged operation by itself.
Each signed-app request SHALL carry a fresh `com.orchard.node.lifecycle.manage` Authorization Services external authorization proving administrator consent and SHALL bind the operation, canonical argument and input digest, invoking audit identity, helper nonce, and request sequence to one promptly expiring helper session.
Direct root CLI requests MAY use only the verified installed `orchard-node` executable running with effective UID 0 and SHALL remain subject to the same fixed-operation, executable, argument, path, profile, nonce, and replay checks.
It SHALL reject arbitrary executables, shell commands, arbitrary arguments, Controller or database roles, caller-selected real-system roots, customer CA administration, system trust mutation, and unowned paths or service labels.
The signed-app Join action MAY invoke only the exact installed join executable as `_orchardnode` through a bounded protected input channel.
It SHALL verify caller and executable identity, input ownership and size, service identity, and configuration agreement without logging the bundle or token.

#### Scenario: Join and runtime resolve different identity roots

- **WHEN** an override or wrapper would direct join and runtime to different identity roots or service identities
- **THEN** preflight rejects enrollment before redemption
- **AND** diagnostics expose no secret

#### Scenario: Helper receives arbitrary authority

- **WHEN** a caller requests an arbitrary executable, Controller role, system trust mutation, or unowned path
- **THEN** the helper rejects the request before mutation even when the caller can request local lifecycle operations

#### Scenario: Genuine app lacks administrator authorization

- **WHEN** the genuine signed app requests a privileged operation without a fresh matching administrator authorization session
- **THEN** the helper rejects the request before mutation
- **AND** caller code identity does not substitute for consent

### Requirement: Release Trust Is App-Specific And Cannot Self-Authorize

The dedicated profile SHALL store release trust separately from customer enrollment CA material, Controller trust, the macOS system trust store, and Node identity.
The first-install verifier SHALL contain only owner-approved Orchard release-root key identifiers and fingerprints plus the expected Apple Team identity.
A detached release registry SHALL validate under an already approved root.
A Candidate Manifest, release record, activation attestation, or candidate-supplied registry SHALL NOT add the root that authorizes itself.

A fixed helper operation MAY write only the app-specific release-trust store after validating a monotonic registry generation under an already trusted unrevoked root.
Rotation SHALL name the new and retiring key identities, effective times, registry generation, and rollback protection.
Offline import SHALL use the same signed registry and SHALL NOT create a different trust path.
The initial roots, Apple Team identity, key custody, registry location, and rotation ceremony SHALL be accepted and implemented before release verification can complete.

#### Scenario: Candidate supplies a new verifying key

- **WHEN** a candidate record or detached sidecar is valid only under a key introduced by that same untrusted material
- **THEN** release verification rejects it without changing local trust

#### Scenario: Trusted release root rotates

- **WHEN** a monotonic registry update is authorized by a previously trusted unrevoked root
- **THEN** the app-specific store can install the accepted rotation
- **AND** customer and system trust stores remain unchanged

### Requirement: Acquisition And Enrollment Remain Separate

Node acquisition SHALL expose one selected immutable authenticated release record and download link separately from the existing short-lived one-use enrollment JSON.
Operators SHALL verify, install, and configure Node software before creating the expiring enrollment artifact.
The enrollment artifact SHALL remain bootstrap material and SHALL NOT contain executable tooling, release authority, shared BEAM cookies, or long-lived Node credentials.
Download SHALL NOT imply verification, installation, local identity finalization, registration, admission, Peer Grant authorization, schedulability, or serving.

#### Scenario: Operator prepares a new machine

- **WHEN** the operator follows Add Node guidance for the dedicated profile
- **THEN** it presents verified acquisition and target-machine installation before enrollment creation and join
- **AND** the existing enrollment JSON and one-time handling remain separate

### Requirement: Release Identity And Activation Authorization Are Distinct

The immutable Node release record SHALL be a projection of the governance Candidate Manifest and SHALL NOT create an independent release authority.
It SHALL bind Product Version, release channel, source and build identity, Candidate Manifest digest, final DMG digest, mounted app identity, sealed Node payload identity, bundle identifier, Apple Team and signing identity, before and after signing evidence, SBOM reference, platform and provider tuple, and exact Controller compatibility declaration.
The record and final Candidate Manifest SHALL remain detached from the sealed DMG.
Installed verification SHALL reproduce the authenticated app and payload identity.

Install, update, enrollment, and serving startup SHALL additionally require a governance-owned Release Activation Attestation accepted before implementation.
The attestation fields, release eligibility, withdrawal precedence, and lineage replay protection SHALL follow [Node Activation Authority Is Separate From Distribution Approval](../product-release-governance/spec.md#requirement-node-activation-authority-is-separate-from-distribution-approval).
Unknown or rolled-back time, excessive clock uncertainty, stale or unavailable authority, incompatibility, or unverifiable installed bytes SHALL block the new transition.
Connected refresh SHALL verify the same authority and SHALL NOT replace bytes automatically.

An already running Node SHALL remain governed by admission, certificate, Peer Grant, Controller policy, and Runtime Endpoint health rather than a new release-freshness serving lease.
A restart is a new activation boundary.
Automatic recall, forced shutdown, and unattended replacement require a separate accepted contract.

#### Scenario: Digest matches but activation is withdrawn

- **WHEN** the bytes match the immutable release record but trusted current activation state records withdrawal
- **THEN** install, enrollment, update, and serving startup are rejected

#### Scenario: Publication approval is still valid

- **WHEN** a release has valid distribution approval but no valid Release Activation Attestation
- **THEN** the Node does not treat publication approval as startup authority

#### Scenario: Installed app differs from the candidate

- **WHEN** installed app or payload identity differs from the authenticated Candidate Manifest projection
- **THEN** activation fails even if the receipt names the expected release

### Requirement: Node App Uses Governed Apple Build Allocation

The dedicated Node app SHALL consume the allocator and artifact binding defined by [Apple Build Allocation Covers Every Governed App Identity](../product-release-governance/spec.md#requirement-apple-build-allocation-covers-every-governed-app-identity).
The release-governance owner SHALL approve and seed that allocator before Node qualification.

#### Scenario: Candidate contains both app identities

- **WHEN** one candidate set contains all-in-one and dedicated Node app artifacts
- **THEN** each artifact records its own bundle metadata
- **AND** the candidate consumes two distinct allocations from the one approved monotonic authority without collision or unauthorized reuse

### Requirement: Offline Activation Has Bounded Freshness

Offline delivery SHALL preserve the original artifact bytes and carry the same verifiable release registry, Candidate Manifest projection, and Release Activation Attestation used online.
The verifier SHALL enforce expiry, maximum clock uncertainty, lineage replay protection, withdrawal evidence, and the locally recorded highest accepted sequence without automatic network egress.
Stale, expired, unavailable, or unverifiable authority SHALL block install, update, enrollment, and serving startup.
An already running Node SHALL remain under existing runtime authorization until a new activation boundary.
Status SHALL identify the missing or stale authorization without downloading or replacing bytes automatically.

#### Scenario: Air-gapped host receives current authorized media

- **WHEN** imported bytes, registry, manifest, activation attestation, time policy, and lineage sequence validate
- **THEN** the host can proceed through the same release gates without internet access

#### Scenario: Offline authorization expires before restart

- **WHEN** a stopped Node has no valid replacement attestation at restart
- **THEN** serving startup remains blocked
- **AND** status requests refreshed authorization without modifying installed bytes

#### Scenario: Stopped Node recovers activation authority

- **WHEN** an authorized operator supplies valid governance renewal and trusted-time/state recovery evidence through connected refresh or offline import after expiry, clock rollback, or unavailable trusted state
- **THEN** the Node verifies it under existing release trust, withdrawal precedence, and replay protection without requiring production BEAM or current activation authority
- **AND** it atomically restores verified authorization state without replacing installed bytes or Node identity
- **AND** serving remains stopped until the ordinary startup gates pass

#### Scenario: Recovery evidence cannot establish current authority

- **WHEN** evidence is forged, replayed, withdrawn, interrupted, or cannot establish trusted time and state
- **THEN** the Node remains stopped with a specific recovery blocker without resetting trust or bypassing freshness

### Requirement: Admission Preserves Capacity Policy And Initial Grant Atomicity

The active Controller SHALL admit a registered dedicated Node only through the current leader-authorized admission boundary.
One transaction SHALL commit the Node Admission state, Node Admission Decision, cluster audit, phase-appropriate explicit Controller dispatch-capacity policy, and initial `pending_delivery` Peer Grant metadata for every eligible Controller instance.
Failure of any constituent SHALL roll back the entire admission.
The transaction SHALL preserve preview, confirmation, mutation-time revalidation, capacity-phase locking, Controller-instance identity, and current pre-cutover or enforcing policy semantics.
Admission SHALL NOT imply grant delivery, Runtime Endpoint readiness, scheduler eligibility, Controller leadership, or serving.

Initial delivery SHALL retrieve only the exact `pending_delivery` grant over the retained certificate-authenticated control path without requiring an already-authorized BEAM connection.
Both named endpoints SHALL stage the exact protected grant bytes and acknowledge grant identity, generation, scope, certificate identities, staged-byte digest, and current admission.
The Controller SHALL advance the durable grant to `active` only after both acknowledgements match the pending metadata and current authorization.
Lost delivery or acknowledgement responses SHALL be idempotently revalidated from durable Controller and endpoint state.
Partial staging, disagreement, revocation before cutover, or failed revalidation SHALL leave the grant non-active and the Node non-serving.

#### Scenario: Capacity policy write fails during admission

- **WHEN** admission cannot persist the phase-appropriate dispatch-capacity policy
- **THEN** no admission state, decision, audit, or initial grant metadata commits

#### Scenario: Admission transaction succeeds

- **WHEN** every admission constituent commits atomically
- **THEN** the Node remains non-serving until exact grant delivery, production transport, runtime readiness, and scheduler authority also succeed

#### Scenario: Initial grant acknowledgement is lost

- **WHEN** both endpoints stage the exact pending grant but the Controller loses an acknowledgement response
- **THEN** retry revalidates the durable staged identity and authorization without requiring BEAM Distribution
- **AND** the grant becomes active only after both endpoint acknowledgements are proven

### Requirement: Enrolled Startup Is Explicitly BEAM-First

Installation SHALL leave serving disabled and enrollment SHALL require explicit local operator intent.
Successful local Store finalization SHALL permit only the certificate-authenticated control and recovery path until admission and exact active certificate-bound Peer Grant delivery succeed.
Production startup SHALL validate exact Node and Controller Certificate identities, trusted inventory, canonical BEAM names and private addresses, active staged grant scope, generation, expiry and revocation, current admission, and a successful current activation-boundary decision before OTP TLS Distribution starts.
Worker Runtime negotiation and fresh authenticated health and Runtime Endpoint facts SHALL follow production transport authorization and SHALL be recorded independently of request-time dispatch authorization.
The Controller-owned activation evaluator SHALL require current admission, active Peer Grant, authenticated BEAM availability, exact identity, the recorded successful activation-boundary result, fresh runtime evidence, and the phase-appropriate capacity policy persisted by admission before automatic `admitted -> active` promotion.
Scheduler eligibility SHALL follow activation, and every inference request SHALL remain subject to current leader and dispatch-capacity authorization.
Missing or invalid authorization or unavailable BEAM Distribution SHALL remain visibly non-serving without shared-cookie or gRPC inference fallback.
The retained certificate-authenticated control path SHALL remain distinct from inference transport.
Static targets, experimental Peer Grant tracers, and shared-cookie app smoke SHALL NOT authorize this profile.
After successful startup, scheduler eligibility SHALL consume the recorded activation-boundary result and SHALL NOT continuously revalidate attestation freshness as a serving lease.
Attestation expiry alone SHALL NOT deschedule or stop an uninterrupted healthy Node, while restart and every other enumerated new activation boundary SHALL require current authority.

#### Scenario: Node is registered but not admitted

- **WHEN** join finalizes a valid local identity and the Controller records registration
- **THEN** status reports `registered; awaiting admission`
- **AND** no production Peer Grant, BEAM Runtime Endpoint, scheduler eligibility, or inference authority is inferred

#### Scenario: Admission precedes grant delivery

- **WHEN** admission commits but the exact active grant is not delivered and staged
- **THEN** the Node remains non-serving on the certificate-authenticated control path

#### Scenario: Production BEAM becomes unavailable

- **WHEN** certificate, grant, inventory, canonical-name, or TLS Distribution validation fails during startup or reconnect
- **THEN** the Node reports the specific failure and remains ineligible
- **AND** it does not select a shared cookie or gRPC inference fallback

#### Scenario: Activation attestation expires during a healthy run

- **WHEN** the activation attestation expires after successful startup while admission, certificates, active grants, Controller policy, transport, and Runtime Endpoint health remain current
- **THEN** expiry alone does not remove scheduler eligibility or stop inference
- **AND** a later restart remains blocked until current activation authority is available

### Requirement: Manual Lifecycle Uses Distinct Ordinary And Repair Entry Gates

The lifecycle SHALL retain a root-owned `config/lifecycle-ownership.json` outside replaceable payload bytes.
It SHALL bind profile, installed app and payload identity, Node ID when present, service UID and GID, owned paths, receipt generation, last completed transaction, and retained-state disposition.
Default removal SHALL update and retain this record.
The record SHALL grant no Controller, cluster, trust, or serving authority.

Ordinary update SHALL require an intact active receipt and verified owned paths.
It SHALL require explicit operator intent, compatible current activation authorization, Controller cordon, completed drain, maintenance state, prevented restart, serialized local custody, and verified exact Node Agent and Worker Runtime exit before mutation.
The initial profile SHALL reject retained-state schema migration.
Every mutation SHALL use a durable incomplete-operation marker and SHALL remain stopped when rollback or process state is uncertain.

Repair SHALL use a distinct entry gate.
It MAY proceed from an intact active receipt or a matching retained ownership record only when signed app identity, fixed profile, service identity, installation root, Node Identity Root, and non-secret ownership facts agree.
It SHALL be diagnostic first and MAY restore only verified Node-owned executable, service, command, configuration, and receipt state.
It SHALL NOT infer custody from retained identity alone, reissue identity, redeem enrollment, accept partial TLS, mutate customer or system trust, or restore serving solely because bytes return.
Before mutating runtime-affecting state, repair SHALL suppress restart, acquire serialized local custody, and verify exact Node Agent and Worker Runtime exit.
When the Controller is reachable, mutating repair SHALL also require Controller maintenance exclusion.
When the Controller is unreachable, repair MAY change verified local Node-owned state only while launchd remains disabled and SHALL record `remote coordination pending`; it SHALL NOT restart or restore eligibility until Controller maintenance, admission, grant, and runtime state are reconciled.
When neither receipt nor retained ownership evidence proves custody, repair SHALL stop before mutation and require an explicit Controller decommission plus an owner-approved forensic or fresh-host path.

Rollback MAY restore prior verified Node-owned bytes and records, but restart SHALL revalidate current activation, compatibility, identity, admission, Peer Grant, transport, and runtime readiness.
Withdrawn or expired rollback bytes SHALL remain stopped.
Default removal SHALL verify process exit, remove Node-owned executable state, and retain configuration, identity, models, bundles, logs, retained operator-owned contents under the `support/` namespace, and ownership evidence.
Remote decommission SHALL remain separate.
An unreachable Controller SHALL produce `remote revocation pending`, not a decommission or destructive-purge claim.

#### Scenario: Update cannot prove process exit

- **WHEN** update cannot prove Controller exclusion, restart suppression, or exact Node and Worker Runtime exit
- **THEN** it fails before payload mutation and starts no overlapping process

#### Scenario: Repair has only retained Node identity

- **WHEN** retained identity exists but active receipt and retained ownership evidence are absent or invalid
- **THEN** repair performs no mutation and does not infer local custody from identity

#### Scenario: Repair cannot prove process exit

- **WHEN** mutating repair cannot suppress restart or prove exact Node Agent and Worker Runtime exit
- **THEN** repair remains diagnostic-only and changes no runtime-affecting state

#### Scenario: Repair proceeds while Controller is unreachable

- **WHEN** local ownership is proven, restart is suppressed, exact processes are stopped, and the Controller cannot confirm maintenance exclusion
- **THEN** repair may restore verified local Node-owned state with launchd disabled
- **AND** status records `remote coordination pending` without restarting or restoring eligibility

#### Scenario: Rollback restores withdrawn bytes

- **WHEN** prior bytes are restored but current activation authority is withdrawn or expired
- **THEN** the Node remains stopped with an actionable repair status

#### Scenario: Local removal cannot reach Controller

- **WHEN** an operator removes a stopped Node while the Controller is unreachable
- **THEN** local executable state is removed and operator and identity state are retained
- **AND** status reports remote revocation pending without claiming decommission

### Requirement: Completion Requires Admitted Qualified Inference

This change SHALL use Stage A for closed composition and local authority validation, Stage B for clean-host verification, installation, local identity finalization, and registration awaiting admission, and Stage C for admitted production-authorized inference and lifecycle qualification.
Stage B SHALL NOT complete the change or establish production readiness.
Stage B and Stage C SHALL use the exact signed, notarized, stapled, activation-authorized candidate produced under separate explicit credential and candidate-activation authorization.
Stage C SHALL require real Apple Silicon evidence for the exact accepted Controller, Node Product Version, macOS, hardware, MLX provider and interpreter, model and tokenizer, inference-feature, release-authorization, and network tuple.
It SHALL cover model load, inference, streaming, cancellation, capacity, restart, reconnect, certificate renewal, grant rotation and revocation, compatibility rejection, offline activation, manual update, rollback, interruption, repair, removal, and remote-decommission reporting.
Experimental Peer Grant tracers and shared-cookie smoke SHALL NOT substitute for enrolled production evidence.
Public artifact support SHALL additionally require explicit release approval and all applicable signing, notarization, stapling, mounted verification, delivery, publication, and support gates.

#### Scenario: Stage B passes before production transport

- **WHEN** clean-host registration passes but enrolled production BEAM, runtime qualification, or lifecycle qualification remains incomplete
- **THEN** the artifact remains an intermediate engineering result
- **AND** the change remains incomplete and unsupported

#### Scenario: Exact Stage C matrix passes

- **WHEN** every accepted tuple passes Stages A, B, and C
- **THEN** implementation qualification may be recorded only for those tuples
- **AND** release, publication, and support remain separate explicit decisions
