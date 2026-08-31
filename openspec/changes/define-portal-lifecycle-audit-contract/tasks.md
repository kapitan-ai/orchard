## 1. Owner Review Gates

- [ ] 1.1 Approve or revise `portal_user.invited`, `portal_user.invite_issued`, `portal_user.invite_reissued`, `portal_user.invite_redeemed`, and `portal_user.disabled`.
- [ ] 1.2 Approve separate Portal User creation and first invite issuance events.
- [ ] 1.3 Approve `user` plus Portal User ID as successful redemption and Portal key actor provenance.
- [ ] 1.4 Approve committed-effective-transition audit rows without a persisted outcome field.
- [ ] 1.5 Approve no duplicate success audit for rejected requests, repeated disable, or repeated revoke.
- [ ] 1.6 Approve Console `operator` provenance with null actor ID and `surface = "console"`.
- [ ] 1.7 Approve the per-action non-secret payload allowlist and the exclusion of `previous_invite_existed`.
- [ ] 1.8 Confirm that PR #300 invite lifecycle, route, persistence, and key-survival semantics remain unchanged while accepting the explicit repeated-disable, repeated-revoke, and stale-session behavior changes in this proposal.

## 2. Portal Audit Implementation

- [ ] 2.1 Make one outermost `AuditWriter.transaction/1` call own each Portal User creation, invite issue or reissue, redemption, disablement, and Portal-owned API Key mint or revoke mutation.
- [ ] 2.2 Insert the required tenant-scoped audit row in the same transaction as each effective mutation.
- [ ] 2.3 Roll back the complete mutation and withhold any secret-bearing success result when audit insertion fails.
- [ ] 2.4 Classify initial issuance versus reissue from invite-row state observed under the locked Portal User.
- [ ] 2.5 Generate the Copy invite token and calculate its expiry only after the Portal User lock, persist that exact expiry in the invite and audit row, and return the matching plaintext URL only after commit.
- [ ] 2.6 Carry the validated Portal session tenant ID, Portal User ID, and password epoch into key mutations; lock and revalidate the active Portal User and matching epoch before applying the Portal User then API Key lock order.
- [ ] 2.7 Make repeated disable and Portal revoke true no-ops with no timestamp rewrite, session-epoch change, duplicate audit row, or success telemetry.
- [ ] 2.8 Enforce the approved actor, target, and secret-free payload contract.
- [ ] 2.9 Preserve Portal User-first lock ordering for Copy invite, redemption, disablement, and Portal-owned key mutations.

## 3. Metrics Implementation

- [ ] 3.1 Map every `portal_user.*` audit action to the bounded `portal_user` action domain.
- [ ] 3.2 Add `portal_user` to the metrics normalizer's closed audit action vocabulary.
- [ ] 3.3 Raise the audit-events family ceiling from 24 to 36.
- [ ] 3.4 Reconcile the accepted worksheet to 2,600 total series and 2,400 series of headroom without absorbing the issue #121-owned 229-series attempt/retry drift into this change.
- [ ] 3.5 Prove that successful audit telemetry is emitted only after the outermost `AuditWriter.transaction/1` commits, including a regression test that forbids publishing from a nested audit transaction before an outer rollback.

## 4. Regression Coverage

- [ ] 4.1 Cover each effective action's tenant scope, actor, target, timestamp, and payload.
- [ ] 4.2 Inject audit insertion failures and prove complete mutation rollback and absence of success telemetry.
- [ ] 4.3 Cover concurrent first Copy invite classification and prove one issued event followed by reissued events, lock-time token and expiry generation, and monotonically extending stored expiry under serialization.
- [ ] 4.4 Cover repeated disable and repeated revoke as mutation-free no-ops.
- [ ] 4.5 Cover invalid, expired, redeemed, wrong-Organization, disabled-user, and unknown-token redemption as mutation-free without success audit evidence.
- [ ] 4.6 Assert that every prohibited secret, secret-derived value, email, raw request field, and `previous_invite_existed` is absent.
- [ ] 4.7 Cover the twelve-domain by three-outcome metrics ceiling.
- [ ] 4.8 Cover Portal key mint and revoke rejection when the validated session epoch is stale at locked mutation time, and prove the API Key is not locked or mutated first.

## 5. Contract Reconciliation And Validation

- [ ] 5.1 Reconcile accepted owner decisions into `SPEC.md`, accepted OpenSpec specs, product docs, and implementation tests in the later implementation PR.
- [ ] 5.2 Run the complete applicable Elixir format, compile, Credo, Dialyzer, test, and coverage workflow for implementation changes.
- [ ] 5.3 Run focused Portal governance, Console, endpoint, audit writer, and metrics suites.
- [ ] 5.4 Run strict targeted and all-spec OpenSpec validation.
- [ ] 5.5 Scan accepted specs and the change package for placeholder purpose text, unfinished markers, and contradictory stale lifecycle language.
- [ ] 5.6 Obtain independent contract and code review before archive.
- [ ] 5.7 Record a future Devin or mawarduri trigger only if implementation later reaches a genuinely macOS-specific Orchard.app, launchd, Keychain, DMG-installed, HTTPS, clipboard, or accessibility boundary that portable browser tests and hosted macOS CI cannot prove.
