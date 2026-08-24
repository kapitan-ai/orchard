## Why

Disabling an invited Portal User currently leaves the outstanding invite redeemable.
The public redemption path can then reactivate the disabled identity because it does not require the route Organization or the user's current invited status.
The adjacent Portal User key-list query also relies on data consistency instead of enforcing the authenticated Organization boundary.

## What Changes

- Invalidate outstanding Portal Invites atomically with Portal User disablement.
- Bind redemption to the Organization in the route and a currently invited Portal User.
- Return one generic mutation-free response for every ineligible invite redemption.
- Require both authenticated `portal_user_id` and `tenant_id` when listing portal-owned API Keys.
- Preserve target-only session termination and existing API Keys after disablement.

## Capabilities

### Modified Capabilities

- `developer-api-key-portal`: Restores the accepted Organization-scoped invite, disablement, and own-key listing boundaries.

## Impact

- SPEC.md impact: clarifies the existing §7.4a invite lifecycle and §10.2 ownership boundaries without adding Portal User authority.
- Implementation impact: focused governance transaction, public redemption facade, controller call, and regression-test changes.
- Security impact: closes disable-then-reactivate and cross-Organization listing paths while keeping failures generic and secrets transient.
- Migration impact: none.
- Non-impact: API-key revocation, TTLs, session duration, Console layout, CLI and API management surfaces, packaging, and licensing remain unchanged.
