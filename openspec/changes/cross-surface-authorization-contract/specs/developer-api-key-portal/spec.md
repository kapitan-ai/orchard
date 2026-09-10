## MODIFIED Requirements

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
After named Console cutover, Console actions SHALL use `actor_type = 'operator'`, the stable Console Identity UUID as `actor_id`, `actor_principal_type = 'console_identity'`, `actor_credential_type = 'console_session'`, its non-secret persisted session UUID as `actor_credential_id`, and `surface = 'console'`.
Historical anonymous rows SHALL remain unchanged; pre-cutover rows retain their legacy attribution.
New rows governed by this Portal lifecycle/self-service contract SHALL use top-level `payload_schema = 'portal_lifecycle.v1'`.
Management-family revocation of a Portal-minted key SHALL instead use `credential_management.v1` under that operation's authority, actor, audit scope, and closed payload contract; key ownership SHALL NOT choose the schema.
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
- **AND** redemption SHALL use Portal User provenance while disablement SHALL use the named Console Identity provenance after cutover
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

#### Scenario: Management and Portal revoke select different explicit schemas

- **WHEN** management revokes a Portal-minted key through its credential family, or the owning Portal User revokes a key through Portal
- **THEN** the executing operation selects `credential_management.v1` or `portal_lifecycle.v1` respectively while preserving `api_key.revoked` and the target key reference
- **AND** management attributes its authenticated principal while Portal retains Portal User identity and self-service scope
- **AND** no historical audit row is rewritten

### Requirement: Portal Audit Payloads Are Bounded And Secret-Free

Portal lifecycle and self-service payloads selected by top-level `payload_schema = 'portal_lifecycle.v1'` SHALL use the following unchanged closed per-action allowlists.
Management revocation of a Portal-minted key SHALL select `credential_management.v1` and that operation's closed payload; it SHALL NOT append management fields to these Portal payloads.
Null discriminators SHALL identify legacy records decoded under their historical contract, without inferred modern attribution or backfill.
This modifies `SPEC.md` §§8 and 10.9 by selecting schemas through the executing operation rather than issuance provenance.
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

#### Scenario: Portal payload remains closed after named Console migration

- **WHEN** a named Console Identity invites or disables a Portal User after cutover
- **THEN** named principal/session references appear only in explicit top-level audit fields
- **AND** the existing Portal per-action payload allowlist remains unchanged
