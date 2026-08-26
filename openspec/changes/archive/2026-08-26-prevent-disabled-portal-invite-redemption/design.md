## Context

Portal Invite reissue already invalidates an unused invite by deleting its hash-only row.
Portal User disablement and redemption currently use separate transactions without one shared lock order.
The database already contains every field needed to enforce the accepted lifecycle, so no schema change is required.

## Decision

Portal User invite mutations SHALL serialize on the Portal User row before touching invite or session rows.
Disablement SHALL lock the current tenant-scoped Portal User, change the status, delete outstanding invite rows, and delete only that user's sessions in one transaction.
Redemption SHALL use the token hash only to discover a candidate, then lock and recheck the current Portal User's invited status and Organization before locking and consuming the invite.
Copy invite SHALL lock and recheck the current Portal User before replacing an unused invite.

The public redemption facade SHALL require the normalized route Organization slug.
The old route-independent arity SHALL not remain as a bypass.
Every invite eligibility failure SHALL roll back as the same `invalid_invite` result consumed by the existing generic endpoint response.

Portal-owned key listing SHALL use the authenticated Tenant and Portal User returned by session validation and require both identifiers in the query.
API-key authentication and revocation semantics SHALL remain unchanged.

## Alternatives Rejected

Adding an `invalidated_at` column is unnecessary because existing reissue semantics already use deletion and the issue requires no durable invite-revocation history.
Revoking API Keys on disablement would violate the accepted Portal User provenance and tenant-Bearer contract.
A presentation-layer check would leave the public governance boundary bypassable.

## Risks

Inconsistent lock ordering could create deadlocks or allow a concurrent reissue after disablement.
All reissue, redemption, and disablement paths therefore lock the Portal User first.
A candidate token lookup can become stale, so every eligibility condition is rechecked under the transaction lock before mutation.
