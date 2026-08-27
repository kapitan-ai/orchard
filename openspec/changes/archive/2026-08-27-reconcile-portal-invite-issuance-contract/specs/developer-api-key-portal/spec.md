## RENAMED Requirements

- FROM: `### Requirement: Copy Invite Reissues A Hash-Only Token`
- TO: `### Requirement: Copy Invite Issues Or Reissues A Hash-Only Token`

## MODIFIED Requirements

### Requirement: Portal Users Are Operator-Invited Named Identities

A Portal User SHALL belong to exactly one Organization and use email as an identifier unique by normalized value within that Organization.
An operator SHALL create Portal User accounts.
Creating a Portal User SHALL persist only the Portal User in `invited` status.
Creation SHALL NOT mint or store a Portal Invite token and SHALL NOT return or display a Portal Invite URL.
The Developer Portal SHALL NOT offer public signup, self-registration, or shared Organization password authentication.
SMTP SHALL NOT be required.
This refines `SPEC.md` §7.4a and §8.

#### Scenario: Public signup is unavailable

- **WHEN** an unauthenticated caller visits any Developer Portal route
- **THEN** Orchard SHALL offer only invite redemption or email-plus-password login
- **AND** Orchard SHALL NOT create a Portal User without an operator creating that Portal User in `invited` status

#### Scenario: Portal User creation does not issue an invite token

- **WHEN** an operator creates a Portal User
- **THEN** Orchard SHALL persist the Portal User in `invited` status
- **AND** Orchard SHALL NOT create a Portal Invite row
- **AND** Console SHALL NOT return or display a Portal Invite URL

#### Scenario: Same email can identify users in different Organizations

- **WHEN** two Organizations invite the same normalized email
- **THEN** each Organization MAY have its own Portal User for that email
- **AND** each Portal User SHALL remain scoped to its own Organization

### Requirement: Copy Invite Issues Or Reissues A Hash-Only Token

Console SHALL provide Copy invite for a Portal User in `invited` status.
The first Copy invite action after Portal User creation SHALL issue the initial Portal Invite.
Each Copy invite action SHALL mint a fresh single-use token, delete any previous invite row for that Portal User, extend expiry from the action time, and persist only the new token hash.
A Portal User SHALL have at most one stored invite row at a time.
Deleting the stored row SHALL be the invite invalidation mechanism, and Orchard SHALL NOT retain invite invalidation or revocation history.
Orchard SHALL NOT persist the plaintext token or invite URL.
The operator SHALL deliver the URL out of band without an SMTP dependency.
Invite redemption SHALL be bound to the Organization identified by the route and SHALL activate only a Portal User who is currently `invited` in that Organization.
Invite redemption SHALL use the canonical `POST /portal/:organization_slug/invites/:token` route.
Wrong-Organization, disabled-user, invalidated, expired, redeemed, and unknown-token redemption failures SHALL use one generic external response and SHALL make no persisted mutation.
This refines `SPEC.md` §7.4a, §8, §10.8, and §10.9.

#### Scenario: First Copy invite issues the initial token

- **WHEN** an operator uses Copy invite for an invited Portal User with no stored invite
- **THEN** Orchard SHALL return the newly issued plaintext URL only for that Copy invite action
- **AND** durable storage SHALL contain exactly one hash-only invite row for that Portal User

#### Scenario: Recopy deletes and replaces the previous invite

- **WHEN** an operator uses Copy invite twice for the same invited Portal User
- **THEN** the second action SHALL return a newly issued plaintext URL
- **AND** Orchard SHALL extend the invite expiry
- **AND** the first unused token SHALL no longer redeem
- **AND** durable storage SHALL contain exactly one invite row with only the replacement token hash
- **AND** Orchard SHALL retain no invalidation tombstone or revocation history for the deleted row

#### Scenario: Valid invite is redeemed once

- **WHEN** an invited Portal User submits a valid unexpired invite token and a valid new password through `POST /portal/:organization_slug/invites/:token`
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
