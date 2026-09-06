# developer-api-key-portal Specification

## Purpose
Define Orchard's invite-only Developer Portal for named Portal Users who manage only their own tenant-direct API Keys.
These requirements cover identity and invite lifecycle, isolated authentication, user-owned sessions and keys, login throttling, activation guidance, legacy key compatibility, and TLS-only access.

## Requirements
### Requirement: Developer Portal Is Isolated From Every Platform Authority

Orchard SHALL expose a Developer Portal browser surface at `/portal/:organization_slug` that is distinct from Orchard Console.
The portal SHALL NOT render operator Console chrome, other Workspaces, nodes, or cluster administration.
A Portal User SHALL authorize only the Developer Portal for that Portal User's Workspace.
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

A Portal User SHALL belong to exactly one Workspace and use email as an identifier unique by normalized value within that Workspace.
An operator SHALL create Portal User accounts.
Creating a Portal User SHALL persist only the Portal User in `invited` status.
Creation SHALL NOT mint or store a Portal Invite token and SHALL NOT return or display a Portal Invite URL.
The Developer Portal SHALL NOT offer public signup, self-registration, or shared Workspace password authentication.
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

#### Scenario: Same email can identify users in different Workspaces

- **WHEN** two Workspaces invite the same normalized email
- **THEN** each Workspace MAY have its own Portal User for that email
- **AND** each Portal User SHALL remain scoped to its own Workspace

### Requirement: Copy Invite Issues Or Reissues A Hash-Only Token

Console SHALL provide Copy invite for a Portal User in `invited` status.
The first Copy invite action after Portal User creation SHALL issue the initial Portal Invite.
Each Copy invite action SHALL mint a fresh single-use token, delete any previous invite row for that Portal User, extend expiry from the action time, and persist only the new token hash.
A Portal User SHALL have at most one stored invite row at a time.
Deleting the stored row SHALL be the invite invalidation mechanism, and Orchard SHALL NOT retain invite invalidation or revocation history.
Orchard SHALL NOT persist the plaintext token or invite URL.
The operator SHALL deliver the URL out of band without an SMTP dependency.
Invite redemption SHALL be bound to the Workspace identified by the route and SHALL activate only a Portal User who is currently `invited` in that Workspace.
Invite redemption SHALL use the canonical `POST /portal/:organization_slug/invites/:token` route.
Wrong-Workspace, disabled-user, invalidated, expired, redeemed, and unknown-token redemption failures SHALL use one generic external response and SHALL make no persisted mutation.
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

#### Scenario: Wrong Workspace does not consume an invite

- **WHEN** a caller submits one Workspace's valid invite through another Workspace's route
- **THEN** Orchard SHALL return the generic invalid-invite response
- **AND** the invite SHALL remain redeemable through its owning Workspace's route

#### Scenario: Ineligible redemption is generic and mutation-free

- **WHEN** a caller submits an invite for a disabled Portal User, an invalidated invite, an expired invite, a redeemed invite, or an unknown token
- **THEN** every submission SHALL receive the same generic invalid-invite response contract
- **AND** Orchard SHALL NOT persist a mutation

### Requirement: Named Login Failures Are Indistinguishable

The Developer Portal SHALL authenticate an active Portal User with Workspace slug, normalized email, and password.
Unknown Workspace, unknown email, disabled Portal User, and wrong password SHALL produce indistinguishable status, body shape, headers, and generic credential failure.
`GET /portal/:organization_slug` SHALL be response-indistinguishable for Workspaces with invited users, Workspaces with active users, Workspaces with no users, and unknown slugs.
Failed login limits SHALL be keyed by Workspace fingerprint, Portal User or email fingerprint, and source fingerprint without a Workspace-wide lockout.
This refines `SPEC.md` §7.4a.

#### Scenario: Credential failures share one response contract

- **WHEN** callers submit an unknown Workspace, unknown email, disabled Portal User, and wrong password
- **THEN** every submission SHALL receive the same credential-failure status, body shape, and headers
- **AND** Orchard SHALL perform a bounded password-verification path without disclosing which identity exists

#### Scenario: One identity and source cannot lock the Workspace

- **WHEN** one source exceeds failed-login backoff for one Portal User or email fingerprint
- **THEN** another Portal User or source MAY still attempt login for the Workspace
- **AND** Orchard SHALL NOT create a Workspace-wide lockout

### Requirement: Portal Sessions Belong To One Portal User

Every Developer Portal session SHALL belong to one `portal_user_id` and that Portal User's Workspace.
Initial invite issuance, invite reissue, invite redemption, and Portal User disablement SHALL end that Portal User's standing sessions.
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
The mint operation SHALL serialize cap enforcement on the Portal User rather than the Workspace.
This refines `SPEC.md` §7.4a and §10.2.

#### Scenario: Eleventh active key for one Portal User is rejected

- **WHEN** one Portal User already owns 10 active portal-minted keys
- **AND** that Portal User attempts to mint another key
- **THEN** Orchard SHALL reject the mint
- **AND** Orchard SHALL NOT insert a new API Key row

#### Scenario: One user's cap does not consume another user's allowance

- **WHEN** one Portal User owns 10 active portal-minted keys
- **AND** another Portal User in the same Workspace has fewer than 10 active portal-minted keys
- **THEN** the second Portal User MAY mint another owned key

### Requirement: Portal List And Revoke Are Own-Keys-Only

The portal SHALL list and revoke only keys whose `portal_user_id` and `tenant_id` match the signed-in Portal User and Workspace.
Keys owned by another Portal User, keys owned by another Workspace, operator-minted keys, and missing keys SHALL be indistinguishable on portal list and revoke paths.
Portal revoke SHALL take effect on the next Public Inference authentication.
This refines `SPEC.md` §7.4a and §10.2.

#### Scenario: Portal Users cannot see each other's keys

- **WHEN** two Portal Users belong to the same Workspace and each owns portal-minted keys
- **THEN** each Portal User SHALL list only their own keys
- **AND** neither Portal User SHALL learn the other Portal User's key names, prefixes, or status

#### Scenario: Inconsistent cross-Workspace key ownership is excluded

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

### Requirement: Portal Lifecycle Mutations Produce Atomic Tenant Audit Evidence

Every effective Portal User lifecycle mutation SHALL commit one tenant-scoped audit row inside the same outermost `AuditWriter.transaction/1` boundary as its authoritative state changes.
`AuditWriter.transaction/1` SHALL NOT be nested inside another transaction that owns the authoritative mutation.
The row and mutation SHALL roll back together when audit insertion fails.
Portal User creation SHALL use `portal_user.invited`.
The first Copy invite action SHALL use `portal_user.invite_issued`, and a later Copy invite action that replaces an invite observed under the locked Portal User SHALL use `portal_user.invite_reissued`.
Successful invite redemption SHALL use `portal_user.invite_redeemed`.
An effective Portal User disablement SHALL use `portal_user.disabled`.
Portal-owned API Key mint and effective revoke SHALL reuse `api_key.created` and `api_key.revoked`.

Every row SHALL use the owning Workspace's `tenant_id`.
Portal User actions SHALL target `target_type = 'portal_user'` and the affected Portal User ID.
API Key actions SHALL target `target_type = 'api_key'`, the affected API Key ID, and the matching `api_key_id`.
Console actions SHALL use `actor_type = 'operator'`, a null `actor_id`, and `surface = 'console'`.
Successful redemption and Portal-owned key mutations SHALL use `actor_type = 'user'`, the Portal User ID as `actor_id`, and `surface = 'developer_portal'` as audit provenance only.
This provenance SHALL NOT make a Portal User an Operator, Public Inference principal, or other platform principal.

Audit rows SHALL represent committed effective mutations without a persisted outcome field.
A rejected request or true no-op SHALL NOT create a success audit row.
Successful audit telemetry SHALL be emitted only after the authoritative transaction commits, and a rolled-back transaction SHALL NOT emit a succeeded observation.
A direct audit insertion inside an unmanaged transaction SHALL fail before persistence.
A rolled-back savepoint SHALL NOT leave a publishable success observation.
Post-commit metric verification failure SHALL mark metrics reporting degraded without altering the committed domain result or withholding its show-once success value, and a later successful verification MAY recover that degradation.
This refines `SPEC.md` sections 7.4a, 8.2, 9.1, and 10.9.

#### Scenario: Creation and first issuance remain separate atomic mutations

- **WHEN** Console creates a Portal User and later uses Copy invite for the first time
- **THEN** creation SHALL atomically commit the invited identity and one `portal_user.invited` row without minting an invite
- **AND** first Copy SHALL observe no invite under the Portal User lock and atomically commit the hash-only invite and one `portal_user.invite_issued` row
- **AND** the plaintext invite URL SHALL be returned only after commit

#### Scenario: Concurrent Copy invite actions classify under the Portal User lock

- **WHEN** concurrent Copy invite actions target one invited Portal User with no stored invite
- **THEN** exactly one committed action SHALL be `portal_user.invite_issued`
- **AND** each later committed replacement SHALL be `portal_user.invite_reissued`
- **AND** token generation and expiry calculation SHALL occur after the lock so each stored expiry extends rather than moves backward

#### Scenario: Successful redemption and disablement are atomic

- **WHEN** a valid invite activates its currently invited Portal User, or an operator effectively disables a Portal User
- **THEN** the authoritative state and session changes SHALL commit with exactly one matching audit row
- **AND** redemption SHALL use Portal User provenance while disablement SHALL use shared Console operator provenance
- **AND** disabled-user or otherwise ineligible redemption SHALL remain mutation-free without success evidence

#### Scenario: Repeated disable is a true no-op

- **WHEN** an operator disables an already disabled Portal User
- **THEN** Orchard SHALL return the persisted state without rewriting timestamps or advancing the session epoch
- **AND** Orchard SHALL create no duplicate row or succeeded observation

#### Scenario: Portal key mutations revalidate authority before the key lock

- **WHEN** a validated Portal session requests key mint or own-key revoke
- **THEN** Orchard SHALL carry the tenant ID, Portal User ID, and password epoch into the transaction
- **AND** Orchard SHALL lock and revalidate that tenant-scoped active Portal User before cap enforcement or an API Key lock
- **AND** revoke SHALL use the lock order Portal User then API Key
- **AND** an effective mutation and its matching API Key audit row SHALL commit atomically

#### Scenario: Stale session or repeated revoke creates no success evidence

- **WHEN** the captured session epoch no longer matches the locked Portal User, or the owned key is already revoked
- **THEN** stale authority SHALL fail before an API Key is locked or mutated
- **AND** repeated revoke SHALL preserve its timestamps
- **AND** neither path SHALL create a duplicate row or succeeded observation

#### Scenario: Audit insertion failure rolls back the mutation

- **WHEN** a required Portal lifecycle or Portal-owned API Key audit insertion fails
- **THEN** the authoritative domain mutation SHALL roll back
- **AND** no secret-bearing success result SHALL be published
- **AND** no `outcome = 'succeeded'` audit observation SHALL be emitted

### Requirement: Portal Audit Payloads Are Bounded And Secret-Free

Portal lifecycle audit payloads SHALL use a closed per-action allowlist.
`portal_user.invited`, `portal_user.invite_redeemed`, and `portal_user.disabled` SHALL include exactly `surface`.
`portal_user.invite_issued` and `portal_user.invite_reissued` SHALL include exactly `surface` and `expires_at`.
Console `surface` SHALL be `console`, and redemption `surface` SHALL be `developer_portal`.
Invite `expires_at` SHALL be the replacement invite expiry encoded as a UTC ISO 8601 string.

Portal-owned `api_key.created` and `api_key.revoked` SHALL include `name`, `token_prefix`, `owner_type`, `surface`, `issuance_surface`, and `portal_user_id`.
They SHALL include `expires_at` when the key has an expiry and SHALL omit it otherwise.
`portal_user_id` SHALL be encoded as the canonical Portal User UUID string.
API Key `expires_at`, when present, SHALL be encoded as a UTC ISO 8601 string.
`owner_type` SHALL be `tenant`.
`surface` and `issuance_surface` SHALL be `developer_portal`.

Payloads SHALL NOT contain an invite token, invite hash, invite URL, password, password hash, Portal session token, Portal session hash, API Key plaintext secret, API Key secret hash, email address, request header, source address, raw error, arbitrary request parameter, or `previous_invite_existed`.
The issue-versus-reissue action name SHALL be the only durable classification of whether a prior invite row existed.
This refines `SPEC.md` sections 8.2, 10.8, and 10.9.

#### Scenario: Invite payload contains only bounded non-secret context

- **WHEN** Orchard commits a Portal User lifecycle audit row
- **THEN** the payload SHALL contain exactly the fields allowed for that action
- **AND** the target columns SHALL identify the Portal User
- **AND** the payload SHALL retain no token, hash, URL, email, raw request field, or prior-invite flag

#### Scenario: Portal API Key payload excludes key secrets

- **WHEN** Orchard commits a Portal-owned `api_key.created` or `api_key.revoked` row
- **THEN** the payload MAY contain only the approved bounded API Key and Portal provenance fields
- **AND** the target columns and `api_key_id` SHALL identify the API Key
- **AND** the payload SHALL NOT contain the plaintext secret or secret hash

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

### Requirement: Activation Curl Uses One Authorized Exact Model

After a successful mint, the portal SHALL show one `POST /v1/chat/completions` curl using an active exact Model with enabled access for the Workspace, or state that no test curl is available.
Selection SHALL be deterministic when no exact Model was requested.
An unavailable or unauthorized requested exact Model SHALL NOT be silently substituted.
Model availability and authorization SHALL NOT imply runtime readiness or request success.
If no eligible Model can be proven, the key mint SHALL still succeed.
The full secret SHALL appear only at creation and SHALL NOT be recoverable later.
This refines `SPEC.md` §7.2.3, §7.2.4, and §7.4a.

#### Scenario: No eligible model still mints the key

- **WHEN** a Portal User mints a key for a Workspace with no active authorized Model
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
