## Context

PR #284 reconciled the apex Portal contract with shipped delete-based invite invalidation, Organization-bound invited-only redemption, and the canonical POST route.
PR #291 later synchronized the accepted Developer Portal capability and removed the prior password-replacement claim.
The remaining live ambiguity is the boundary between creating a Portal User and issuing the first Portal Invite.
The original 2026-08-14 OpenSpec package still records earlier password-replacement and invalidation-state intent, but it is an archived historical artifact rather than current product truth.

## Decisions

### Portal User Creation And Portal Invite Issuance Stay Separate

The **Invite** form creates a Portal User in `invited` status.
It does not mint or store a Portal Invite token and does not return or display a Portal Invite URL.
The first **Copy invite** action issues the initial Portal Invite.
Each later **Copy invite** action uses the same issuance path to replace the prior unused invite.

### Deletion Is The Only Invite Invalidation Record

Each Copy invite action deletes any prior invite row before storing one replacement hash-only row.
Portal User disablement deletes every outstanding unused invite row in the same transaction as the status and session changes.
Orchard retains no invite invalidation tombstone, revocation record, or separate invite-state column.
Redeemed state remains the `redeemed_at` value on the single stored invite row and does not authorize active-user recovery.

### Every Copy Invite Action Ends Standing Sessions

`copy_invite_transaction/4` deletes the Portal User's sessions on every Copy invite action, including the initial issuance.
The accepted session-termination sentence previously named only invite reissue, which under-named the shipped behavior once the first Copy invite became the initial issuance path.
The reconciled sentence names initial invite issuance alongside reissue, redemption, and disablement.
This is a naming correction to already-shipped behavior and requires no product code, migration, or test change.

### The Canonical Redemption Route Remains The Shipped Route

Invite redemption uses `POST /portal/:organization_slug/invites/:token`.
The route Organization and the Portal User's current `invited` status are rechecked before mutation.
This reconciliation introduces no compatibility route and no route-independent redemption seam.

### Historical OpenSpec Packages Are Not Rewritten

The archived 2026-08-14 package remains unchanged because it records the intent reviewed at that time.
Current truth comes from `SPEC.md`, the accepted capability spec, the later PR #284 archive, and shipped behavior.
This package records the present reconciliation without attributing later decisions to the earlier package's reviewers.

### Owner-Gated Future Slices Remain Undefined

Active-user recovery, audit vocabulary, and neutral key-attribution labels require separate owner decisions.
This change records them only as non-goals and does not create requirements, scenarios, labels, or implementation tasks for them.
Issue #270 remains independent.

## Alternatives Rejected

- Updating `SPEC.md` was rejected because the apex contract is already complete and correct.
- Rewriting the archived 2026-08-14 package was rejected because it would obscure the decision chronology.
- Adding `invalidated_at`, retained history, or a separate invite-state column was rejected because it conflicts with the current apex contract.
- Treating **Copy invite** as active-user recovery was rejected because current redemption is invited-only and recovery semantics remain owner-gated.
- Defining audit vocabulary or key-attribution labels was rejected because no authoritative decision currently fixes those contracts.

## Validation And Archive Plan

The active change is validated strictly before archive.
The accepted capability spec is synchronized directly because this package reconciles behavior that is already accepted and shipped.
After review, archive this package with `--skip-specs` so the synchronized accepted spec is not applied twice.
Then validate all active changes and accepted specs strictly and inspect the accepted capability for placeholder prose.
