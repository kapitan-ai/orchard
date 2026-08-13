## Context

Orchard already has hashed show-once tenant-direct API Keys, tenant quotas, and an operator Console Organization page that can mint and revoke keys.
There is no Organization-scoped login, no portal password field, no issuance provenance, and no password hasher in `orchard_controller`.
Console auth is cluster-wide Basic Auth. Reusing that shell for a weaker session would leak operator chrome.

Origin: `docs/brainstorms/2026-08-13-self-service-api-key-portal-requirements.md`.
Implementation plan: `docs/plans/2026-08-13-001-feat-self-service-api-key-portal-plan.md`.
UI note: `docs/designs/2026-08-13-self-service-api-key-portal.md`.

## Goals

- Give a human developer a working key and one curl without operator help, when the Organization already has a callable model.
- Keep operator Console as the only cluster surface.
- Fail closed on TLS, enumeration, and secret retention.

## Non-Goals

- Named portal users, SSO, agent mint APIs, and API Client tokens from the portal remain later cuts.
- This change does not invent a second key format.

## Decision 1: Separate Portal, Shared Phoenix Session Cookie

The portal is a distinct `/portal/:organization_slug` namespace with its own layouts and `live_session`.
CSRF and LiveView still ride the existing Phoenix session cookie `_orchard_console_key` because a second cookie is invisible to LiveView `connect_info`.
Isolation is enforced above that layer: never read `_orchard_console_authenticated`, never render Console chrome.

Rejected: org-scoped slice of Console. Operator Basic Auth is cluster-wide.

## Decision 2: Shared Organization Password Plus Epoch

One operator-set password per Organization. No user table.
Password hash plus monotonic `portal_session_epoch`.
Rotate or clear increments the epoch and deletes `portal_sessions`.
It does not revoke minted keys.

Login identifies the Organization by slug first, then verifies that password.
Unknown, closed, and wrong-password cases share one generic failure and the same hasher cost through the same verifier pool.

## Decision 3: Portal-Mint Provenance And Cap

`api_keys.issuance_surface` is `governance` or `developer_portal`.
Existing keys backfill to `governance`.
The 10-key cap counts only active portal-minted tenant-direct keys.
Operator mint is exempt.
Portal revoke requires `issuance_surface = 'developer_portal'` so a leaked portal password cannot kill operator recovery keys.
The portal may list operator-minted tenant-direct keys read-only.

## Decision 4: Slow Password KDF With Packaging Gate

Prefer Argon2id via `argon2_elixir` (64 MiB, 3 iterations, parallelism 1).
That would be the first compiled NIF in `orchard_controller`.
If it cannot load in the controller release, use documented `:crypto` PBKDF2-HMAC-SHA512 before any password row exists.
Do not hash portal passwords with API-key SHA-256.

## Decision 5: TLS-Only And Per-Source Backoff

Portal routes and operator password mutations require `public_api_https_enabled?` and effective HTTPS scheme.
`plain_http_localhost` returns 404 and rejects password mutations.

Failed logins are limited per Organization fingerprint plus source fingerprint:
1-4 free, then 30s / 60s / 120s / 240s / 480s / 900s.
No Organization-wide lockout.

Sessions last 8 hours absolute and 30 minutes idle.
Auth ticks do not refresh idle.

## Decision 6: Deterministic Activation Curl

After mint, choose the first tenant-authorized active model from the exact `GET /v1/models` visibility query, sorted by public identifier then UUID.
If authorization cannot be proven, mint still succeeds and the portal states that no curl is available.
The model identifier is untrusted interpolation in the shell snippet.
