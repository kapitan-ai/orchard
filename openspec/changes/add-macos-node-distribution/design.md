## Context

The current macOS native distribution is one signed and notarized DMG containing `Orchard.app`.
Its role selector can install a Node Agent, but role selection does not prove that the app, OTP releases, CLI, boot files, compiled modules, dynamic references, or native payload are Controller-free.
The implemented Console enrollment flow produces one short-lived enrollment artifact and tells the target operator to run `orchardctl node join`.
A clean dedicated Node host needs executable software and a profile-specific join surface before that artifact can be redeemed.

Enrollment already separates one-time bootstrap material, client-generated private key and CSR, issued identity validation, protected local storage, Controller registration, explicit admission, Peer Grant authorization, Runtime Endpoint readiness, scheduling, and serving.
This design keeps those boundaries and gives the dedicated distribution an explicit local owner at each step.

This change is proposed intent under `SPEC.md`.
It does not alter the apex contract, implement a product task, create a candidate, use credentials, or establish a supported artifact.

## Goals / Non-Goals

**Goals:**

- Define a clean-host Apple Silicon macOS Node distribution from prebuilt verified bytes.
- Preserve the existing all-in-one `Orchard.app` contract and ownership.
- Prove Controller-free Node composition at the assembled-byte and runtime boundaries.
- Preserve complete client-side identity validation without Controller CA, persistence, policy, or unrelated command authority.
- Define release trust, activation authorization, configuration custody, enrollment, production startup, and manual lifecycle as separate gates.
- Produce reviewable implementation pull-request boundaries that pair behavior with focused failure-path evidence.
- Complete qualification only after admitted, authorized, exact-model inference and lifecycle evidence exist.

**Non-Goals:**

- Modify or replace the existing all-in-one app, `orchardctl`, or role-selected lifecycle.
- Support Controller-bearing dedicated hosts, legacy adoption, Controller-to-Node conversion, native PKG, MDM, unattended update, or a general component catalog.
- Import the `managed-macos-node-composition-provenance` transition generation, stable-bootstrap activation protocol, source baseline, or managed rollback protocol.
- Resolve GitHub issue #371 or promise same-name enrollment recovery before that issue has an accepted contract and implementation.
- Remove certificate lifecycle, enrollment, Peer Grant delivery and recovery, diagnostics, Worker Runtime gRPC, or any other boundary preserved by the staged gRPC deprecation contract.
- Implement or support a Linux Node artifact.
A signed Linux tarball remains a future candidate under a separately accepted platform, provider, lifecycle, and qualification contract.

## Contract Status And Dependency Order

The dependency order is normative for implementation sequencing.

1. The owner accepts the identifiers, profile name, release-trust model, activation-authorization model, Apple build-number allocation, privileged-operation authorization, first qualification matrix, and production BEAM ownership listed below.
2. The accepted proposal is followed by a separate apex and release-governance reconciliation pull request.
That pull request updates `SPEC.md`, the affected main specifications, decisions, and release governance without changing runtime behavior.
3. The governance implementation supplies Candidate Manifest projection, Node activation attestations, trusted release-root storage and rotation, `com.orchard.node` build-number allocation, and verification fixtures.
4. Node-local PKI and CLI extraction lands before the dedicated release is assembled.
5. Closed release composition, app/helper/configuration ownership, release verification, and crash-safe clean installation land before Console acquisition or enrollment guidance advertises the profile.
6. Profile-aware acquisition and join land before Stage B clean-host registration.
Console release guidance may land first, but dedicated-profile enrollment issuance and actionable join guidance stay disabled until the target-host join and local pre-redemption checks are available.
7. Admission integration preserves the current phase-appropriate dispatch-capacity policy transaction and initial Peer Grant metadata before production distribution is enabled.
8. Initial grant delivery, protected endpoint staging, acknowledgement, and durable activation land before OTP TLS Distribution can consume the grant.
9. Grant lifecycle handling, OTP TLS Distribution, runtime readiness, scheduler eligibility, and exact-model qualification land in that order.
10. Manual replacement, rollback, repair, removal, and offline qualification pass before Stage C can complete.
11. Credential-free engineering validation precedes any credentialed candidate operation.
A separately authorized exact candidate is then constructed, signed inner-first, notarized, stapled, activated, and verified before Stage B or Stage C qualification uses it.
Delivery, publication, support, and public visibility remain later and separately authorized release operations after implementation qualification.

Current dependency state on the proposal baseline is mixed.

- PR #105 merged the product-versioning and release-governance proposal, but its release workflow, activation authorization, Node bundle allocation, and most implementation tasks are incomplete.
- PR #333 merged Controller release decoupling from CLI, but the Node-local CLI still needs its own closed extraction proof.
- PR #359 merged Console enrollment and one-time delivery with `orchardctl` guidance.
The dedicated profile needs a follow-on contract and implementation for profile-aware guidance.
- Issue #371 remains open and `needs-triage`; draft PR #384 proposes audited same-name recovery but is not merged or current authority on this baseline.
Current no-redisplay, identity-bound resume, and distinct-name replacement behavior remains authoritative until a separately accepted recovery change lands.
- The Controller dispatch-capacity contract is current admission authority.
Dedicated Node admission must preserve it rather than depend on a future whole-package completion claim.
- PR #351 and ADR 0029 define staged deprecation of first-party inference gRPC only.
The certificate-authenticated control and recovery uses remain prerequisites here.
- PR #358 and ADR 0030 define a separate experimental managed source-baseline transition.
This distribution may satisfy its future clean-host prerequisite, but no managed transition mechanism is imported into this design.

## Owner Decisions Required Before Implementation

The Repository Owner must explicitly accept these decisions before the first behavior-changing pull request.

1. **Artifact and profile identity.**
Accept or replace `dedicated_apple_silicon_macos_node`, `Orchard Node.app`, `com.orchard.node`, `/Applications/Orchard Node.app`, `/Library/Application Support/Orchard Node/`, `_orchardnode`, `com.orchard.node.agent`, `com.orchard.node.lifecycle`, and `/usr/local/bin/orchard-node`.
2. **Apple build-number authority.**
Accept one global monotonic `1..9999` allocation ledger shared by `com.orchard.app` and `com.orchard.node`, with one distinct allocation per governed app artifact.
A candidate containing both bundle identifiers consumes two distinct allocations.
Allocate before app construction by the immutable pre-seal key `{build_kind, candidate_or_internal_build_identity, full_source_commit, product_version, channel, bundle_identifier, staged_payload_identity}`.
For a tagged Candidate, `candidate_or_internal_build_identity` is its signed tag; for an Internal Build it is a unique governance-issued construction identity.
An unchanged pre-seal retry reuses its allocation, any changed key consumes a new allocation, and a failed or abandoned allocation is never recycled.
After construction and signing, the allocation record and manifest bind that number to the final sealed artifact digest.
3. **Release Activation Attestation.**
Accept the governance-owned activation state, eligible candidate and channel states, sequence scope, issue and expiry semantics, withdrawal precedence, offline freshness, maximum clock uncertainty, and renewal procedure.
A distribution or publication approval must not be reused implicitly as activation authority.
4. **Release-trust bootstrap and rotation.**
Accept the initial release-root key identifiers and fingerprints, Apple Team identity, app-specific trust-store location, fixed helper operation, offline bootstrap media, rotation chain, revocation behavior, and key custody.
A candidate must not authorize the trust root used to verify itself.
5. **Console and recovery behavior.**
Accept profile-aware selection between existing `orchardctl` guidance and the dedicated `orchard-node` or signed-app Join action.
Confirm that issue #371 remains a separate dependency for same-name replacement and does not block ordinary new-name clean-host enrollment.
6. **Repair ownership evidence.**
Accept the retained local ownership record, receipt fields, uninstall retention behavior, and the terminal response when neither an intact receipt nor retained ownership evidence can prove custody.
Retained Node identity alone must not authorize takeover.
7. **Production BEAM integration ownership.**
Name the implementing owner for certificate-authenticated control bootstrap, initial grant metadata integration, grant delivery and storage, rotation and revocation, canonical-name inventory, OTP TLS Distribution startup, and failure normalization.
8. **First qualification matrix.**
Freeze exact Controller release line, Node Product Version, macOS versions, Apple Silicon families, MLX provider and interpreter closure, model and tokenizer revisions, supported inference features, and offline authorization interval.
No broader matrix may be inferred from one passing host.
9. **Privileged-operation authorization.**
Accept the proposed `com.orchard.node.lifecycle.manage` Authorization Services right for signed-app requests, administrator authentication for each new helper authorization session, and direct root CLI access only from the verified installed `orchard-node` executable.
Each authorization is one session, expires promptly, and binds the operation, canonical argument and input digest, invoking audit identity, helper nonce, and request sequence so code identity alone never grants permission or permits replay.

## Decisions

### 1. Separate Profile Identity And Exclusive Ownership

The proposed distribution profile identifier is `dedicated_apple_silicon_macos_node`.
It composes the existing Apple Silicon macOS platform profile and macOS MLX Node runtime profile with a new direct clean-host distribution profile.
It is distinct from the all-in-one macOS native distribution and from `managed_apple_silicon_macos_node`.

The app name is `Orchard Node.app`, its bundle identifier is `com.orchard.node`, and its install location is `/Applications/Orchard Node.app`.
Its installation root is `/Library/Application Support/Orchard Node/`.
Its service identity is `_orchardnode`, its daemon label is `com.orchard.node.agent`, its helper identity is `com.orchard.node.lifecycle`, and its command is `/usr/local/bin/orchard-node`.
The dedicated app does not replace `Orchard.app`, `orchardctl`, or any all-in-one path or service.

Initial install rejects conflicting Orchard or Node app ownership, occupied command or service paths, legacy `com.orchard.pkg` receipts, Controller services, retained Node state, and competing Node or Worker Runtime processes.
No automatic takeover, dual installation, Controller-to-Node conversion, or legacy adoption is supported.
A relocated validation root relocates every path and simulates launchd.

### 2. Closed Node Release And Minimal Client Authority

The dedicated release is built from an explicit allowlist containing pinned ERTS, Node Agent, the minimal Node-local client, the MLX Worker Runtime provider, required tokenizer and native artifacts, and genuinely shared portable libraries.
It rejects Controller OTP applications, Controller RPC bridges, Repo startup, migrations, database services, Console or HTTP server code, CA issuance, trust administration, Controller executables, lifecycle commands outside the dedicated helper, and unrelated native payloads.

Closure proof inspects release application metadata, `.boot` and `.script` terms, compiled BEAM inventory, application dependencies, dynamic module references, runtime process starts, native executable references, linked Mach-O libraries, bundled interpreters, and generated credentials.
Deleting the Controller release directory or selecting a Node role is not proof.
The generic-secret scan includes implicit Mix `releases/COOKIE`, default or generated OTP cookies, embedded environment files, and test credentials.
No reusable shipped credential may authorize a production peer.

The Node-local client preserves key and CSR generation, `certificate_identity/2`, `validate_issued_identity/1`, protected Store staging and atomic finalization, certificate and key matching, URI SAN checks, Controller identity checks, and every required client dependency.
It excludes Controller CA private keys, certificate issuance, trust administration, direct Repo access, policy mutation, admission, lifecycle mutation, and unrelated operator commands.
Its surface is limited to `orchard-node node join --enrollment-bundle PATH`, local identity and status diagnostics, help, and version.
Every extraction pull request includes invalid-certificate, mismatched-identity, interrupted-finalization, no-Repo-start, and no-Controller-module regression evidence.

### 3. One Provisioning Configuration And A Fixed Helper Protocol

The root-authorized lifecycle owns one schema-versioned `config/node.json` under the dedicated installation root.
It records the profile, Controller endpoint and bootstrap trust reference, advertised private address and control port, fixed Node Identity Root, service UID and GID, selected transport policy, and local release-trust reference.
It contains no enrollment token, private key, Peer Grant plaintext, or database material.
It is root-owned and readable only by the Node service group where required.
The Node service cannot rewrite it.

The app, join client, non-serving certificate-control bootstrap, and ordinary Node runtime consume the same configuration schema.
Caller environment, inherited environment files, CLI flags, and wrapper defaults cannot silently override endpoint, identity root, service identity, transport, or release trust.
An explicit root-authorized configuration operation writes a complete replacement atomically before enrollment.
Conflicts fail before token redemption.

The helper is an authenticated, fixed-operation protocol bound to the signed app and dedicated profile.
Signed code identity proves which client is calling but does not authorize a privileged operation.
For signed-app requests, the invoking interactive principal must obtain the accepted `com.orchard.node.lifecycle.manage` Authorization Services right through explicit administrator authentication for each new helper authorization session.
The external authorization reference is bound to one short-lived helper session, the invoking audit identity, operation code, canonical argument and input digest, a helper-issued nonce, and a strictly increasing request sequence.
Direct root CLI invocation is permitted only when the effective UID is 0 and the caller is the exact installed, root-owned `orchard-node` executable.
Both paths remain subject to the same operation, path, executable, profile, and service allowlists.
It accepts only versioned operations over allowlisted Node-owned paths and service labels.
It rejects arbitrary executables, shell commands, arbitrary arguments, Controller or database roles, caller-selected system roots, customer CA administration, system trust mutation, and unowned paths.
The real-system root is fixed.
Relocated roots are test-only and simulate service management.

The signed-app Join action may ask the helper to run only the exact installed join executable as `_orchardnode`.
The bundle enters through a bounded protected input channel and is cleared after use.
The helper verifies caller and executable code identity, input ownership and size, target service identity, and configuration agreement without logging the bundle or token.

### 4. Release Trust Is Separate From Customer Trust

Release verification uses an app-specific trust store under the dedicated installation root.
It is separate from the customer enrollment CA, Controller Certificate trust, macOS system trust, and Node identity stores.

For first installation, the signed and notarized verifier contains the owner-approved Orchard release-root key identifiers and fingerprints plus the expected Apple Team identity.
A detached release registry must validate under one of those preapproved roots.
A Candidate Manifest, release record, or candidate-supplied registry cannot add the key that authorizes itself.

The helper may expose one fixed `install-release-trust` operation that writes only the app-specific release-trust store after verifying a registry under an already trusted root.
It is not a generic trust-store operation.
Rotation requires a monotonic registry generation, authorization by a previously trusted unrevoked root, explicit new and retiring key identities, effective times, and rollback protection.
Offline media carries the same signed registry and cannot introduce a different trust path.
The exact first roots, Apple Team identity, custody, and rotation ceremony are owner decisions and release prerequisites.

### 5. Immutable Release Identity And Separate Activation Authorization

The selected download record is a projection of the governance Candidate Manifest.
It binds Product Version, release channel, source commit, build identity, Candidate Manifest digest, final DMG digest, mounted app identity, sealed Node payload identity, bundle identifier, Apple Team and signing identity, before and after signing evidence, SBOM reference, platform and provider tuple, and exact Controller compatibility declaration.
The record and final Candidate Manifest remain detached from the sealed DMG to avoid digest self-reference.
Installed verification reproduces the authenticated mounted app and payload identity.

The release-governance owner must add a distinct `Release Activation Attestation` before Node activation implementation begins.
It is not a distribution approval, GitHub or Amore surface state, or implicit lease over an already running process.
The attestation binds at least:

- contract version and activation purpose;
- Product Version, release channel, Candidate Manifest digest, and exact Node artifact identity;
- eligible verified candidate and distribution state;
- bundle identifier and platform tuple;
- monotonically increasing sequence within the artifact release lineage;
- registry generation and signing key identifier;
- issue, not-before, and expiry times;
- withdrawal, supersession, and replacement relationship;
- maximum accepted clock skew and offline verification policy.

Install, update, enrollment, and serving startup require a currently valid activation attestation.
Known withdrawal has precedence over a later-expiring older authorization.
Replay below the highest accepted lineage sequence fails closed.
Unknown or rolled-back local time, excessive clock uncertainty, unavailable trusted state, incompatible Controller version, or an expired attestation blocks the new transition.
Connected refresh verifies the same authority and does not replace bytes automatically.

An already running Node remains governed by admission, certificate, Peer Grant, Controller policy, and Runtime Endpoint health.
Activation freshness is checked again only at a new activation boundary, including restart.
Release recall uses explicit Controller exclusion and the manual lifecycle.
Automatic recall, forced shutdown, or unattended replacement requires a separate accepted contract.

The proposed Apple allocator is one global monotonic `1..9999` sequence across both `com.orchard.app` and `com.orchard.node`.
The Candidate Manifest records each artifact's bundle identifier, `CFBundleShortVersionString`, and allocated `CFBundleVersion`.
Each app artifact receives its allocation before construction under `{build_kind, candidate_or_internal_build_identity, full_source_commit, product_version, channel, bundle_identifier, staged_payload_identity}`.
An unchanged pre-seal construction retry reuses that allocation; any changed key consumes a new allocation, and abandoned numbers are never recycled.
Construction and signing then bind the allocation record to the final sealed artifact digest in the Candidate or Internal Build Manifest.
Any byte change after manifest sealing invalidates that artifact and requires a new Product Version and signed tag for a Candidate, or a new governance-issued construction identity for an Internal Build, before another allocation and construction attempt.
The Release Owner must accept this extension and seed it against all historical values before qualification.

### 6. Acquisition, Enrollment, Admission, Authorization, And Serving Are Distinct

The operator journey uses these ordered states.

1. **Acquire.**
Obtain the DMG and detached release set from an authorized source.
2. **Verify.**
Validate Developer ID and notarization, release registry, Candidate Manifest projection, activation attestation, final digest, mounted app, sealed payload, platform tuple, and compatibility.
3. **Install.**
Run the root-authorized clean-host lifecycle.
Installation creates no Node identity and leaves serving disabled.
4. **Configure.**
Persist the Controller, trust, address, identity-root, service, transport, and release references.
5. **Create and transfer enrollment.**
The Controller creates the existing short-lived one-use enrollment artifact.
The Console selects `orchardctl` for existing profiles and describes the expected post-install dedicated join surface only when this profile and an eligible release have been selected.
The Controller does not claim to observe target-host installation before enrollment.
The target-host client verifies installation and release identity locally before token redemption.
6. **Finalize local identity and register.**
The service identity generates the key and CSR, redeems once, validates the response, and atomically finalizes the protected Store.
Remote registration without local finalization is incomplete.
7. **Run control-only bootstrap.**
The certificate-authenticated control and recovery surface may start, but production BEAM Distribution and inference remain disabled.
Status says `registered; awaiting admission`.
8. **Admit atomically.**
The active Controller transaction commits the Node Admission Decision, cluster audit, phase-appropriate explicit dispatch-capacity policy, admission state, and initial `pending_delivery` Peer Grant metadata for every eligible Controller instance.
Failure of any constituent rolls back the entire admission.
9. **Deliver, stage, acknowledge, and activate authorization.**
The exact certificate-bound Peer Grant is retrieved while `pending_delivery` over the authenticated control channel, staged under the protected identity roots of both endpoints, and acknowledged without requiring an existing BEAM connection.
The Controller advances the durable grant to `active` only after both endpoint staging acknowledgements match the grant identity, generation, scope, and certificate bindings.
Lost responses are retried idempotently from the durable grant state, and any mismatch leaves the grant non-active and the Node non-serving.
10. **Start production transport.**
Validate Node and Controller Certificates, trusted inventory, canonical names and addresses, active grant scope, generation, expiry, revocation state, and current admission before OTP TLS Distribution starts.
11. **Publish readiness.**
Negotiate the pinned Worker Runtime, prove provider and model readiness, and publish fresh authenticated health and Runtime Endpoint facts independently of request-time dispatch authorization.
The Controller-owned activation evaluator verifies those facts, current admission, exact identity, active grant, successful activation-boundary evidence, and the phase-appropriate capacity policy persisted by admission before triggering the existing automatic `admitted -> active` lifecycle promotion.
12. **Schedule and serve.**
Only after activation may the Node become scheduler-eligible, and every inference request remains subject to current leader and dispatch-capacity authorization.

The current enrollment JSON schema and one-time publication contract do not carry release bytes or release authority.
Download does not imply installation.
Installation does not imply registration.
Registration does not imply admission.
Admission does not imply grant delivery.
A Peer Grant does not imply Controller leadership.
Transport connectivity does not imply readiness.
Readiness does not bypass Controller dispatch capacity or scheduling policy.
Activation-attestation expiry after successful startup does not become a serving lease or invalidate an otherwise healthy running Node.
Restart and every other enumerated new activation boundary require current activation authority.

Issue #371 governs a different recovery question.
Before redemption, a lost or failed one-time bundle remains non-redisplayable and current Console recovery creates a new enrollment with a distinct name.
After a remote registration response is lost, only the existing matching-enrollment, matching-key, and matching-CSR resume path may recover that same identity.
Same-name replacement, supersession, or recovery requires separate acceptance and implementation of issue #371.
This proposal does not invent token replay or identity takeover.

### 7. Production BEAM Is Exact And Fail-Closed

The production path uses certificate-authenticated control for enrollment, certificate lifecycle, Peer Grant delivery and recovery, and diagnostics.
It uses OTP TLS Distribution for the first-party Runtime Endpoint only after admission and the exact active Peer Grant are valid.
The retained control path is not an inference fallback.

Canonical names derive from trusted inventory using the complete Node and Controller UUID forms required by `SPEC.md`.
An address change is an authenticated inventory mutation that requires a new canonical name, new grant generation, and deliberate reconnect.
Static targets and shared-cookie smoke remain source-development or explicitly selected compatibility evidence only.
They cannot authorize this profile.

Missing, invalid, expired, withdrawn, revoked, wrong-generation, wrong-certificate, wrong-name, or undelivered grants keep the Node non-serving.
Certificate renewal causes grant rotation.
Revocation updates durable authority, removes scheduler eligibility, changes exact-name authorization, disconnects the peer, and remains visibly incomplete until disconnection or process restart is proved.
There is no shared production cookie and no silent gRPC inference retry.
The gRPC deprecation release epochs must preserve certificate control, grant delivery and recovery, diagnostics, and Worker Runtime roles until a separately accepted replacement exists.

### 8. Manual Lifecycle Has A Distinct Repair Entry

Install performs exact release and clean-host preflight before mutation.
It redeems no enrollment and starts no serving process.
Launchd may restart the non-serving supervisor, but every serving transition rechecks lifecycle certainty, configuration, retained identity, release activation, admission, Peer Grant, transport, and runtime authorization.

Manual update requires explicit operator intent, current compatible activation authorization, Controller cordon, completed drain, maintenance state, prevented restart, serialized local custody, and verified exit of the exact Node Agent and Worker Runtime processes.
Failure to prove Controller exclusion, restart suppression, identity-root exclusion, or process exit blocks mutation.
The initial profile accepts only retained-state-compatible updates with no configuration or Node identity schema migration.

The lifecycle retains a root-owned `config/lifecycle-ownership.json` record outside replaceable payload bytes.
It binds the profile, installed app and payload identity, Node ID when present, service UID and GID, owned path set, receipt generation, last completed transaction, and retained-state disposition.
Default uninstall updates and retains this record while removing executable state.
The record grants no cluster trust or serving authority.

Ordinary update requires an intact active receipt plus exact owned-path verification.
Repair has a separate entry gate.
It may proceed from an intact active receipt or a retained ownership record only when the signed app identity, fixed profile, service identity, installation root, Node Identity Root, and non-secret ownership facts agree.
Repair is diagnostic first and may restore only verified Node-owned executable, service, command, configuration, and receipt state.
It cannot infer custody from retained identity alone, reissue identity, redeem enrollment, accept partial TLS, mutate customer or system trust, or re-enable serving because bytes were restored.
Before repair mutates any runtime-affecting state, it suppresses restart, acquires serialized local custody, and proves exact Node Agent and Worker Runtime exit.
When the Controller is reachable, mutating repair also requires Controller maintenance exclusion.
When the Controller is unreachable, repair may change verified local Node-owned state only while launchd remains disabled and must record `remote coordination pending`; it cannot restart or restore eligibility until Controller maintenance, admission, grant, and runtime state are reconciled.
If neither receipt nor retained ownership evidence can prove custody, repair stops without mutation and requires explicit Controller decommission plus an owner-approved forensic or fresh-host path.

Every mutation uses a serialized transaction and a durable incomplete-operation marker.
An interrupted or unverifiable operation remains stopped.
Rollback may restore prior Node-owned bytes, links, service records, and receipt, but restart requires current release activation, compatibility, identity, admission, Peer Grant, and runtime checks.
Withdrawn or expired rollback bytes remain stopped.

Default removal verifies exact process exit, removes Node-owned executables, helper, services, commands, and payload, and retains configuration, identity, models, bundles, logs, support material, and the lifecycle ownership record.
Remote decommission and local removal are separate.
If the Controller is unreachable, local removal reports remote revocation pending and does not claim decommission or destructive purge.

This lifecycle is not ADR 0030's managed transition.
It has no source baseline, transition generation, atomic generation pointer, one-shot provisional child, host-arm token, or managed automatic update.

## Staged Acceptance

**Stage A - Closed composition**

- The exact Node app, release, client, helper, configuration, trust store, and native payload are assembled from allowlists.
- Static and runtime closure rejects Controller, Repo, CA, policy, unrelated command, and reusable credential authority.
- Relocated lifecycle and signing-contract tests preserve the all-in-one app unchanged.
- No production support claim follows.

**Stage B - Clean-host registration**

- A compatible clean Mac acquires, verifies, installs, and configures the selected Node release without source tools, a source checkout, local Controller, or database.
- Pre-redemption agreement failures spend no token.
- Local identity finalization and registration succeed or fail under the existing identity-bound recovery contract.
- The final state is `registered; awaiting admission`, with no production transport, scheduler eligibility, serving, support, or completion claim.

**Stage C - Admitted qualified worker**

- Atomic admission includes capacity policy and initial grant metadata.
- Certificate-authenticated grant delivery, OTP TLS Distribution, canonical identity, rotation, revocation, reconnect, and no-fallback behavior pass.
- Worker Runtime readiness and exact-model inference, streaming, cancellation, and failure normalization pass on every declared tuple.
- Reboot, offline activation freshness, manual update, rollback, interruption, repair, removal, and remote-decommission reporting pass.
- Experimental Peer Grant tracers and shared-cookie smoke cannot substitute for this evidence.

Strict OpenSpec validation confirms only that this change package is structurally valid.
It does not approve this architecture, implement any task, qualify hardware, authorize credentials, sign or notarize a candidate, create a release, publish bytes, establish support, or change repository visibility.

## Risks / Trade-offs

- Hidden client dependencies can retain Controller code.
Assembled inventory and runtime negative assertions are both required.
- A privileged helper can become a generic root execution surface.
The protocol is fixed, app-bound, profile-bound, path-bound, and covered by hostile-input tests.
- Release activation can become a second release authority.
The attestation is owned by release governance and activation consumes it without redefining Candidate or distribution state.
- Offline freshness can block restart of authentic bytes.
The owner must publish the interval, clock policy, renewal procedure, and recovery path before release.
- Manual lifecycle causes downtime.
The design accepts a stopped interval and refuses overlapping processes.
- Registration can be mistaken for readiness.
Stage B is explicitly incomplete and non-serving.
- The current same-name recovery gap can confuse operators.
Guidance must state current behavior and must not imply issue #371 is solved.

## Migration And Rollback

There is no in-place migration from `Orchard.app`, a source checkout, a legacy package, or the managed profile.
The first supported path, if approved and qualified, is clean-host installation.

The first implementation pull request is contract-only.
It reconciles `SPEC.md`, affected main specifications, decisions, release governance, profile identity, Console command selection, activation authorization, trust bootstrap, Apple allocation, repair entry, and dependency order.
It changes no runtime behavior and creates no artifact.

Later behavior pull requests follow the boundaries in `tasks.md`.
Each includes its own focused failure-path evidence and the applicable repository workflow.
A failed implementation slice rolls back through ordinary Git and product-code rollback until the dedicated lifecycle itself is implemented and qualified.
No implementation pull request may use signing, notarization, publication, or support language as validation.

Before any candidate release, the exact engineering head must pass the full applicable credential-free Elixir, native, Swift, lifecycle, app, signing-contract, DMG, and strict OpenSpec workflows.
Stage B and Stage C then require a separately authorized exact candidate whose inner components and outer app are signed in order, notarized, stapled, activated, and verified without changing final bytes.
Developer ID credentials, notarization, and candidate activation are explicit owner-authorized inputs to qualification.
Delivery, publication, support, and public visibility remain separate later decisions and do not follow from qualification.
