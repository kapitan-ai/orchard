## Why

App developers who call Orchard's Public Inference API need long-lived Bearer keys without asking a cluster operator for every key.
A shared Organization portal password gives every password holder access to one Organization-wide key pool.
That model cannot isolate one developer's keys from another developer.
Orchard needs an invite-only named Portal User as the Developer Portal minting gate while keeping the Public Inference principal model unchanged.

## What Changes

- Add a TLS-only Developer Portal at `/portal/:organization_slug` with its own layouts, pipeline, and LiveView session.
- Let an operator invite a Portal User by email and copy a single-use expiring invite URL for out-of-band delivery.
- Make each Copy invite action reissue a fresh hash-only token, extend expiry, and invalidate prior unused tokens.
- Let an invited Portal User redeem the invite, set a password, and sign in with email plus password.
- Let a signed-in Portal User mint, list, and revoke only their own tenant-direct API Keys.
- Persist `portal_users`, `portal_invite_tokens`, Portal User-owned session rows, login throttle fingerprints, API key `issuance_surface`, and nullable `api_keys.portal_user_id`.
- Cap active portal-minted tenant-direct keys at 10 per Portal User.
- End a disabled Portal User's sessions without automatically revoking their keys.
- Keep legacy portal-minted keys with null `portal_user_id` valid as Bearer credentials and visible only to operators.
- Show each key secret once and then show one activation curl or state that no callable model exists.
- Keep `orchard_sk_*`, Public Inference `principal_type = tenant`, Admin and Operator authentication, and Console Basic Auth unchanged.
- Remove the shared Organization portal password as a Developer Portal login factor.

## Capabilities

### New Capabilities

- `developer-api-key-portal`: Invite-only, Organization-scoped self-service minting gate for Portal User-owned tenant-direct API Keys.

### Modified Capabilities

- None.
  No accepted OpenSpec capability currently owns a named Developer Portal identity.

## Impact

- SPEC.md impact: this change refines `SPEC.md` §2.3, §7.1, §7.4a, §8, §10.2, §10.8, and §10.9.
- Implementation impact: additive and contract migrations for Portal Users, invite tokens, Portal User-owned sessions and keys, isolated `OrchardPortal` web namespace, and Portal User controls on Console Organization detail.
- Security impact: slow password KDF, hash-only invite and session tokens, indistinguishable credential failures, per-identity-and-source login backoff, TLS-only availability, own-key authorization, and show-once secrets.
- Migration impact: the shared Organization portal password no longer authenticates any portal route, while legacy unowned portal keys remain valid until explicitly revoked.
- Non-impact: Public Inference `/v1/*`, `orchard_sk_*`, Bearer `principal_type = tenant`, Operator API, Admin API, Console Basic Auth, API Client provisioning, and Node TLS or BEAM credentials.

## Non-Goals

- No public signup, SMTP delivery, magic-link email, SSO, OAuth, or `tenant_admin` Console login.
- No Portal User authority for Console, Operator API, Admin API, or Public Inference sessions.
- No agent minting API or non-operator CLI mint.
- No API Client create, disable, or token mint from the portal.
- No quota, model-access, or Organization administration from the portal.
- No per-key rate limits.
- No change to the Public Inference key format or Bearer contract.
