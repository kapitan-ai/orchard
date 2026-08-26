## MODIFIED Requirements

### Requirement: Copy Invite Reissues A Hash-Only Token

Console SHALL provide Copy invite for a Portal User in `invited` status.
Each Copy invite action SHALL mint a fresh single-use token, extend expiry from reissue, invalidate all prior unused tokens for that Portal User, and persist only the new token hash.
Orchard SHALL NOT persist the plaintext token or invite URL.
The operator SHALL deliver the URL out of band without an SMTP dependency.
Invite redemption SHALL be bound to the Organization identified by the route and SHALL activate only a Portal User who is currently `invited` in that Organization.
Wrong-Organization, disabled-user, invalidated, expired, redeemed, and unknown-token redemption failures SHALL use one generic external response and SHALL make no persisted mutation.
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

#### Scenario: Disable invalidates an outstanding invite

- **WHEN** an operator disables an invited Portal User with an outstanding invite
- **THEN** the Portal User SHALL remain disabled
- **AND** the outstanding invite SHALL be invalid when disablement commits

#### Scenario: Wrong Organization does not consume an invite

- **WHEN** a caller submits one Organization's valid invite through another Organization's route
- **THEN** Orchard SHALL return the generic invalid-invite response
- **AND** the invite SHALL remain redeemable through its owning Organization's route

#### Scenario: Ineligible redemption is generic and mutation-free

- **WHEN** a caller submits an invite for a disabled Portal User, an invalidated invite, an expired invite, a redeemed invite, or an unknown token
- **THEN** every submission SHALL receive the same generic invalid-invite response contract
- **AND** Orchard SHALL NOT persist a mutation

### Requirement: Portal Sessions Belong To One Portal User

Every Developer Portal session SHALL belong to one `portal_user_id` and that Portal User's Organization.
Invite reissue, invite redemption, and Portal User disablement SHALL end that Portal User's standing sessions.
Portal User disablement SHALL invalidate every outstanding invite in the same transaction that changes the user's status and ends the user's sessions.
Disabling a Portal User SHALL NOT automatically revoke owned API Keys.
This refines `SPEC.md` §7.4a and §8.

#### Scenario: Disable ends sessions without revoking keys

- **WHEN** an operator disables one Portal User who has a standing session and active owned keys
- **THEN** only that Portal User's sessions SHALL fail revalidation
- **AND** other Portal Users' sessions SHALL remain valid
- **AND** the disabled Portal User's keys SHALL remain valid Bearer credentials until explicitly revoked

#### Scenario: Disable an invited Portal User

- **WHEN** an operator disables an invited Portal User with an outstanding invite
- **THEN** the Portal User SHALL remain disabled
- **AND** every outstanding invite for that Portal User SHALL be invalid immediately when disablement commits

### Requirement: Portal List And Revoke Are Own-Keys-Only

The portal SHALL list and revoke only keys whose `portal_user_id` and `tenant_id` match the signed-in Portal User and Organization.
Keys owned by another Portal User, keys owned by another Organization, operator-minted keys, and missing keys SHALL be indistinguishable on portal list and revoke paths.
Portal revoke SHALL take effect on the next Public Inference authentication.
This refines `SPEC.md` §7.4a and §10.2.

#### Scenario: Portal Users cannot see each other's keys

- **WHEN** two Portal Users belong to the same Organization and each owns portal-minted keys
- **THEN** each Portal User SHALL list only their own keys
- **AND** neither Portal User SHALL learn the other Portal User's key names, prefixes, or status

#### Scenario: Inconsistent cross-Organization key ownership is excluded

- **WHEN** a portal-minted key records the signed-in `portal_user_id` but a different `tenant_id`
- **THEN** the key SHALL be absent from the Portal User's list
- **AND** the Portal User SHALL NOT learn the key's name, prefix, or status

#### Scenario: Portal User cannot revoke another user's key

- **WHEN** a Portal User attempts to revoke a key owned by another Portal User
- **THEN** Orchard SHALL treat the key as not found
- **AND** the other Portal User's key SHALL remain active

#### Scenario: Own-key revoke fails the next Bearer request

- **WHEN** a Portal User revokes their own portal-minted key
- **AND** the next Public Inference request presents that key
- **THEN** authentication SHALL fail with `401 invalid_api_key`
