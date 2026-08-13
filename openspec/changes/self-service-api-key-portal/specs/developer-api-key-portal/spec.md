## ADDED Requirements

### Requirement: Developer Portal Is Isolated From Operator Console

Orchard SHALL expose a Developer Portal browser surface at `/portal/:organization_slug` that is distinct from Orchard Console.
The portal SHALL NOT render operator Console chrome, other Organizations, nodes, license state, or cluster administration.
Portal sessions SHALL NOT authorize Public Inference, Operator API, Admin API, or Console access.
This refines `SPEC.md` §2.3, §7.1, and §7.4a.

#### Scenario: Portal session cannot reach Console

- **WHEN** a developer holds a valid portal session cookie for one Organization
- **THEN** requests to `/console` SHALL NOT be authorized by that session
- **AND** the portal HTML SHALL NOT include Console sidebar, license badge, or `/console` navigation

#### Scenario: Portal session cannot call Operator or Admin APIs

- **WHEN** a caller presents only a Developer Portal session
- **THEN** Operator API and Admin API requests SHALL fail closed
- **AND** the failure SHALL NOT treat the portal session as a Bearer API Token

### Requirement: Organization Slug Is Identified Before Password Check

The portal SHALL identify the Organization from the route slug first, then verify that Organization's portal password.
An Organization with no portal password SHALL have no open portal.
`GET /portal/:organization_slug` SHALL be response-indistinguishable for open, closed, and unknown slugs.
Unknown slug, closed portal, and wrong password SHALL share one generic login failure.
This refines `SPEC.md` §7.4a.

#### Scenario: Closed and unknown slugs share the GET login shape

- **WHEN** an unauthenticated caller requests `GET /portal/:organization_slug` for an open Organization, a closed Organization, and an unknown slug
- **THEN** Orchard SHALL return the same status, body shape, and headers in all three cases
- **AND** the page SHALL show the slug from the URL, not the Organization name

#### Scenario: Closed portal cannot mint keys

- **WHEN** an Organization has no portal password hash
- **THEN** a password submission SHALL fail with the generic login error
- **AND** Orchard SHALL NOT create a portal session

### Requirement: Operator Sets Rotates And Clears The Portal Password

An operator SHALL set, rotate, or clear the portal password from Console Organization detail.
The password SHALL be stored only as a slow password-hash, never plaintext.
Clearing or rotating the password SHALL increment `portal_session_epoch` and end standing portal sessions for that Organization.
Password rotation and clear SHALL NOT revoke minted API Keys.
Operator password mutations SHALL be rejected when public API HTTPS is not enabled.
This refines `SPEC.md` §7.4a, §10.8, and §10.9.

#### Scenario: Rotate ends sessions and leaves keys valid

- **WHEN** an operator rotates an Organization portal password
- **THEN** existing portal sessions for that Organization SHALL fail revalidation
- **AND** previously minted API Keys SHALL remain valid Bearer credentials until explicitly revoked

#### Scenario: Degraded transport rejects password set

- **WHEN** transport mode is `plain_http_localhost`
- **THEN** Orchard SHALL reject portal password set, rotate, and clear
- **AND** Orchard SHALL NOT persist a new password hash

### Requirement: Portal Mints Tenant-Direct Keys With A Portal-Only Cap

The portal SHALL mint tenant-direct API Keys with `issuance_surface = 'developer_portal'` using the existing `orchard_sk_*` show-once contract.
An Organization MAY have at most 10 active portal-minted tenant-direct keys.
Operator-minted tenant-direct keys SHALL NOT count toward that ceiling.
Operator mint paths SHALL remain available and operator-only.
This refines `SPEC.md` §7.4a, §8, and §10.2.

#### Scenario: Eleventh active portal key is rejected

- **WHEN** an Organization already has 10 active portal-minted tenant-direct keys
- **AND** a portal session attempts to mint another key
- **THEN** Orchard SHALL reject the mint
- **AND** Orchard SHALL NOT insert a new API Key row

#### Scenario: Operator mint remains uncapped

- **WHEN** an Organization already has 10 active portal-minted tenant-direct keys
- **AND** an operator mints a tenant-direct key through Console, CLI, or Admin API
- **THEN** the operator mint SHALL succeed
- **AND** the new key SHALL have `issuance_surface = 'governance'`

### Requirement: Portal Lists Organization Keys And Revokes Only Portal-Minted Keys

The portal SHALL list tenant-direct keys for the signed-in Organization, including operator-minted keys, with name, prefix, created time, last used time, status, and lifetime persisted-inference request count.
The portal SHALL NOT list service-account-owned API Tokens.
Portal revoke SHALL require `issuance_surface = 'developer_portal'` and SHALL take effect on the next Public Inference authentication.
This refines `SPEC.md` §7.4a and §10.2.

#### Scenario: Portal cannot revoke an operator key

- **WHEN** a portal session attempts to revoke an operator-minted tenant-direct key
- **THEN** Orchard SHALL treat the key as not found
- **AND** the key SHALL remain active

#### Scenario: Portal revoke fails the next Bearer request

- **WHEN** a portal session revokes a portal-minted key
- **AND** the next Public Inference request presents that key
- **THEN** authentication SHALL fail with `401 invalid_api_key`

### Requirement: Activation Curl Uses One Deterministic Callable Model

After a successful mint, the portal SHALL show one `POST /v1/chat/completions` curl that uses a deterministic callable model already authorized for the Organization, or state that no test curl is available.
If no callable model can be proven, the key mint SHALL still succeed.
The full secret SHALL appear only at creation and SHALL NOT be recoverable later.
This refines `SPEC.md` §7.2.3, §7.2.4, and §7.4a.

#### Scenario: No callable model still mints the key

- **WHEN** a portal session mints a key for an Organization with no proven callable model
- **THEN** Orchard SHALL persist the key
- **AND** the portal SHALL state that no test curl is available
- **AND** the secret SHALL still be shown once

### Requirement: Portal Traffic Is TLS-Only And Login Failures Are Per-Source

The portal SHALL be served only when public API HTTPS is enabled and the effective request scheme is HTTPS.
Degraded `plain_http_localhost` SHALL return `404` for every portal route.
Failed portal logins SHALL be limited per Organization fingerprint and source fingerprint.
They SHALL NOT use an Organization-wide lockout.
This refines `SPEC.md` §7.4a and §10.7.

#### Scenario: Degraded mode hides the portal

- **WHEN** transport mode is `plain_http_localhost`
- **THEN** every `/portal/:organization_slug` route SHALL return `404`
- **AND** Orchard SHALL NOT set a portal session

#### Scenario: One source cannot lock the whole Organization

- **WHEN** one client source exceeds the failed-login backoff for an Organization
- **THEN** a different source MAY still attempt login for that Organization
- **AND** the throttled source SHALL receive a retryable failure distinct from the generic credential error
