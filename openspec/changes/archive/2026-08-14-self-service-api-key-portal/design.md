## Context

Orchard already has hashed show-once tenant-direct API Keys, tenant quotas, and an operator Console Organization page that can mint and revoke keys.
The first Developer Portal contract used one shared Organization password and one Organization-wide pool of portal-minted keys.
That login cannot prevent one developer from listing or revoking another developer's keys.
ADR 0020 defines Portal User as a portal-scoped minting-gate identity rather than a platform principal.

Origin: `docs/brainstorms/2026-08-13-named-developer-portal-identity-requirements.md`.
Implementation plan: `docs/plans/2026-08-13-002-feat-named-portal-user-identity-plan.md`.
Decision record: `docs/decisions/0020-portal-user-is-not-a-platform-principal.md`.

## Goals

- Give each operator-invited Portal User an isolated Developer Portal login and an own-keys-only self-service surface.
- Let an operator copy an invite URL without SMTP and without storing a plaintext invite token.
- Keep the Public Inference Bearer key and tenant-principal contracts unchanged.
- Fail closed on transport, enumeration, cross-user key access, and secret retention.
- Preserve legacy unowned portal-minted keys as operator-visible Bearer credentials until explicit revocation.

## Non-Goals

- Public signup, SMTP, magic-link email, SSO, OAuth, and Tenant Admin login remain out of scope.
- A Portal User does not authorize Console, Operator API, Admin API, or Public Inference access.
- This change does not invent a second key format or a new Public Inference principal.
- Disable does not automatically revoke API Keys.

## Decision 1: Separate Portal And Portal-Only Session

The portal is a distinct `/portal/:organization_slug` namespace with its own layouts and `live_session`.
CSRF and LiveView may use the existing Phoenix cookie transport, but Portal User authentication state is a separate opaque hash-backed session.
Portal code never reads Console authentication as Portal User authority and never renders Console chrome.
A valid Portal User session authorizes only Developer Portal routes for that session's Portal User and Organization.

Rejected: an Organization-scoped slice of Console.
Operator Basic Auth is cluster-wide.
Rejected: allowing a Portal User session to authorize Console, Operator API, Admin API, or Public Inference.

## Decision 2: Invite-Only Named Portal User

A Portal User belongs to one Organization and is identified by email unique on `(tenant_id, normalized_email)`.
Accounts are created only by an operator.
There is no public signup and no shared Organization portal password fallback.
An active Portal User signs in with email plus password.
Unknown Organization, unknown email, disabled Portal User, and wrong password use the same generic response shape and the same password-verification cost.

`portal_users` stores Organization ownership, original and normalized email, password hash, status, session epoch, disable timestamp, and timestamps.
A Portal User password uses a slow password KDF and never API key SHA-256.

## Decision 3: Hash-Only Invite Reissue

`portal_invite_tokens` belongs to one Portal User and stores only a token hash, expiry, redemption or invalidation state, and timestamps.
The plaintext token exists only in the newly generated Copy invite URL.
Orchard never stores the plaintext token or URL in Postgres, logs, audit payloads, or support artifacts.

Each Copy invite action mints a fresh token, invalidates every prior unused token for that Portal User, and extends expiry from the reissue time.
The operator delivers the copied URL out of band.
Redeeming a valid unexpired token sets the Portal User password, marks the token redeemed, activates the Portal User, and ends that Portal User's existing sessions.
Password reset uses the same invite reissue and redemption flow.
SMTP and magic-link email are not required.

## Decision 4: Portal User-Owned Sessions And Disable

Each `portal_sessions` row belongs to one `portal_user_id` and one `tenant_id` and stores only an opaque token hash.
Session validation checks that the Portal User is active, belongs to the route Organization, and has the current session epoch.
Invite reissue, invite redemption, password replacement, and disable end only that Portal User's sessions.
Disable does not revoke owned API Keys.
The operator can inspect and deliberately revoke those keys through Console.

Sessions last 8 hours absolute and 30 minutes idle.
Auth ticks do not refresh idle.

## Decision 5: Own-Key Provenance And Per-User Cap

`api_keys.portal_user_id` is nullable minting-gate provenance.
Every new Developer Portal mint stores `issuance_surface = 'developer_portal'` and the signed-in Portal User's ID.
The portal list and revoke queries require both the signed-in `portal_user_id` and its `tenant_id`.
A key owned by another Portal User, an operator-minted key, and a missing key have the same portal-facing not-found behavior.

The cap is 10 active portal-minted tenant-direct keys per Portal User.
Revoked and expired keys do not count.
The mint transaction locks the Portal User row before counting and inserting.
Operator mint remains uncapped and operator-only.

Public Inference authentication continues to accept `orchard_sk_*` and resolve the API Key to `principal_type = tenant`.
It does not consult `portal_user_id`.
A Portal User is not an API Key principal.

Legacy Developer Portal keys with null `portal_user_id` remain valid Bearer credentials until explicitly revoked.
They remain visible only to operators, cannot be claimed, and cannot be listed or revoked by a Portal User.
No new Developer Portal mint may create an unowned key.

## Decision 6: TLS-Only And Per-Identity Backoff

Portal routes require `public_api_https_enabled?` and an effective HTTPS request scheme.
`plain_http_localhost` returns `404` for every portal route.

Failed logins are limited per Organization fingerprint, Portal User or normalized-email fingerprint, and source fingerprint.
This prevents one source from causing an Organization-wide lockout.
Unknown email uses a derived email fingerprint so the throttle does not disclose whether a Portal User exists.

## Decision 7: Show-Once Key And Deterministic Activation Curl

After mint, the portal chooses the first tenant-authorized active model from the exact `GET /v1/models` visibility query, sorted by public identifier then UUID.
If authorization cannot be proven, mint still succeeds and the portal states that no curl is available.
The key secret appears only at creation and is never recoverable later.
The model identifier is untrusted interpolation in the shell snippet.
