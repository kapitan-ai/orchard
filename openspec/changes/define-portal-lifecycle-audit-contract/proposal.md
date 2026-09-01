## Why

`SPEC.md` requires audit evidence for Portal User invitation, reissue, redemption, disablement, and API Key creation and revocation.
Before this implementation, the shipped Portal governance paths did not write those audit rows.
PR #300 settled the invitation lifecycle, and PR #322 accepted the actor, action, outcome, no-op, concurrency, and metrics decisions for this slice.
This change implements that focused contract for atomic Portal lifecycle audit evidence, including Portal-owned API Key mint and revoke.

## What Changes

- Use five accepted Portal User audit actions: `portal_user.invited`, `portal_user.invite_issued`, `portal_user.invite_reissued`, `portal_user.invite_redeemed`, and `portal_user.disabled`.
- Reuse `api_key.created` and `api_key.revoked` for Portal-owned API Key mutations rather than creating Portal-specific aliases.
- Require each effective Portal mutation and its tenant-scoped audit row to commit or roll back through one outermost `AuditWriter.transaction/1` boundary.
- Require first issuance versus reissue to be classified from invite-row state observed under the existing Portal User lock.
- Require Copy invite token generation and expiry calculation after that lock is acquired so each serialized reissue extends the stored expiry.
- Require audit rows to represent committed effective transitions, with no duplicate row for a rejected request or a true no-op.
- Define actor, target, and payload rules that preserve Console operator provenance and Portal User provenance without granting new authority.
- Require successful audit telemetry only after the authoritative transaction commits.
- Add `portal_user` as one bounded audit metric domain and reconcile the audit-family ceiling with the current eleven-domain implementation plus this new domain.

## Accepted Decisions

PR #322 accepted the following decisions as the contract for this implementation slice.

1. **Separate creation and first issuance events.**
   Use `portal_user.invited` for creation of the invited identity and `portal_user.invite_issued` for the first Copy invite action because PR #300 established them as separate committed mutations.
2. **Attribute successful redemption to Portal User provenance.**
   Use `actor_type = "user"` and `actor_id = portal_user.id` for `portal_user.invite_redeemed`, while stating that invite possession is audit provenance only and does not make a Portal User a platform or Public Inference principal.
3. **Treat the committed row as the successful outcome.**
   Persist one audit row only for an effective committed mutation, without persisting an `outcome` field in the row or payload.
   Audit insertion failure rolls back the mutation, and only post-commit telemetry may report `succeeded`.
4. **Do not audit rejected requests or true no-ops as successes.**
   Keep repeated disable and revoke mutation-free with no duplicate audit row or success telemetry.
   Every successful Copy invite remains an effective mutation because it mints a fresh token and expiry.
5. **Preserve the shared Console operator model.**
   Use `actor_type = "operator"`, null `actor_id`, and `surface = "console"` until Orchard has an authenticated first-class Console operator identity.
6. **Use a strict non-secret payload allowlist.**
   Allow `surface` for every event, `expires_at` for invite issue or reissue, and the existing bounded API Key metadata plus Portal ownership provenance for key events.
   Do not persist `previous_invite_existed`; the issued or reissued action name already records that classification.

## Capabilities

### Modified Capabilities

- `developer-api-key-portal`: Defines atomic audit rows, action names, actor and target provenance, effective-transition semantics, and secret-free payloads for the existing Portal lifecycle and Portal-owned API Key operations.
- `controller-prometheus-metrics`: Adds the bounded `portal_user` audit domain and reconciles the audit-series worksheet and family ceiling.

## Impact

- `SPEC.md` impact: sections 7.4a, 9.1, and 10.9 now state the accepted atomic lifecycle, bounded payload, no-op, lock-order, and metrics contracts.
- Product behavior impact: repeated disable and revoke are true no-ops, and Portal key mint and revoke reject a session whose captured epoch no longer matches the locked Portal User.
- Persistence impact: every effective Portal lifecycle and Portal-owned key mutation now commits one append-only audit row atomically without a schema change.
- Governance impact: Portal User creation, invite issue and reissue, redemption, disablement, and Portal-owned key mint and revoke have mandatory atomic audit evidence.
- Concurrency impact: invite issuance classification, token generation, and expiry calculation occur under the existing Portal User lock, while key mutation authority is revalidated with the lock order Portal User then API Key.
- Metrics impact: the bounded audit action vocabulary grows to include `portal_user`, for 36 audit series and a 2,600-series accepted Portal lifecycle floor.
  The separately accepted issue #121 attempt and retry families add 229 runtime series, producing a 2,829-series runtime worksheet and 2,171 series of headroom.
- Documentation impact: the apex contract, accepted capability specs, this active package, and the operator journey are reconciled.

## Non-Goals

- Do not reintroduce `invalidated_at`, retained invite invalidation history, or another invite-state column.
- Do not define active-user recovery, replacement invites, Portal User re-enablement, or Portal User deletion.
- Do not change the canonical `POST /portal/:organization_slug/invites/:token` redemption route.
- Do not change invited-only, Organization-bound redemption or generic mutation-free failure behavior.
- Do not revoke API Keys automatically when a Portal User is disabled or an invite is issued, reissued, or redeemed.
- Do not design Console key labels or another Console management surface.
- Do not persist `previous_invite_existed`, invite tokens, invite hashes, invite URLs, passwords, password hashes, session tokens, session hashes, API Key secrets, or API Key secret hashes in audit evidence.
- Do not close issue #279.
- Keep issue #270 independent.
- Do not add an ADR or glossary term unless a future accepted change selects a broader identity or authority model than the existing `Operator`, `Portal User`, and `Audit Log` concepts.
