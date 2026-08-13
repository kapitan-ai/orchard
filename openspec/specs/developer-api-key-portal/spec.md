# developer-api-key-portal Specification

## Purpose
Define Orchard's invite-only Developer Portal for named Portal Users who manage only their own tenant-direct API Keys.
These requirements cover identity and invite lifecycle, isolated authentication, user-owned sessions and keys, login throttling, activation guidance, legacy key compatibility, and TLS-only access.

## Requirements
### Requirement: Developer Portal Is Isolated From Every Platform Authority

Orchard SHALL expose a Developer Portal browser surface at `/portal/:organization_slug` that is distinct from Orchard Console.
The portal SHALL NOT render operator Console chrome, other Organizations, nodes, license state, or cluster administration.
A Portal User SHALL authorize only the Developer Portal for that Portal User's Organization.
A Portal User session SHALL NOT authorize Public Inference, Operator API, Admin API, or Console access.
This refines `SPEC.md` §2.3, §7.1, and §7.4a.

#### Scenario: Portal User cannot authorize Console

- **WHEN** a caller presents only a valid Portal User session
- **THEN** requests to Console SHALL NOT be authorized by that session
- **AND** the portal HTML SHALL NOT include Console navigation or operator chrome

#### Scenario: Portal User cannot authorize Operator or Admin APIs

- **WHEN** a caller presents only a valid Portal User session to the Operator API or Admin API
- **THEN** Orchard SHALL fail closed
- **AND** Orchard SHALL NOT treat the session as Operator, Admin, Tenant Admin, or Bearer authority

#### Scenario: Portal User session is not Public Inference authority

- **WHEN** a caller presents a Portal User session without an `orchard_sk_*` Bearer credential to Public Inference
- **THEN** Public Inference authentication SHALL fail
- **AND** Orchard SHALL NOT treat `portal_user_id` as a Public Inference principal

### Requirement: Portal Users Are Operator-Invited Named Identities

A Portal User SHALL belong to exactly one Organization and use email as an identifier unique by normalized value within that Organization.
An operator SHALL create Portal User accounts.
The Developer Portal SHALL NOT offer public signup, self-registration, or shared Organization password authentication.
SMTP SHALL NOT be required.
This refines `SPEC.md` §7.4a and §8.

#### Scenario: Public signup is unavailable

- **WHEN** an unauthenticated caller visits any Developer Portal route
- **THEN** Orchard SHALL offer only invite redemption or email-plus-password login
- **AND** Orchard SHALL NOT create a Portal User without an operator-created invitation

#### Scenario: Same email can identify users in different Organizations

- **WHEN** two Organizations invite the same normalized email
- **THEN** each Organization MAY have its own Portal User for that email
- **AND** each Portal User SHALL remain scoped to its own Organization

### Requirement: Copy Invite Reissues A Hash-Only Token

Console SHALL provide Copy invite for a Portal User in `invited` status.
Each Copy invite action SHALL mint a fresh single-use token, extend expiry from reissue, invalidate all prior unused tokens for that Portal User, and persist only the new token hash.
Orchard SHALL NOT persist the plaintext token or invite URL.
The operator SHALL deliver the URL out of band without an SMTP dependency.
This refines `SPEC.md` §7.4a, §8, §10.8, and §10.9.

#### Scenario: Recopy invalidates the previous invite

- **WHEN** an operator uses Copy invite twice for the same invited Portal User
- **THEN** the second action SHALL return a newly issued plaintext URL
- **AND** Orchard SHALL extend the invite expiry
- **AND** the first unused token SHALL no longer redeem
- **AND** durable storage SHALL contain only token hashes

#### Scenario: Valid invite is redeemed once

- **WHEN** an invited Portal User submits a valid unexpired invite token and a valid new password
- **THEN** Orchard SHALL store only the password hash
- **AND** Orchard SHALL mark the invite redeemed and activate the Portal User
- **AND** Orchard SHALL create no session from a second redemption attempt with the same token

### Requirement: Named Login Failures Are Indistinguishable

The Developer Portal SHALL authenticate an active Portal User with Organization slug, normalized email, and password.
Unknown Organization, unknown email, disabled Portal User, and wrong password SHALL produce indistinguishable status, body shape, headers, and generic credential failure.
`GET /portal/:organization_slug` SHALL be response-indistinguishable for Organizations with invited users, Organizations with active users, Organizations with no users, and unknown slugs.
Failed login limits SHALL be keyed by Organization fingerprint, Portal User or email fingerprint, and source fingerprint without an Organization-wide lockout.
This refines `SPEC.md` §7.4a.

#### Scenario: Credential failures share one response contract

- **WHEN** callers submit an unknown Organization, unknown email, disabled Portal User, and wrong password
- **THEN** every submission SHALL receive the same credential-failure status, body shape, and headers
- **AND** Orchard SHALL perform a bounded password-verification path without disclosing which identity exists

#### Scenario: One identity and source cannot lock the Organization

- **WHEN** one source exceeds failed-login backoff for one Portal User or email fingerprint
- **THEN** another Portal User or source MAY still attempt login for the Organization
- **AND** Orchard SHALL NOT create an Organization-wide lockout

### Requirement: Portal Sessions Belong To One Portal User

Every Developer Portal session SHALL belong to one `portal_user_id` and that Portal User's Organization.
Invite reissue, invite redemption, password replacement, and Portal User disablement SHALL end that Portal User's standing sessions.
Disabling a Portal User SHALL NOT automatically revoke owned API Keys.
This refines `SPEC.md` §7.4a and §8.

#### Scenario: Disable ends sessions without revoking keys

- **WHEN** an operator disables an active Portal User who has a standing session and active owned keys
- **THEN** that Portal User's session SHALL fail revalidation
- **AND** other Portal Users' sessions SHALL remain valid
- **AND** the disabled Portal User's keys SHALL remain valid Bearer credentials until explicitly revoked

### Requirement: Portal Mints Tenant-Direct Keys Owned By The Portal User

The portal SHALL mint tenant-direct API Keys with `issuance_surface = 'developer_portal'`, the signed-in `portal_user_id`, and the existing `orchard_sk_*` show-once contract.
`portal_user_id` SHALL be minting-gate provenance only.
Public Inference SHALL continue to resolve the key as `principal_type = tenant` without consulting `portal_user_id`.
Operator mint paths SHALL remain uncapped and operator-only.
This refines `SPEC.md` §7.4a, §8, and §10.2.

#### Scenario: Portal mint preserves tenant Bearer principal

- **WHEN** a Portal User mints a key and presents it as an `orchard_sk_*` Bearer credential
- **THEN** Public Inference SHALL authenticate the key as `principal_type = tenant`
- **AND** Public Inference SHALL NOT authorize from the Portal User session or `portal_user_id`

#### Scenario: Operator mint remains operator-only

- **WHEN** an operator mints a tenant-direct key through Console, CLI, or Admin API
- **THEN** the mint SHALL remain available without the Portal User cap
- **AND** a Portal User SHALL NOT gain access to that operator mint path or key

### Requirement: Active Key Cap Is Ten Per Portal User

Each Portal User SHALL NOT have more than 10 active portal-minted tenant-direct keys.
Revoked and expired keys SHALL NOT count toward the ceiling.
The mint operation SHALL serialize cap enforcement on the Portal User rather than the Organization.
This refines `SPEC.md` §7.4a and §10.2.

#### Scenario: Eleventh active key for one Portal User is rejected

- **WHEN** one Portal User already owns 10 active portal-minted keys
- **AND** that Portal User attempts to mint another key
- **THEN** Orchard SHALL reject the mint
- **AND** Orchard SHALL NOT insert a new API Key row

#### Scenario: One user's cap does not consume another user's allowance

- **WHEN** one Portal User owns 10 active portal-minted keys
- **AND** another Portal User in the same Organization has fewer than 10 active portal-minted keys
- **THEN** the second Portal User MAY mint another owned key

### Requirement: Portal List And Revoke Are Own-Keys-Only

The portal SHALL list and revoke only keys whose `portal_user_id` and `tenant_id` match the signed-in Portal User and Organization.
Keys owned by another Portal User, operator-minted keys, and missing keys SHALL be indistinguishable on portal list and revoke paths.
Portal revoke SHALL take effect on the next Public Inference authentication.
This refines `SPEC.md` §7.4a and §10.2.

#### Scenario: Portal Users cannot see each other's keys

- **WHEN** two Portal Users belong to the same Organization and each owns portal-minted keys
- **THEN** each Portal User SHALL list only their own keys
- **AND** neither Portal User SHALL learn the other Portal User's key names, prefixes, or status

#### Scenario: Portal User cannot revoke another user's key

- **WHEN** a Portal User attempts to revoke a key owned by another Portal User
- **THEN** Orchard SHALL treat the key as not found
- **AND** the other Portal User's key SHALL remain active

#### Scenario: Own-key revoke fails the next Bearer request

- **WHEN** a Portal User revokes their own portal-minted key
- **AND** the next Public Inference request presents that key
- **THEN** authentication SHALL fail with `401 invalid_api_key`

### Requirement: Legacy Unowned Portal Keys Remain Operator-Visible Bearers

Portal-minted keys with null `portal_user_id` SHALL remain valid `orchard_sk_*` Bearer credentials until explicitly revoked.
Legacy unowned portal keys SHALL remain visible only to operators and SHALL NOT be claimable, listed, or revoked by a Portal User.
The portal SHALL NOT mint a new unowned key.
This refines `SPEC.md` §7.4a, §8, and §10.2.

#### Scenario: Legacy unowned key remains valid but absent from portal

- **WHEN** an existing portal-minted key has null `portal_user_id`
- **THEN** Public Inference SHALL continue to accept it as a tenant Bearer credential until explicit revocation
- **AND** operators SHALL be able to inspect and revoke it
- **AND** every Portal User SHALL be unable to list, claim, or revoke it

### Requirement: Activation Curl Uses One Deterministic Callable Model

After a successful mint, the portal SHALL show one `POST /v1/chat/completions` curl that uses a deterministic callable model already authorized for the Organization, or state that no test curl is available.
If no callable model can be proven, the key mint SHALL still succeed.
The full secret SHALL appear only at creation and SHALL NOT be recoverable later.
This refines `SPEC.md` §7.2.3, §7.2.4, and §7.4a.

#### Scenario: No callable model still mints the key

- **WHEN** a Portal User mints a key for an Organization with no proven callable model
- **THEN** Orchard SHALL persist the key
- **AND** the portal SHALL state that no test curl is available
- **AND** the secret SHALL still be shown once

### Requirement: Portal Traffic Is TLS-Only

The portal SHALL be served only when public API HTTPS is enabled and the effective request scheme is HTTPS.
Degraded `plain_http_localhost` SHALL return `404` for every portal route.
This refines `SPEC.md` §7.4a and §10.7.

#### Scenario: Degraded mode hides every portal route

- **WHEN** transport mode is `plain_http_localhost`
- **THEN** invite, login, logout, and key routes under `/portal/:organization_slug` SHALL return `404`
- **AND** Orchard SHALL NOT create a Portal User session
