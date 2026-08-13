## 1. Contract

- [x] 1.1 Update `SPEC.md` §2.3, §7.1, §7.4a, §8, §10.2, §10.8, and §10.9 for the Developer Portal.
- [x] 1.2 Add this OpenSpec proposal, design, tasks, and requirement delta.
- [x] 1.3 Validate the change with strict OpenSpec.

## 2. Persistence And Password Lifecycle

- [ ] 2.1 Prove Argon2id loads in the controller environment or switch to documented PBKDF2-HMAC-SHA512 before any password row exists.
- [ ] 2.2 Add additive migration for tenant portal fields, `issuance_surface`, `portal_sessions`, `portal_login_throttles`, and `requests.api_key_id` index if missing.
- [ ] 2.3 Add `lock_tenant/1` and portal password set/rotate/clear with epoch increment, session deletion, TLS rejection, and redacted audit.
- [ ] 2.4 Add focused password and governance tests from the implementation plan Unit 2 scenarios.

## 3. Sessions And Throttle

- [ ] 3.1 Add portal session create/validate/logout and per-source throttle reservation.
- [ ] 3.2 Add the bounded verifier pool and dummy-verify path with the same hasher cost.
- [ ] 3.3 Store the opaque portal token in the Phoenix session so LiveView mount can revalidate.
- [ ] 3.4 Add session, throttle, and verifier tests from the implementation plan Unit 3 scenarios.

## 4. Portal Keys And Activation Curl

- [ ] 4.1 Add `create_portal_api_key/3` with tenant lock and portal-only cap of 10.
- [ ] 4.2 Add `list_portal_api_keys/1` with grouped persisted-inference request counts.
- [ ] 4.3 Add `revoke_portal_api_key/3` limited to `issuance_surface = 'developer_portal'`.
- [ ] 4.4 Add deterministic activation-curl construction with untrusted model-identifier quoting.
- [ ] 4.5 Add governance, curl, and Bearer integration tests from the implementation plan Unit 4 scenarios.

## 5. Isolated Portal Surface

- [ ] 5.1 Register TLS-guarded `/portal/:organization_slug` routes with CSRF, secure headers, and no Console auth marker.
- [ ] 5.2 Add indistinguishable GET login for open, closed, and unknown slugs.
- [ ] 5.3 Add `OrchardPortal.KeysLive` with show-once secret, dark-pinned layouts, and chrome-absence tests.
- [ ] 5.4 Follow `docs/designs/2026-08-13-self-service-api-key-portal.md` except slug-in-URL login.

## 6. Operator Surface And Docs

- [ ] 6.1 Add the Developer Portal card to Organization detail: set, rotate, clear, HTTPS URL, active portal-key count.
- [ ] 6.2 Document the containment runbook in `docs/operator-journey.md`.
- [ ] 6.3 Add a narrow portal-surface section to `docs/DESIGN.md`.
- [ ] 6.4 Run the Elixir quality workflow for the changed surface.
