## 1. Contract

- [x] 1.1 Update `SPEC.md` §2.3, §7.1, §7.4a, §8, §10.2, §10.8, and §10.9 for invite-only Portal Users.
- [x] 1.2 Amend this live OpenSpec proposal, design, tasks, and requirement delta instead of creating a second change.
- [x] 1.3 Validate the amended change with strict OpenSpec.

## 2. Portal User And Invite Persistence

- [ ] 2.1 Add the Portal User status enum, `portal_users`, and Organization-scoped normalized-email uniqueness.
- [ ] 2.2 Add `portal_invite_tokens` with hash-only single-use tokens, expiry, redemption, and invalidation state.
- [ ] 2.3 Add Copy invite reissue that invalidates prior unused tokens, extends expiry, and returns plaintext only in the new URL.
- [ ] 2.4 Add invite redemption and password replacement with a slow password KDF and no SMTP dependency.
- [ ] 2.5 Add focused persistence and invite lifecycle tests for expiry, single use, reissue invalidation, and absent plaintext storage.

## 3. Portal User Sessions And Login Throttle

- [ ] 3.1 Add Portal User-owned session create, validate, logout, and user-scoped session termination.
- [ ] 3.2 Add email-plus-password login with indistinguishable unknown Organization, unknown email, disabled user, and wrong-password responses.
- [ ] 3.3 Add throttle reservation by Organization fingerprint, Portal User or email fingerprint, and source fingerprint.
- [ ] 3.4 Add the bounded verifier pool and dummy-verify path with the same password-hasher cost.
- [ ] 3.5 Store only an opaque portal session token in the Phoenix session so LiveView mount can revalidate.
- [ ] 3.6 Add session, disable, replacement-invite, throttle, and verifier tests.

## 4. Portal User-Owned Keys And Activation Curl

- [ ] 4.1 Add nullable `api_keys.portal_user_id` without changing `orchard_sk_*` or Public Inference `principal_type = tenant`.
- [ ] 4.2 Add Portal User-owned mint with `issuance_surface = 'developer_portal'` and a Portal User row lock.
- [ ] 4.3 Enforce at most 10 active portal-minted keys per Portal User, excluding revoked and expired keys.
- [ ] 4.4 Add own-keys-only list and revoke queries scoped by both `portal_user_id` and `tenant_id`.
- [ ] 4.5 Keep operator-minted and legacy unowned portal keys absent from Developer Portal list and revoke paths.
- [ ] 4.6 Keep legacy unowned portal keys valid on the unchanged Bearer path and visible to operators.
- [ ] 4.7 Add deterministic activation-curl construction with untrusted model-identifier quoting and show-once secret handling.
- [ ] 4.8 Add cross-user isolation, per-user cap, legacy-key, operator-mint, revoke, and Bearer integration tests.

## 5. Isolated Developer Portal Surface

- [ ] 5.1 Register TLS-guarded invite, login, logout, and key routes with CSRF, secure headers, and no Console auth marker.
- [ ] 5.2 Add invite redemption and email-plus-password login without a shared Organization password fallback.
- [ ] 5.3 Add `OrchardPortal.KeysLive` with own-key list, show-once secret, isolated layouts, and chrome-absence tests.
- [ ] 5.4 Prove Portal User sessions cannot authorize Console, Operator API, Admin API, or Public Inference.
- [ ] 5.5 Prove `plain_http_localhost` returns `404` for every Developer Portal route.

## 6. Operator Surface And Adjacent Docs

- [ ] 6.1 Add Portal User invite, Copy invite, disable, and owned-key visibility to Console Organization detail.
- [ ] 6.2 Ensure disable ends only that Portal User's sessions and does not revoke owned keys.
- [ ] 6.3 Update `docs/operator-journey.md` in its separately reviewed unit.
- [ ] 6.4 Update `docs/DESIGN.md` in its separately reviewed unit.
- [ ] 6.5 Run the Elixir quality workflow for the implementation changes.
