## Why

Adding a worker requires executable Node software before an enrollment bundle can be redeemed, but the current macOS artifact couples direct Node provisioning to the broader `Orchard.app` payload and `orchardctl` closure.
A dedicated prebuilt Node distribution should let an operator acquire, install, configure, register, admit, authorize, qualify, and operate an Apple Silicon worker without a source checkout or local Controller, while keeping each transition explicit and independently auditable.

## What Changes

- Propose a distinct `dedicated_apple_silicon_macos_node` distribution profile delivered as a signed and notarized DMG containing `Orchard Node.app`.
- Preserve the existing all-in-one `Orchard.app`, its role-selected lifecycle, `orchardctl`, paths, services, and release gates unchanged.
- Require an actual Controller-free OTP application, release, boot, module, dynamic, and native dependency closure.
- Extract a minimal Node-local enrollment client that preserves key generation, CSR generation, issued-identity validation, and protected Store finalization without Controller CA, persistence, policy, lifecycle, or unrelated operator authority.
- Give the dedicated app exclusive command, helper, service, receipt, configuration, identity, and retained-state ownership on clean hosts, with explicit administrator authorization for privileged operations and a distinct fail-closed repair entry contract.
- Keep release acquisition separate from installation, enrollment-bundle creation, target-host registration, Controller admission, Peer Grant authorization, schedulability, and serving.
- Extend release governance before implementation with Node activation authorization, clean-host release-trust bootstrap and rotation, offline freshness, withdrawal precedence, and Apple build-number allocation for `com.orchard.node`.
- Amend Console enrollment guidance to select `orchard-node` or the signed-app Join action only for the dedicated profile while preserving `orchardctl` for existing profiles and preserving the one-time enrollment artifact.
- Preserve the current atomic admission boundary, including the Node Admission Decision, audit event, phase-appropriate Controller dispatch-capacity policy, and initial Peer Grant metadata.
- Require certificate-authenticated control and recovery, exact trusted inventory and canonical names, scoped Peer Grant delivery, OTP TLS Distribution, Worker Runtime readiness, and scheduler authorization with no shared cookie or silent gRPC inference fallback.
- Define manual install, update, rollback, repair, and removal with stopped replacement, verified process exit, retained identity, and explicit remote decommission status.
- Stage acceptance as A: closed composition, B: clean-host registration awaiting admission, and C: admitted and authorized qualified inference plus lifecycle evidence.
Stage B does not complete this change or establish production support.
- Reshape the original checklist into ordered owner-decision gates, reviewable implementation pull requests that pair behavior with failure-path evidence, and recurring validation or credentialed release gates.

## Capabilities

### New Capabilities

- `macos-node-distribution`: Defines clean-host Node-only composition, configuration and identity custody, release verification, enrolled startup, manual lifecycle, repair, and staged qualification.

### Modified Capabilities

- `packaging-deployment`: Adds a separate dedicated Node DMG without changing the all-in-one payload or implying a supported public binary.
- `app-distribution-lifecycle`: Adds profile-specific app identity, constrained helper authority, stopped replacement, retained ownership evidence, and fail-closed repair for the dedicated Node profile.
- `platform-profiles`: Reserves a dedicated clean-host macOS Node distribution profile distinct from the experimental managed source-baseline transition.
- `operator-first-run-journey`: Makes target-host join guidance distribution-profile-aware without changing bundle creation, one-time delivery, registration, or admission semantics.
- `product-release-governance`: Requires a governance-owned Node activation-authorization contract and Apple build-number allocation for `com.orchard.node` before the artifact can activate.

## Impact

- `SPEC.md` impact: acceptance requires focused amendments to §§1.4, 2.5, 4.2-4.6, 7.5.0-7.5.1, 10.5-10.6, 11-11.4, 11.7, 11.9, 13.1, and 13.4.
The amendments must permit the separately named Node distribution, preserve the all-in-one contract, define the Node-local client boundary, preserve atomic admission authority, and add the dedicated manual lifecycle and activation gates.
This proposal does not edit `SPEC.md` or authorize behavior implementation.
- Release-governance dependency: PR #105 established the product-version and Candidate Manifest proposal, but activation authorization, clean-host release-trust bootstrap, `com.orchard.node` allocation, and most release workflow implementation remain incomplete.
Those contracts and implementation must land before Node activation or qualification work consumes them.
- Console dependency: PR #359 implemented the one-time Console flow with `orchardctl node join` guidance.
A profile-aware guidance amendment must land before the dedicated artifact is offered through Add Node.
- CLI dependency: PR #333 removed the reverse Controller-to-CLI release dependency.
It did not remove the Node CLI's transitive Controller closure and is not Stage A evidence.
- Enrollment recovery dependency: PR #384 merged the audited recovery contract for issue #371, but did not implement same-name recovery.
This proposal preserves current no-redisplay and identity-bound resume behavior and must not promise same-name replacement until the accepted recovery contract is implemented.
- Admission dependency: current Controller dispatch-capacity authority is part of Node admission and must remain in the same transaction as admission, decision, audit, and initial Peer Grant metadata.
- Transport dependency: the gRPC deprecation contract removes only first-party inference compatibility in staged release epochs.
Certificate lifecycle, enrollment, Peer Grant delivery and recovery, diagnostics, and Worker Runtime gRPC remain until their own accepted replacements exist.
- Managed-composition relationship: PR #358 and ADR 0030 define an experimental source-baseline-to-prebuilt transition.
This clean-host distribution supplies a prerequisite productization path but does not adopt that transition generation, stable-bootstrap activation, managed update, or rollback protocol.
- Production completion depends on exact enrolled BEAM bootstrap, grant rotation and revocation, runtime readiness, Controller compatibility, and a declared macOS, Apple Silicon, MLX, and model feature matrix.
- Strict OpenSpec validity proves package structure only.
It is not architecture approval, implementation, real-hardware qualification, signing, notarization, release, support, publication, or repository-visibility approval.
- No official or supported public binary follows from this proposal.
Stage B and Stage C require a separately authorized signed, notarized, stapled, activation-authorized exact candidate.
Delivery, publication, support, and public visibility remain later and separately authorized gates.
