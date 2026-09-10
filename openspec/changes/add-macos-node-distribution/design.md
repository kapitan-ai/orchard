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

Dependency state refreshed after PR #384 merged is mixed.

- PR #105 merged the product-versioning and release-governance proposal, but its release workflow, activation authorization, Node bundle allocation, and most implementation tasks are incomplete.
- PR #333 merged Controller release decoupling from CLI, but the Node-local CLI still needs its own closed extraction proof.
- PR #359 merged Console enrollment and one-time delivery with `orchardctl` guidance.
The dedicated profile needs a follow-on contract and implementation for profile-aware guidance.
- PR #384 merged the audited recovery contract for issue #371; it did not implement same-name recovery.
Current no-redisplay, identity-bound resume, and distinct-name replacement runtime behavior remains until the accepted recovery contract is implemented.
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

## Decisions And Requirement Ownership

`SPEC.md` remains the current product contract.
The capability deltas contain the proposed changes; this design records their rationale and unresolved owner choices.
Implementation PR 1 reconciles accepted changes into the apex contract before behavior implementation.
It must reconcile references and remove superseded duplication rather than maintain a second full contract here.

| Decision | Proposed requirement owner | Rationale |
|----------|----------------------------|-----------|
| Separate clean-host app and exclusive paths | [Distinct profile and ownership](specs/macos-node-distribution/spec.md#requirement-dedicated-node-distribution-has-a-distinct-profile-and-exclusive-ownership), [platform profile](specs/platform-profiles/spec.md) | Separate custody avoids silently adopting an all-in-one, legacy, or managed installation. |
| Closed release and minimal enrollment client | [Payload closure](specs/macos-node-distribution/spec.md#requirement-node-payload-proves-controller-free-closure), [client authority](specs/macos-node-distribution/spec.md#requirement-node-client-preserves-complete-identity-validation-with-minimal-authority) | A role selector cannot prove that compiled or dynamically loaded Controller authority is absent. |
| Shared provisioning and constrained helper | [Provisioning configuration](specs/macos-node-distribution/spec.md#requirement-enrollment-and-runtime-share-one-provisioning-configuration), [app lifecycle](specs/app-distribution-lifecycle/spec.md) | Join and runtime must consume the same identity and configuration; signing identifies a caller but does not grant administrator permission. |
| Separate release trust and activation authority | [Release governance](specs/product-release-governance/spec.md), [Node verification](specs/macos-node-distribution/spec.md#requirement-release-identity-and-activation-authorization-are-distinct) | Candidate identity, publication approval, and permission to start are separate facts; the consumer must not invent a second release authority. |
| Acquisition before enrollment | [Acquisition](specs/macos-node-distribution/spec.md#requirement-acquisition-and-enrollment-remain-separate), [Console journey](specs/operator-first-run-journey/spec.md) | Installing software before minting an expiring bundle avoids spending bootstrap lifetime on acquisition. |
| Admission, grant delivery, transport, readiness, and serving | [Atomic admission and delivery](specs/macos-node-distribution/spec.md#requirement-admission-preserves-capacity-policy-and-initial-grant-atomicity), [enrolled startup](specs/macos-node-distribution/spec.md#requirement-enrolled-startup-is-explicitly-beam-first) | Initial grant delivery cannot depend on the BEAM connection it authorizes, and runtime evidence cannot depend on request-time dispatch authority. |
| Stopped manual replacement and separate repair entry | [Manual lifecycle](specs/macos-node-distribution/spec.md#requirement-manual-lifecycle-uses-distinct-ordinary-and-repair-entry-gates) | Repair must remain possible when a receipt is damaged without treating retained identity as custody or restoring serving prematurely. |
| Staged exact qualification | [Completion](specs/macos-node-distribution/spec.md#requirement-completion-requires-admitted-qualified-inference), [packaging](specs/packaging-deployment/spec.md) | Registration alone does not prove production transport, inference, lifecycle, or release readiness. |

### Implementation Details Not Repeated In The Deltas

The configuration is readable only by the Node service group where required; the Node service cannot rewrite it.
Relocated validation roots relocate every path and simulate launchd, while real-system roots remain fixed.
The protected Join input is cleared after use.
The fixed release-trust helper operation is named `install-release-trust` and writes only the app-specific store.

Release records remain detached from the sealed DMG to avoid digest self-reference.
Any byte change after manifest sealing invalidates the artifact and requires a new Product Version and signed tag for a Candidate, or a new governance-issued construction identity for an Internal Build, before another allocation and construction attempt.
Release recall uses explicit Controller exclusion and the manual lifecycle.

Canonical names derive from trusted inventory using the complete Node and Controller UUID forms required by `SPEC.md`.
An address change is an authenticated inventory mutation requiring a new canonical name, new grant generation, and deliberate reconnect.
Certificate renewal causes grant rotation.
Revocation updates durable authority, removes scheduler eligibility, changes exact-name authorization, disconnects the peer, and remains visibly incomplete until disconnection or process restart is proved.
The retained control channel has no inference fallback role.

Launchd may restart the non-serving supervisor, but every serving transition rechecks lifecycle certainty, configuration, retained identity, release activation, admission, Peer Grant, transport, and runtime authorization.
Repair and update must prove identity-root exclusion as part of serialized custody.
Removal covers the helper, services, command, and payload as Node-owned executable state.
Removal retains all operator-owned contents under the `support/` namespace without providing a support-bundle collection capability.

### Activation Recovery Ownership

The release-governance implementation supplies renewal issuance and authenticated trusted-time/state recovery evidence under the owner-accepted policy.
Implementation PR 5 owns the Node-side recovery operation, including explicit connected refresh and offline import while serving remains stopped.
That path must work without production BEAM or an already-valid activation attestation, while retaining helper authorization, existing release trust, withdrawal precedence, and replay protection.
It must preserve installed bytes and Node identity, atomically restore verified authorization state, and then rerun the ordinary startup gates.
When trusted state cannot be recovered under the accepted policy, it reports a terminal blocker rather than resetting trust or treating the local clock as authority.
Implementation PR 14 qualifies both successful recovery and refused invalid recovery; offline-expiry qualification cannot precede PR 5 recovery evidence.
The exact policy and evidence format remain owner decisions under the release-governance delta.

### Staged Acceptance

The completion requirement owns the Stage A, B, and C obligations and the exact qualification tuple.
`tasks.md` assigns their implementation and evidence: PRs 2-5 establish composition and local authority, PRs 6-7 establish clean-host registration, and PRs 8-14 establish admitted inference and lifecycle qualification.
Stage B remains `registered; awaiting admission` and does not complete this change.
All-in-one preservation, no-token-spend failures, runtime failure normalization, and current identity-bound resume remain required by the corresponding task and capability, even when an earlier stage passes.

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
- The current same-name recovery implementation gap can confuse operators.
Guidance must distinguish the merged #384 contract from available runtime behavior.

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
