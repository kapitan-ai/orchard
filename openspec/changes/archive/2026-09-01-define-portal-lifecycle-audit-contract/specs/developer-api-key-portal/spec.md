## ADDED Requirements

### Requirement: Portal Lifecycle Mutations Produce Atomic Tenant Audit Evidence

Every effective Portal User lifecycle mutation SHALL commit one tenant-scoped audit row inside the same outermost `AuditWriter.transaction/1` boundary as its authoritative state changes.
`AuditWriter.transaction/1` SHALL NOT be nested inside another transaction that owns the authoritative mutation.
The row and mutation SHALL roll back together when audit insertion fails.
Portal User creation SHALL use `portal_user.invited`.
The first Copy invite action SHALL use `portal_user.invite_issued`, and a later Copy invite action that replaces an invite observed under the locked Portal User SHALL use `portal_user.invite_reissued`.
Successful invite redemption SHALL use `portal_user.invite_redeemed`.
An effective Portal User disablement SHALL use `portal_user.disabled`.
Portal-owned API Key mint and effective revoke SHALL reuse `api_key.created` and `api_key.revoked`.

Every row SHALL use the owning Organization's `tenant_id`.
Portal User actions SHALL target `target_type = 'portal_user'` and the affected Portal User ID.
API Key actions SHALL target `target_type = 'api_key'`, the affected API Key ID, and the matching `api_key_id`.
Console actions SHALL use `actor_type = 'operator'`, a null `actor_id`, and `surface = 'console'` until Console authenticates a first-class operator identity.
Successful redemption and Portal-owned key mutations SHALL use `actor_type = 'user'`, the Portal User ID as `actor_id`, and `surface = 'developer_portal'` as audit provenance only.
This provenance SHALL NOT make a Portal User an Operator, Public Inference principal, or other platform principal.

Audit rows SHALL represent committed effective mutations without a persisted outcome field.
A rejected request or true no-op SHALL NOT create a success audit row.
Successful audit telemetry SHALL be emitted only after the authoritative transaction commits, and a rolled-back transaction SHALL NOT emit a succeeded observation.
A direct audit insertion inside an unmanaged transaction SHALL fail before persistence.
A rolled-back savepoint SHALL NOT leave a publishable success observation.
Post-commit metric verification failure SHALL mark metrics reporting degraded without altering the committed domain result or withholding its show-once success value, and a later successful verification MAY recover that degradation.
This refines `SPEC.md` sections 7.4a, 8.2, 9.1, and 10.9.

#### Scenario: Portal User creation records the invited identity

- **WHEN** Console successfully creates a Portal User
- **THEN** the Portal User and one `portal_user.invited` audit row SHALL commit atomically
- **AND** the row SHALL be tenant-scoped, use the shared Console operator provenance, and target the Portal User
- **AND** creation SHALL NOT mint or store a Portal Invite token or return a Portal Invite URL

#### Scenario: First Copy invite is classified under the Portal User lock

- **WHEN** an operator uses Copy invite and no invite row exists after the invited Portal User is locked
- **THEN** Orchard SHALL classify the mutation as `portal_user.invite_issued`
- **AND** Orchard SHALL generate the fresh token and calculate its expiry after acquiring that lock
- **AND** the replacement hash-only invite row, target-user session termination, and audit row SHALL commit atomically
- **AND** the invite row and audit payload SHALL use that exact expiry
- **AND** the plaintext URL SHALL be returned only after the transaction commits

#### Scenario: Later Copy invite is classified as reissue under the lock

- **WHEN** an operator uses Copy invite and an invite row exists after the invited Portal User is locked
- **THEN** Orchard SHALL classify the mutation as `portal_user.invite_reissued`
- **AND** Orchard SHALL generate the fresh token and calculate its expiry after acquiring that lock
- **AND** Orchard SHALL delete and replace the prior invite row without retaining invalidation history
- **AND** the replacement hash-only invite row, target-user session termination, and audit row SHALL commit atomically

#### Scenario: Concurrent Copy invite actions use locked mutation-time classification

- **WHEN** concurrent Copy invite actions target one invited Portal User with no stored invite
- **THEN** classification SHALL serialize on the Portal User lock
- **AND** exactly one committed action SHALL be `portal_user.invite_issued`
- **AND** each later committed replacement SHALL be `portal_user.invite_reissued`
- **AND** each serialized replacement SHALL calculate expiry under the lock so the stored expiry extends rather than moves backward
- **AND** classification SHALL NOT depend on pre-transaction state

#### Scenario: Successful redemption records Portal User provenance

- **WHEN** a valid unexpired Organization-bound invite activates its currently invited Portal User through `POST /portal/:organization_slug/invites/:token`
- **THEN** activation, `redeemed_at`, target-user session termination, and `portal_user.invite_redeemed` SHALL commit atomically
- **AND** the audit actor SHALL be `user` with the activated Portal User ID
- **AND** that actor provenance SHALL NOT authorize the Portal User outside the Developer Portal

#### Scenario: Ineligible redemption remains mutation-free and unaudited as success

- **WHEN** redemption uses the wrong Organization or an invalid, expired, redeemed, disabled-user, or unknown invite
- **THEN** Orchard SHALL preserve the existing generic invalid-invite response
- **AND** Orchard SHALL persist no lifecycle mutation or success audit row
- **AND** a valid invite submitted through the wrong Organization SHALL remain usable through its owning Organization

#### Scenario: Disable records only an effective transition

- **WHEN** an operator disables a Portal User who is not already disabled
- **THEN** the status change, outstanding-unused-invite deletion, target-user session termination, and `portal_user.disabled` SHALL commit atomically
- **AND** the audit row SHALL use shared Console operator provenance and target the Portal User
- **AND** the Portal User's API Keys SHALL remain unchanged

#### Scenario: Repeated disable is a true no-op

- **WHEN** an operator disables a Portal User who is already disabled
- **THEN** Orchard SHALL return the persisted disabled state without rewriting `disabled_at` or advancing the session epoch
- **AND** Orchard SHALL NOT create another `portal_user.disabled` row or succeeded audit observation

#### Scenario: Portal key mint reuses the API Key action

- **WHEN** an authorized Portal User mints a tenant-direct API Key
- **THEN** Orchard SHALL carry the validated session tenant ID, Portal User ID, and password epoch into the transaction
- **AND** Orchard SHALL lock that tenant-scoped Portal User first and revalidate active status and the captured epoch before cap enforcement
- **AND** the key and one `api_key.created` audit row SHALL commit atomically while cap enforcement remains serialized on that Portal User
- **AND** the row SHALL target the API Key and record the Portal User as actor provenance
- **AND** Orchard SHALL return the show-once key secret only after the transaction commits

#### Scenario: Portal key revoke records only an effective transition

- **WHEN** an authorized Portal User revokes their active Portal-owned API Key
- **THEN** Orchard SHALL lock and revalidate the tenant-scoped Portal User against the captured session epoch before locking the API Key
- **AND** the lock order SHALL be Portal User then API Key
- **AND** the active-to-revoked transition and one `api_key.revoked` row SHALL commit atomically
- **AND** the row SHALL target the API Key and record the Portal User as actor provenance
- **AND** a later revoke of the already revoked key SHALL create no mutation, duplicate row, or succeeded observation

#### Scenario: Stale Portal session cannot authorize a key mutation

- **WHEN** a Portal key mint or revoke reaches the transaction after the validated session epoch no longer matches the locked Portal User
- **THEN** Orchard SHALL reject the mutation as an invalid session
- **AND** Orchard SHALL NOT create, revoke, or lock an API Key before that rejection
- **AND** Orchard SHALL NOT create a success audit row or succeeded observation

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
`owner_type` SHALL be `tenant`.
`surface` and `issuance_surface` SHALL be `developer_portal`.
`portal_user_id` SHALL be the canonical Portal User UUID string, and API Key `expires_at` SHALL be a UTC ISO 8601 string.

Payloads SHALL NOT contain an invite token, invite hash, invite URL, password, password hash, Portal session token, Portal session hash, API Key plaintext secret, API Key secret hash, email address, request header, source address, raw error, arbitrary request parameter, or `previous_invite_existed`.
The issue-versus-reissue action name SHALL be the only durable classification of whether a prior invite row existed.
This refines `SPEC.md` sections 8.2, 10.8, and 10.9.

#### Scenario: Invite issue payload contains only bounded non-secret context

- **WHEN** Orchard commits `portal_user.invite_issued` or `portal_user.invite_reissued`
- **THEN** the payload SHALL contain only the originating surface and the new expiry
- **AND** the target columns SHALL identify the Portal User
- **AND** the payload SHALL NOT retain the prior invite's existence, token, hash, URL, or any user email

#### Scenario: Portal API Key payload excludes key secrets

- **WHEN** Orchard commits a Portal-owned `api_key.created` or `api_key.revoked` row
- **THEN** the payload MAY contain only the approved bounded API Key and Portal provenance fields
- **AND** the target columns and `api_key_id` SHALL identify the API Key
- **AND** the payload SHALL NOT contain the plaintext secret or secret hash
