## 0. Proposal Acceptance Gates

- [ ] 0.1 Obtain explicit Repository Owner acceptance for all nine decisions in `design.md`: profile and artifact identifiers, Apple build-number authority, Release Activation Attestation, release-trust bootstrap and rotation, Console and #371 recovery behavior, repair ownership evidence, production BEAM integration ownership, the first qualification matrix, and privileged-operation authorization.
- [ ] 0.2 Record exact dependency state at implementation start for PR #105 release governance, PR #333 CLI decoupling, PR #359 Console enrollment, issue #371 and merged contract-only PR #384 recovery, Controller dispatch-capacity authority, PR #351 gRPC deprecation, and PR #358 managed composition.
- [ ] 0.3 Obtain collaborator acceptance of this proposal, design, six capability deltas, dependency order, staged acceptance, and pull-request boundaries without marking implementation complete.

## 1. Implementation PR 1 - Apex And Governance Reconciliation

This is the proposed first implementation pull request.
It is contract-only and changes no runtime behavior.

- [ ] 1.1 Amend only the required `SPEC.md` sections and affected main OpenSpec specifications to reserve the dedicated distribution profile, permit `Orchard Node.app`, preserve `Orchard.app`, define the Node-local authority boundary, preserve atomic admission capacity policy, and define the manual stopped lifecycle and repair entry.
- [ ] 1.2 Add or update one durable decision record that fixes the accepted identifiers, clean-host ownership, release trust, activation authorization, repair evidence, and explicit exclusion of the managed source-baseline transition.
- [ ] 1.3 Extend product release governance with the accepted Release Activation Attestation, lineage sequence, eligible states, withdrawal and offline clock rules, trusted-root bootstrap and rotation, renewal issuance and trusted-time/state recovery policy with an explicit governance implementation owner, and the approved `com.orchard.node` Apple build-number allocator using a pre-construction immutable key and post-construction sealed-digest binding.
- [ ] 1.4 Reconcile profile-aware Add Node guidance and issue #371 boundaries so existing profiles retain `orchardctl`, the dedicated profile receives expected post-install join guidance without a Controller-side installed-state claim, and no same-name replacement is promised.
- [ ] 1.5 Strictly validate the focused change and complete OpenSpec tree, review generated main specifications for placeholder prose, and obtain exact-diff architecture and security review before merging the contract.

## 2. Implementation PR 2 - Node-Local Enrollment Client

- [ ] 2.1 Extract a portable client-owned enrollment and identity-validation boundary that preserves key and CSR generation, `certificate_identity/2`, `validate_issued_identity/1`, certificate and key matching, URI SAN validation, Controller identity validation, and protected Store staging and finalization.
- [ ] 2.2 Add the narrow `orchard-node` parsing, local identity and status diagnostics, help, and version surface without Controller operations, lifecycle mutation, direct Repo access, CA issuance, trust administration, or unrelated commands.
- [ ] 2.3 In the same pull request, cover invalid and mismatched certificates, mismatched Node or Controller identity, interrupted Store finalization, owner and permission failures, no Repo start, and no Controller module load.
- [ ] 2.4 Run the complete applicable Elixir workflow and coverage plus focused strict OpenSpec validation for the exact head.

## 3. Implementation PR 3 - Closed Node Release And Closure Verifier

- [ ] 3.1 Add the dedicated OTP release and explicit application, module, native, tokenizer, interpreter, and MLX payload allowlists without adding app lifecycle or Console behavior.
- [ ] 3.2 Add assembled-byte and runtime closure verification over release metadata, boot terms, BEAM inventory, dynamic references, process starts, native executable references, linked Mach-O dependencies, and provider assets.
- [ ] 3.3 In the same pull request, reject Controller applications and bridges, Repo and migrations, database and HTTP services, CA and policy authority, unrelated native payloads, implicit `releases/COOKIE`, default OTP cookies, embedded environment secrets, and test credentials.
- [ ] 3.4 Prove the existing all-in-one release and payload remain byte-contract compatible with their current tests, then run applicable Elixir, native, payload, coverage, and strict OpenSpec gates.

## 4. Implementation PR 4 - Dedicated App, Helper, And Configuration Foundations

- [ ] 4.1 Add the accepted app, bundle, root, command, service user, daemon, helper, receipt, and distribution-profile identifiers with clean-host conflict detection and no all-in-one path replacement.
- [ ] 4.2 Implement the authenticated fixed-operation helper and schema-versioned `config/node.json` writer with real-system fixed paths, test-only relocated roots, atomic writes, accepted administrator-right enforcement for signed-app calls, and exact invoking principal, session, replay, caller, executable, service, and profile checks.
- [ ] 4.3 Permit only relocated lifecycle simulation and non-mutating real-system status, leaving real-system install, enrollment, serving, update, rollback, repair, removal, and release activation disabled until their owning pull requests land.
- [ ] 4.4 In the same pull request, test absent or stale administrator authorization, code-identity-only requests, authorization replay and session mismatch, arbitrary executable and argument rejection, Controller and database role refusal, customer and system trust-store refusal, unowned or symlinked path refusal, conflicting receipts, retained identity refusal, process conflicts, permission failures, and relocated launchd simulation.
- [ ] 4.5 Preserve all-in-one lifecycle behavior and run applicable Swift format, lint, build, test, coverage, service-lifecycle, app-build, signing-contract, DMG, Elixir, and strict OpenSpec gates.

## 5. Implementation PR 5 - Release Trust, Activation Verification, And Clean Install

This pull request is blocked until Implementation PR 1 and the required release-governance implementation, including renewal issuance and trusted-time/state recovery evidence, are merged.

- [ ] 5.1 Implement the app-specific release-trust store and fixed trust-install operation using the accepted compiled root fingerprints, Apple Team identity, monotonic registry generations, already-trusted rotation, revocation, and rollback protection.
- [ ] 5.2 Implement Candidate Manifest projection and installed app and payload reproduction without changing the sealed DMG or treating a filename, receipt, checksum, candidate record, or publication approval as sufficient authority.
- [ ] 5.3 Implement Release Activation Attestation verification for eligible states, artifact lineage sequence, withdrawal precedence, compatibility, not-before and expiry, maximum clock uncertainty, offline snapshots, and connected refresh without automatic replacement.
- [ ] 5.4 First enable real-system clean installation behind successful release and activation verification, using serialized lifecycle custody, a durable incomplete-operation marker, atomic receipt and ownership updates, verified rollback, and fail-stopped recovery from interruption.
- [ ] 5.5 In the same pull request, cover self-authorizing candidates, unknown roots, signer changes, stale and replayed sequences, withdrawn candidates, expired or future attestations, rolled-back clocks, incompatible Controllers, altered installed bytes, absent network egress, concurrent install, interruption at every mutation boundary, and rollback uncertainty.
- [ ] 5.6 Implement the Node-side activation recovery operation for explicit connected refresh and offline import without production BEAM or already-valid activation authority, using the accepted governance renewal and trusted-time/state evidence, existing release trust, helper authorization, withdrawal precedence, and replay protection.
- [ ] 5.7 In the same pull request, prove that recovery after expiry, clock rollback, and unavailable trusted state preserves installed bytes and Node identity, atomically restores verified authorization state, and reruns ordinary startup gates; reject forged, replayed, withdrawn, uncertain, or interrupted recovery without trust reset or automatic serving restoration.
- [ ] 5.8 Run governance, packaging, Swift, signing-contract, DMG, failure-path, coverage, and strict OpenSpec validation without using release credentials or enabling production installation against an unverified engineering artifact.

## 6. Implementation PR 6 - Profile-Aware Acquisition Guidance

- [ ] 6.1 Add one authenticated immutable Node release projection and target-machine acquisition step before enrollment creation without embedding installer bytes, release authority, or a claim of observed target-host installation in the enrollment bundle.
- [ ] 6.2 Make Console guidance retain `orchardctl node join` for existing profiles, but keep dedicated-profile enrollment issuance and actionable join guidance disabled behind an implementation-capability gate until PR 7 supplies the target-host join and local preflight.
- [ ] 6.3 Preserve one-time browser delivery, no redisplay, existing enrollment JSON, explicit admission, Pool intent, current distinct-name recovery, and matching-enrollment, matching-key, matching-CSR resume behavior.
- [ ] 6.4 In the same pull request, test profile mismatch, unavailable or withdrawn release, unavailable join capability, the absence of any Controller-side installed-state claim, download versus installation wording, registration versus admission wording, issue #371 non-claims, accessibility, and browser behavior.
- [ ] 6.5 Run focused Console, asset, browser, Elixir, coverage, and strict OpenSpec gates.

## 7. Implementation PR 7 - Join, Local Finalization, And Control-Only Registration

- [ ] 7.1 Implement the signed-app Join action and helper invocation of only the verified installed client as `_orchardnode` through the protected bounded input channel.
- [ ] 7.2 Enforce pre-redemption agreement across bundle endpoint and trust, persisted profile and configuration, effective and consuming identities, advertised address, identity root, permissions, transport, installed release, and current activation authority.
- [ ] 7.3 Start only the enrolled certificate-authenticated control and recovery bootstrap after atomic local Store finalization, and report `registered; awaiting admission` with production BEAM and inference disabled.
- [ ] 7.4 Enable the dedicated Console issuance and actionable guidance capability only with the target-host join preflight, then cover absent or mismatched installation rejection before token spend, token expiry and one-use failure, endpoint and owner mismatch without token spend, protected input cleanup, lost response identity-bound resume, remote registration followed by local-finalization failure, restart, and no automatic re-enrollment or same-name takeover.
- [ ] 7.5 Under separate credential and candidate-activation authorization, prove Stage B with the exact signed, notarized, stapled, activation-authorized candidate on a clean compatible Mac without source checkout, source toolchain, local Controller release, or database, then record that the change remains incomplete and unsupported.

## 8. Implementation PR 8 - Atomic Admission And Initial Grant Metadata

- [ ] 8.1 Extend the current admission transaction so Node Admission state, Node Admission Decision, cluster audit, phase-appropriate explicit Controller dispatch-capacity policy, and initial `pending_delivery` Peer Grant metadata for every eligible Controller instance commit atomically.
- [ ] 8.2 Preserve leader authorization, preview, confirmation, mutation-time revalidation, capacity-phase locking, controller-instance identity, and current pre-cutover or enforcing policy semantics.
- [ ] 8.3 In the same pull request, cover rollback when any constituent fails, concurrent admission, missing or malformed capacity phase, duplicate grant generation, unavailable Controller inventory, and no schedulability before later authorization and readiness.
- [ ] 8.4 Run focused admission, capacity, Peer Grant, audit, Elixir, coverage, and strict OpenSpec gates.

## 9. Implementation PR 9 - Initial Grant Delivery And Activation

- [ ] 9.1 Permit retrieval of the exact certificate-bound grant in `pending_delivery` only over the retained authenticated control channel and atomically stage it under the protected identity roots of both named endpoints without requiring an existing BEAM connection.
- [ ] 9.2 Bind each endpoint acknowledgement to grant identity, generation, scope, certificate identities, staged-byte digest, and admission, then advance the durable grant to `active` only after both acknowledgements match.
- [ ] 9.3 Make lost delivery or acknowledgement responses idempotently revalidatable from durable Controller and endpoint state; any disagreement remains non-active and non-serving.
- [ ] 9.4 In the same pull request, cover wrong certificate or Controller instance, malformed scope, stale generation, unavailable control path, partial staging, lost acknowledgement, replay, concurrent delivery, revocation before cutover, and restart before activation.
- [ ] 9.5 Run focused grant-delivery, control-channel, storage, Elixir, coverage, and strict OpenSpec gates.

## 10. Implementation PR 10 - Grant Lifecycle And OTP TLS Distribution

- [ ] 10.1 Derive canonical Node and Controller names and private addresses from trusted inventory, configure OTP TLS Distribution, and start the Runtime Endpoint only after current admission, exact certificate identity, and an active staged grant authorize both endpoints.
- [ ] 10.2 Implement grant rotation, certificate-renewal rebinding, revocation, deliberate reconnect, disconnect-incomplete status, protected credential custody, and stable failure normalization.
- [ ] 10.3 In the same pull request, cover wrong name, address, certificate, Controller instance, grant scope, generation, state, expiry, revocation, rotation race, unavailable control path, shared-cookie rejection, and no silent gRPC inference fallback.
- [ ] 10.4 Preserve enrollment, certificate, grant delivery and recovery, diagnostics, and Worker Runtime gRPC uses required by ADR 0029 while running the full transport, Elixir, coverage, and strict OpenSpec gates.

## 11. Implementation PR 11 - Runtime Readiness And Scheduler Eligibility

- [ ] 11.1 Negotiate the pinned Worker Runtime and verify provider, interpreter, protocol, model, tokenizer, feature, and capacity facts before publishing fresh authenticated health and Runtime Endpoint evidence independently of request-time dispatch authorization.
- [ ] 11.2 Add the Controller-owned activation evaluator that requires current admission, active Peer Grant, authenticated BEAM availability, exact identity, the recorded successful activation-boundary result, fresh runtime evidence, and the phase-appropriate capacity policy persisted by admission before automatic `admitted -> active` promotion.
- [ ] 11.3 Allow scheduler eligibility only after activation and require current leader and dispatch-capacity authorization for each inference request without revalidating attestation freshness as a serving lease.
- [ ] 11.4 In the same pull request, cover missing, malformed, stale, mismatched, or incompatible evidence, readiness loss, Controller authority loss, reconnect, process restart, transport failure, and attestation expiry during an uninterrupted healthy run without compatibility fallback or expiry-only descheduling.
- [ ] 11.5 Run focused Worker Runtime conformance, scheduler, dispatch, runtime, Elixir, native, coverage, and strict OpenSpec gates.

## 12. Implementation PR 12 - Manual Update And Rollback

- [ ] 12.1 Extend the initial-install lifecycle foundation with Controller exclusion, cordon, completed drain, maintenance state, restart suppression, and exact Node Agent and Worker Runtime exit proof required before replacement.
- [ ] 12.2 Implement retained-state-compatible manual update and rollback with an intact active receipt, compatible current activation authorization at each new startup boundary, no Node identity or configuration schema migration, and no automatic serving restoration.
- [ ] 12.3 In the same pull request, cover interrupted replacement, concurrent lifecycle requests, process-exit uncertainty, incompatible or withdrawn rollback, reboot, Controller unavailability, and fail-stopped recovery through the durable transaction journal.
- [ ] 12.4 Run the applicable Swift, lifecycle, app, signing-contract, DMG, Elixir, native, coverage, and strict OpenSpec gates.

## 13. Implementation PR 13 - Repair, Removal, And Decommission Reporting

- [ ] 13.1 Implement the distinct repair entry from an intact active receipt or matching retained ownership record, with diagnostic-first behavior, restart suppression, serialized local custody, exact Node Agent and Worker Runtime exit proof before runtime-affecting mutation, and a non-mutating terminal blocker when custody or quiescence cannot be proved.
- [ ] 13.2 Implement default local removal that retains configuration, identity, models, bundles, logs, retained operator-owned contents under the `support/` namespace, and ownership evidence while reporting remote decommission or revocation as a separate pending Controller action when unreachable.
- [ ] 13.3 Require Controller maintenance exclusion when reachable; when unreachable, permit only verified local repair with launchd disabled and `remote coordination pending`, with no restart or eligibility restoration before Controller state is reconciled.
- [ ] 13.4 In the same pull request, cover missing and corrupt receipts, retained-identity-only state, running processes, restart races, interrupted repair, partial TLS, wrong service identity, symlink and permission attacks, Controller unavailability, repeat removal, and no destructive purge or serving restoration.
- [ ] 13.5 Run the applicable Swift, lifecycle, app, signing-contract, DMG, Elixir, native, coverage, and strict OpenSpec gates.

## 14. Implementation PR 14 - Exact Stage C Qualification

PR 5 activation recovery evidence is a prerequisite for offline-expiry and restart qualification.

- [ ] 14.1 Freeze and record the accepted exact Controller, Node, macOS, hardware, provider, interpreter, model, tokenizer, feature, release-authorization, and network tuple before execution.
- [ ] 14.2 Under separate credential and candidate-activation authorization, qualify the exact signed, notarized, stapled, activation-authorized candidate for real Apple Silicon model load, inference, streaming, cancellation, failure normalization, capacity, restart, reconnect, certificate renewal, grant rotation and revocation, compatibility rejection, and no fallback.
- [ ] 14.3 Qualify offline acquisition and activation, authorization expiry at every new-activation boundary, successful renewal and trusted-time/state recovery after expiry or clock rollback, refusal of invalid recovery, manual update, rollback, interrupted replacement, repair, local removal, and remote-decommission reporting.
- [ ] 14.4 Record failures and residual matrix exclusions without widening the support claim, substituting experimental Peer Grant or shared-cookie smoke, or treating Stage B as completion.
- [ ] 14.5 Re-run the exact full repository and platform workflows required by `AGENTS.md`, strict validation for this change, strict validation for the complete OpenSpec tree, and an independent exact-head RepoPrompt architecture, security, and release-governance review.

## 15. Recurring Pull-Request And Release Gates

These are gates on the owning pull request or release operation.
They are not deferred implementation pull requests.

- [ ] 15.1 Every behavior-changing pull request includes its focused happy-path and failure-path evidence, applicable formatting, lint, typing, tests, coverage, and exact-head review results.
- [ ] 15.2 Every pull request preserves the all-in-one app and runs adjacent suites for the public path it changes.
- [ ] 15.3 Every OpenSpec-backed pull request runs `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate add-macos-node-distribution --type change --strict --no-interactive` and `git diff --check`.
- [ ] 15.4 Any accepted sync or archive runs repository-wide strict OpenSpec validation and reviews generated main specifications for incomplete prose.
- [ ] 15.5 Before Stage B or Stage C, a separately authorized exact candidate proves exact provenance, distinct per-artifact global Apple build allocation, inner-first signing, notarization, stapling, mounted DMG verification, detached Candidate Manifest and activation evidence, and unchanged final bytes.
- [ ] 15.6 Developer ID credentials, notarization, candidate activation, Amore or other delivery, GitHub or other publication, support claims, and public visibility each require their own explicit authorization and cannot be completed by checking an implementation task.
