## ADDED Requirements

These requirements are accepted target behavior under `SPEC.md` §10.11 and remain pending implementation and cutover; they do not establish a COMPLETE family.

### Requirement: Typed management identity and authority

Under the accepted target in `SPEC.md` §§2.3, 7.1, 8, 10.1, and 10.4, Orchard SHALL distinguish principal, credential, session, grant, action, resource, scope, and audit actor.
A Console Identity SHALL identify one named human with a stable UUID, unique normalized login name, `pending_setup | enabled | disabled` state, a password verifier only after setup, and authentication epoch.
API Clients SHALL remain non-interactive principals and Portal Users SHALL remain Portal-only identities.
Role grants SHALL bind a typed principal to an explicit cluster or Tenant scope and SHALL resolve through a closed server-owned action policy.
Unknown actions, untrusted caller contexts, and missing grants SHALL deny by default.
Owner Contact, display names, source addresses, and tool names MUST NOT authenticate or authorize.

#### Scenario: Matching contact does not join identities

- **WHEN** a Console Identity, Portal User, and API Client Owner Contact have the same visible contact value
- **THEN** their identity, session, grant, and credential lifecycles remain independent
- **AND** none inherits authority from the matching metadata

#### Scenario: Client submits administrator context

- **WHEN** a request submits an actor ID, role list, or local-recovery flag as ordinary input
- **THEN** the Controller derives authority only from its trusted authentication boundary
- **AND** the submitted values cannot grant an action

### Requirement: Named Console sessions are revocable authentication results

Under the accepted target in `SPEC.md` §§10.1 and 10.8, Console login SHALL authenticate an enabled named identity and mint a fresh independent random session bearer.
Only its verifier SHALL be persisted, with identity ID, captured authentication epoch, activity timestamps, expiry, and revocation state.
Sessions SHALL expire after 12 hours absolutely or 30 minutes idle, whichever occurs first.
Activity SHALL NOT extend absolute expiry.
Logout and individual revocation SHALL end the targeted session.
Identity disablement and successful setup redemption SHALL increment the identity authentication epoch and invalidate all standing sessions atomically.
Disablement SHALL invalidate outstanding invitations; setup SHALL NOT reset or reenable active/disabled identities, and password reset/reenablement SHALL remain separate deferred lifecycles.
Production login SHALL require effective HTTPS, use a separate Secure/HttpOnly/SameSite=Lax Console cookie, enforce CSRF and LiveView origin checks, and return generic rate-limited credential failures without public signup.
Named `GET /console/login`, `POST /console/session`, and `POST /console/logout` SHALL be available outside Basic Auth on the restricted pre-cutover preparation surface; those sessions SHALL NOT open general Console access before activation.
Console sessions MUST NOT authorize public inference, Admin API, Operator API, or Portal access.

#### Scenario: Stale LiveView after session revocation

- **WHEN** a session is revoked after a LiveView mounted and its disconnect notification is lost
- **THEN** its next protected event, refresh, or data delivery fails current session validation
- **AND** no new protected result or mutation is exposed through the stale session

#### Scenario: Identity disablement invalidates other sessions

- **WHEN** a Console Identity is disabled while two sessions are active
- **THEN** both captured epochs become invalid in the disable transaction
- **AND** neither session can authorize another operation

#### Scenario: Portal cookie submitted to Console

- **WHEN** a valid Portal session is presented to the Console
- **THEN** it does not authenticate a Console Identity or create a Console Session

### Requirement: Idle activity is explicit and cannot resurrect authority

Under the accepted target in `SPEC.md` §§10.1 and 10.8, Console expiry SHALL use server time with `now >= min(created_at + 12 hours, last_activity_at + 30 minutes)` meaning expired.
Only successfully authorized client-initiated operations in the server-owned activity class SHALL advance activity monotonically under the session protocol.
Explicit credential list, inspect, and preview operations SHALL qualify; background polling, automatic refreshes, heartbeats, subscriptions, asynchronous delivery, and denied checks SHALL NOT qualify.
An eligible touch SHALL revalidate session status, epoch, and both deadlines before commit and MUST NOT resurrect expired/revoked authority or extend absolute expiry.
Completion delayed beyond expiry SHALL NOT touch activity or publish a fresh protected result.
Eligible Console idle bookkeeping SHALL be the sole exception to domain-side-effect-free preview semantics, with no domain mutation or success audit row.
Client initiation SHALL identify the protocol event, not prove human presence; an agent using the session can invoke eligible actions.

#### Scenario: Unattended connected Console expires

- **WHEN** only heartbeats, scheduled refreshes, and subscription deliveries occur for 30 minutes
- **THEN** those events do not advance last activity
- **AND** the session expires exactly at the idle deadline despite a connected socket

#### Scenario: Explicit preview before expiry

- **WHEN** an authorized explicit preview completes while the session is valid
- **THEN** its session activity may advance without domain mutation or success audit
- **AND** the same request at or after either expiry deadline cannot revive authority

### Requirement: Named setup has authenticated carriers and bounded recovery

Under the accepted target in `SPEC.md` §§7.4, 8, 10.1, 10.9, and 11.9, `POST /admin/v1/console-identities` SHALL use existing enabled cluster-admin API Client admission and active Controller authority before or after cutover.
Its exact body SHALL be `login_name`, `initial_access`, `reason`, `confirmed`, and UUID `idempotency_key`.
`initial_access` SHALL contain `role` and `tenant_id`, allowing cluster `admin`/`operator` only with null Tenant or `tenant_admin` only with one existing exact Tenant UUID.
The first identity SHALL require explicitly supplied cluster `admin`, with no implicit grant default; non-admin creation SHALL require an already enabled named cluster admin.
The operation SHALL serialize that guard and atomically persist pending identity, grant, audit, and non-secret idempotency result, without creating a password, invitation, or session.
It SHALL return `{data: {identity_id, state, revision, initial_access}}`.
Same-principal same-key identical retries SHALL reauthorize and return the original result; changed inputs or duplicate normalized login under a different key SHALL return `conflict`.
The idempotency result SHALL be retained with the identity.
Setup mutations SHALL require `confirmed: true` and a reason of 1-512 Unicode characters after trimming.

`GET /admin/v1/console-identities/:id` and the equivalent named cluster-admin Console operation SHALL return exactly `{data: {identity_id, state, revision}}` under current cluster-admin authorization, active Controller/storage requirements, and `Cache-Control: no-store`.
Inspection SHALL NOT return passwords, setup tokens/verifiers, or authentication material.
Identity revision SHALL be a monotonic generation initialized to `1` at creation and advanced once in the authoritative transaction for each effective invitation issue/replacement, redemption, disablement, or grant change.
No-op, replay, failed attempt, read, login/session activity, and passive invitation expiry SHALL NOT advance revision; expiry SHALL still be enforced independently at action time.
Idempotency replay SHALL return the original result without refreshing it; stale mutation recovery SHALL obtain current state through inspection before explicitly retrying with new confirmation and current revision.
A recovered administrator using another API Client SHALL inspect current state rather than depend on another principal's creation idempotency record.

`POST /admin/v1/console-identities/:id/setup-invitations` SHALL accept only `pending_setup` identities and the exact body `expected_revision`, `replace`, `reason`, `confirmed`, and UUID `idempotency_key` under the same authority.
Under the identity fence it SHALL issue one independent random hash-only identity-bound invitation generation expiring exactly 15 minutes after issue.
The verifier SHALL bind target identity UUID, purpose `console_identity_setup`, captured target authentication epoch, generation, and expiry, all of which redemption SHALL revalidate.
Issuer revocation after committed issuance SHALL NOT cancel the invitation; target state/epoch, replacement, consumption, and expiry SHALL determine its continued eligibility.
Existing unconsumed invitations SHALL require explicitly confirmed `replace: true`, a fresh key, and current revision; replacement SHALL invalidate the previous generation atomically.
The first successful one-time HTTPS result SHALL be `{data: {identity_id, revision, invitation_generation, expires_at, delivery: "issued", setup_token}}` with `Cache-Control: no-store`.
Same-key retries SHALL return only those non-secret fields with `delivery: "already_issued"`, never plaintext or a new invitation; lost delivery SHALL require explicit replacement.
Stale revisions and changed-input key reuse SHALL return `conflict` without effect.

Static HTTPS `GET /console/setup` and CSRF-protected `POST /console/setup` SHALL sit outside legacy Basic Auth admission without granting ordinary management access.
Setup secrets SHALL NOT appear in HTTP path/query, request/error logging, audit, or telemetry; optional fragment delivery SHALL be cleared before instrumentation/LiveView connection, with no third-party scripts, `no-store`, and `Referrer-Policy: no-referrer`.
POST SHALL atomically validate current pending identity, generation, unexpired unused verifier, consume it, set the password, enable the identity, advance epoch, and persist audit.
GET SHALL NOT consume the token, and successful redemption SHALL require subsequent ordinary login rather than promote the verifier to a session.
Unknown, expired, replaced, consumed, disabled, and wrong-state submissions SHALL have one generic failure and no mutation.

`POST /admin/v1/console-identities/:id/disable` SHALL accept `expected_revision`, `reason`, and `confirmed` under the same authority and atomically disable pending/enabled identities, invitations, and sessions.
Repeated disable SHALL be an authorized true no-op with unchanged revision/timestamps and no duplicate audit.
Named cluster-admin Console callers SHALL use these same prerequisite operations after cutover; general grant editing, password reset, and reenablement remain deferred.
Lost administrator authority SHALL be recovered only through existing local `orchardctl cluster init --force-new-admin --yes --output <path>` followed by these authenticated APIs to create an additional named admin.
Failed credential publication SHALL preserve the reported authority/publication/containment outcomes without automatic mint/publication retries.
Before revoking a stranded credential, recovery SHALL obtain another usable administrator credential, resolve the exact reported stored prefix through metadata-only family lookup, and explicitly preview/revoke the returned kind/UUID with current revision and confirmation.
Publication failure SHALL NOT imply authority rollback or permit unauthenticated revocation.
No new local identity-recovery bypass or unauthenticated first-authority mint endpoint SHALL be introduced.

#### Scenario: Recover machine authority then create first human admin

- **WHEN** local recovery mints an API Client administrator credential and the operator explicitly requests an initial cluster-admin Console Identity through the authenticated API
- **THEN** pending identity, grant, and audit commit together without usable Console authority
- **AND** invitation redemption and subsequent login establish the named administrator without extending local recovery authority

#### Scenario: Issued invitation response is lost

- **WHEN** an issuance commits but its response is lost
- **THEN** a same-key retry returns non-secret `already_issued` without recovering plaintext
- **AND** a separately confirmed replacement invalidates the prior generation

#### Scenario: Another administrator replaces an invitation

- **WHEN** an invitation replacement advances the identity revision after an administrator captured earlier state
- **THEN** the stale mutation conflicts without effect and the administrator can inspect the current non-secret state/revision
- **AND** original creation or issuance replay remains historical rather than silently refreshing the revision

#### Scenario: Redemption is followed by authenticated disablement

- **WHEN** setup redemption enables an identity and advances its revision
- **THEN** an authorized administrator can inspect the enabled state and current revision before explicitly confirming disablement
- **AND** the disablement advances revision once and reveals no setup secret

#### Scenario: Recovered API Client continues identity administration

- **WHEN** a different API Client recovered through the existing local bootstrap path holds current cluster-admin authority
- **THEN** it can inspect an existing Console Identity and perform a newly confirmed revision-gated operation
- **AND** it does not need access to the original creator's idempotency record

#### Scenario: Concurrent replay and disablement

- **WHEN** invitation redemption races with another redemption, replacement, or identity disablement
- **THEN** the identity fence admits at most one valid-generation redemption
- **AND** stale or ineligible redemption returns the generic failure without state or audit mutation

#### Scenario: Setup token is presented as reset or management authority

- **WHEN** a caller submits a setup token for an enabled/disabled identity or an ordinary management action
- **THEN** Orchard denies without resetting or enabling the identity or granting that action

#### Scenario: Invitation issuer is revoked after issue

- **WHEN** an administrator's credential is revoked after its setup invitation commits
- **THEN** the invitation remains redeemable only under its own target/purpose/epoch/generation/expiry rules
- **AND** the issuer's historical audit reference remains intact without granting the issuer further authority

### Requirement: Authorization is enforced at the Controller operation boundary

Under the accepted target in `SPEC.md` §§7.3, 7.4, 10.4, and 11.9, Console, API, and CLI adapters SHALL invoke one Controller-owned action policy and domain operation boundary for each migrated family.
That boundary SHALL validate current principal state, credential/session validity, grants, action, authoritative resource ownership and privilege, scope, and leadership.
Page admission, API plug authentication, LiveView mount, earlier previews, hidden controls, and client-side tool registration MUST NOT substitute for operation authorization.
Protected reads, previews, mutations, and delivery of newly fetched protected data SHALL perform current validation.
Protected data SHALL linearize at admission to the server HTTP/socket transmission queue under current serialized authority, not at an earlier fetch or callback.
Previously fetched data not yet admitted SHALL be revalidated and suppressed after authority loss; already admitted bytes cannot be recalled even if delivered later.
The single bounded acknowledgement of a committed mutation, including self-revocation, SHALL remain deliverable under that transaction's authorization without another protected read.
Disconnected LiveView renders MUST NOT expose protected data.
Before named Console cutover, every reachable non-migrated protected handler or data path SHALL enforce an action-time cluster-admin guard or fail closed.
This SHALL include direct events, routes, parameter changes, asynchronous results, and subscription delivery, so scoped and roleless identities cannot inherit legacy Console authority.
Admin and Operator API bearer audiences SHALL retain their existing API Client cluster-role admission requirements.
Console operations SHALL use the human's own authority without an implicitly minted administrator API Token.

#### Scenario: Role removed after API admission

- **WHEN** an API request passed its authentication plug but its actor's required grant is removed before the domain operation authorizes
- **THEN** the operation denies using current authority
- **AND** the earlier plug result cannot permit the effect

#### Scenario: Agent uses administrator browser

- **WHEN** an agent operates a valid administrator Console Session through a limited tool list
- **THEN** the session retains the administrator's server-enforced authority
- **AND** Orchard does not claim the tool list is a reduced grant or separate audit identity

#### Scenario: Scoped identity calls a legacy Console handler

- **WHEN** a Tenant-admin or operator-only identity sends a direct event to a non-migrated cluster-management handler
- **THEN** a current server-side cluster-admin guard denies the event and any protected data delivery
- **AND** browser admission or hidden navigation cannot authorize it

### Requirement: Restrictive authority changes and operations serialize

Under the accepted target in `SPEC.md` §§10.2, 10.4, and 10.9, protected operations SHALL share a transaction protocol with actor disablement, credential/session revocation, grant edits, and target ownership or privilege changes.
The protocol SHALL fence actor and target principals, including concurrent addition of previously absent grants, and lock credential/session and target rows in a deterministic order.
After fences are acquired, the operation SHALL reread principal status, credential/session revocation and expiry, idle/absolute expiry, authentication epoch, current grants, and target state before authorizing.
Existing grant, credential, identity, and API Client mutation paths SHALL participate in these fences even if their broader family has not migrated.
A restrictive change committed before protected transmission admission or the mutation transaction SHALL prevent success from a cached caller context.
An operation committed first SHALL remain a committed effect when revocation commits later.
Self-target operations SHALL deduplicate overlapping fences.
Revocation SHALL block the next authentication or operation boundary without implicitly canceling already admitted Public Inference work.

#### Scenario: Workspace token gains cluster authority during revoke

- **WHEN** a Tenant-admin revoke races with adding a cluster grant to the target API Client
- **THEN** both operations serialize on the target principal's authority fence
- **AND** the revoke is denied if the cluster grant commits first
- **AND** a revoke committed first is not retroactively reversed

#### Scenario: Actor is revoked while waiting for a target lock

- **WHEN** a credential revoke operation overlaps revocation of its actor credential or session
- **THEN** common authority fencing produces a single committed ordering
- **AND** the operation cannot commit on authority already revoked earlier in that ordering

### Requirement: Every retained authority writer participates in cutover

Under the accepted target in `SPEC.md` §§10 and 13, the required contract version SHALL cover action policy, session validity, credential/grant writes, authority fences, and audit behavior across every writer.
The closure ledger SHALL explicitly cover management aliases/governance overloads; Portal own-key mint/revoke; Portal invitation/redemption/disable/logout/epoch paths; Console login/logout/setup/disable/session revoke; API Client disable/grant creation/edit; bulk provisioning/rotation; local `cluster init` including forced recovery; and retained direct-DB CLI entry points.
Each ledger entry SHALL identify its authorized operation, complete affected fence set and row order, applicable atomic-audit contract, and whether its broader family is complete or retained pending migration.
Portal operations SHALL retain their narrower session/ownership contract and Portal User-before-key row order while joining affected credential fences; logout/epoch mutation SHALL NOT be exempt from serialization merely because its current audit contract omits a new success event.
Batch/grant/rotation writers SHALL acquire the full sorted affected-principal/key fence set before mutation, including absent-grant insertion.
No standalone management revoke SHALL survive outside shared credential authority or the explicitly retained Portal own-key operation.
Deferred broader family migration SHALL NOT excuse an incompatible writer attaching to the live post-cutover authority store.

#### Scenario: Old CLI bypass exists with Console disabled

- **WHEN** a retained direct-DB CLI or Portal writer lacks current action-policy/session/fence/audit compatibility
- **THEN** cutover blocks or stops/isolates that writer from the post-cutover authority store
- **AND** disabling Console does not qualify the writer as safe

### Requirement: Explicit Basic Auth cutover and bounded recovery

Under the accepted target in `SPEC.md` §§10.1, 11.9, and 13, named Console setup SHALL require explicit cluster-admin authority and expiring single-use protected setup material.
A deployment without an available admin credential SHALL use existing local `orchardctl cluster init` recovery authority first, preserving its leader, confirmation, one-time output, and audit contract.
No installer, environment variable, shared Basic Auth login, Portal User, or node Bootstrap Token SHALL seed or imply a named human administrator.
A durable cluster-wide cutover SHALL require a currently valid unexpired/unrevoked Console Session for an enabled named cluster administrator, verified recovery, and compatible support from every non-retired eligible Controller.
Activation SHALL revalidate that live session, its identity's current enabled state/authentication epoch, and cluster-admin grant under the common identity/session fences; historical login evidence alone SHALL NOT suffice.
Its durable states SHALL be `pre_cutover`, `named_active`, and `rollback_console_disabled`, retaining `required_console_auth_contract_version` after activation.
Activation SHALL require cluster-admin authority, preview, typed confirmation, expected contract version covering all action-policy/session/fence/audit writers, and fresh evidence from every non-retired eligible Controller including Standby and disconnected instances that may return.
Missing/stale/expired evidence SHALL block unless refreshed or the instance is explicitly retired and isolated; retained direct-DB CLI writers SHALL also be inventoried and version-gated.
Before activation, deployment SHALL establish persistent host/service launch and database-access gates excluding incompatible authority writers and verified ingress enforcement covering direct backend HTTP listeners and actual Console LiveView handshake/transport.
Unknown or unenforceable launch/ingress state SHALL block activation, and a cutover-aware Controller below the recorded version SHALL refuse authority-store access at boot, including Console service.
After cutover, Basic Auth, old boolean cookies, connected legacy LiveViews, and production `auth: :none` MUST NOT authorize Console operations.
The cluster MUST NOT admit an incompatible Controller that can restore legacy authority after cutover.
Before any pre-cutover binary starts, rollback SHALL enter `rollback_console_disabled`, block Console HTTP and LiveView access, terminate existing sockets, and persist Console-disabled launch configuration with direct-listener fencing.
When the Console transport cannot be safely separated, the deployment SHALL block the affected listener rather than filter only `/console/*`.
Old binaries cannot interpret the new database state; before execution they SHALL be stopped or isolated so their API/CLI/Portal/session writers cannot reach the live post-cutover authority store, in addition to Console HTTP/LiveView fencing.
Disabling Console alone SHALL NOT satisfy the rollback profile, and downgrade SHALL be unsupported when isolation cannot be verified.
An isolated historical environment SHALL NOT retain the COMPLETE family claim or share the post-cutover authority store.
Restoration SHALL require compatible software, current named authority, and service/ingress verification; interrupted rollback SHALL stay Console-disabled across restart/failover, and cutover state MUST NOT be erased.
After compatible software and host/service/database/ingress isolation are verified, deployment SHALL permit a restricted HTTPS restoration surface exposing only setup redemption, named login/logout, restoration form/preview/confirmation, and their minimal static assets.
All legacy/other Console routes and general LiveView transport SHALL remain blocked on that surface.
With no surviving session, an operator SHALL be able to log in anew or use existing local machine-credential recovery followed by authenticated identity provisioning/invitation, pending setup redemption, and fresh named login.
Restoration SHALL require the acting named cluster admin's valid unexpired/unrevoked session with current identity epoch/grant plus deployment compatibility, and SHALL commit `console_auth.access_restored` atomically with `named_active` before general access is enabled.
Failure SHALL keep general Console/LiveView access closed rather than require a previously surviving session or restore Basic Auth.
Local bootstrap/recovery SHALL remain locally authenticated, narrow, Controller-owned, and audited, with no general Repo fallback or human impersonation.

#### Scenario: Existing shared login at cutover

- **WHEN** cutover activates with old boolean Console cookies and live sockets present
- **THEN** those cookies and sockets lose authority
- **AND** no marker is converted into a session attributed to an invented human

#### Scenario: Named setup is incomplete

- **WHEN** no named cluster administrator has successfully authenticated or a serving Controller lacks compatible support
- **THEN** cutover refuses without changing production authentication state

#### Scenario: All normal administrator credentials are lost

- **WHEN** an operator proves the existing local Controller recovery authority
- **THEN** bounded recovery can mint additional administrator authority and enable explicit named identity recovery
- **AND** it neither deletes existing credentials nor becomes an ordinary management bypass

#### Scenario: Pre-cutover software is restarted after activation

- **WHEN** an operator rolls back to a binary that understands only environment Basic Auth
- **THEN** external gates block Console HTTP and LiveView, terminate old sockets, and persist disabled launch configuration before it starts
- **AND** an unverifiable profile makes the downgrade unsupported rather than relying on the old binary to interpret new state

#### Scenario: Administrator proof expires or Controller evidence is stale

- **WHEN** the administrator session expires before activation or a non-retired eligible Controller has stale capability evidence
- **THEN** activation refuses until live authority and fresh evidence are established or the Controller is explicitly retired and isolated
- **AND** a past successful login or absent Controller is not accepted as current readiness

#### Scenario: Restoration has no surviving Console session

- **WHEN** rollback outlasts every session and compatible software plus host/service/database/ingress isolation have been verified
- **THEN** only the restricted setup/login/logout/restoration HTTPS surface becomes available
- **AND** an operator can provision and redeem a new pending admin through the authenticated setup bridge if needed, log in, and confirm restoration with that acting valid session
- **AND** general Console/LiveView remains closed until compatibility, current authority, and atomic restoration audit/state succeed

### Requirement: Policy preparation has explicit named-session carriers

Under the accepted target in `SPEC.md` §§7.1, 10.1, 10.9, and 13, activation SHALL use `GET/POST /console/auth/activation` and restoration `GET/POST /console/auth/restoration` as restricted same-origin HTTPS controller/form routes outside Basic Auth, without general LiveView transport.
GET SHALL render only the authenticated form/current policy state; POST SHALL use the acting cluster-admin Console Session with existing CSRF, rate-limit, authority-fence, and audit protections.
API Bearers and another session's UUID SHALL NOT authenticate these operations; no new Console bearer audience is introduced.
The exact body SHALL be `dry_run`, `expected_state`, `expected_contract_version`, `confirmed`, and `typed_confirmation`.
Preview SHALL use `dry_run: true` with expected state/version; execution SHALL additionally require `confirmed: true` and literal `ACTIVATE NAMED CONSOLE` or `RESTORE NAMED CONSOLE` for the matching operation.
Activation SHALL require `pre_cutover` and restoration `rollback_console_disabled`; stale state/version SHALL return `conflict` without silent refresh.
Preview SHALL return `{data: {status: "preview", state, required_contract_version, blockers, warnings, consequence_codes, confirmation_requirements}}` without policy/domain/audit mutation.
Execution SHALL return `{data: {state, required_contract_version}}` only after atomic policy/audit commit; current acting session/epoch/grant SHALL be revalidated at execution and general access SHALL remain closed on failure.

#### Scenario: API Client supplies a purported Console session

- **WHEN** an API Client submits a live administrator session UUID instead of authenticating the preparation operation with the acting Console Session
- **THEN** the request fails named-session authentication
- **AND** machine authority remains confined to the existing authenticated provisioning/recovery bridge

### Requirement: Named audit attribution preserves historical evidence and closed schemas

Under the accepted target in `SPEC.md` §§8 and 10.9, authenticated Console operations SHALL record `actor_type = 'operator'` and the stable Console Identity UUID as non-null `actor_id`.
API and portable CLI management operations SHALL retain `actor_type = 'operator'` and record the authenticated API Client UUID as actor, independently of surface provenance.
New nullable top-level fields SHALL be `payload_schema`, `actor_principal_type`, `actor_credential_type`, and `actor_credential_id`.
New management revokes SHALL require principal type `console_identity` with credential type `console_session` or principal type `service_account` with credential type `api_key`, plus the corresponding persisted authentication-record UUID.
Target `api_key_id` SHALL remain the revoked target rather than the authenticating API Token ID.
Session targets SHALL always have null `api_key_id`, and subsequent identity/credential/session cleanup SHALL NOT null or rewrite historical actor/target/authentication references through cascading foreign keys or other updates.
The §8 reconciliation SHALL replace any conflicting audit foreign-key `ON DELETE SET NULL` behavior with retained stable references before accepting cleanup under this contract.
Server-known surface SHALL be `console` or `admin_api`; portable CLI HTTP calls SHALL use `admin_api` because a caller header cannot establish trusted CLI provenance.
Legacy/null discriminator rows SHALL retain legacy decoding and null typed fields without backfill; system/local-recovery/non-management rows may retain null authentication references without claiming a human identity.
New management revokes SHALL use `credential_management.v1`, and new Portal lifecycle/self-service events SHALL use `portal_lifecycle.v1`, selected by executing operation rather than key ownership.
New Portal-origin actor type/ID SHALL remain `user`/Portal User UUID with `actor_principal_type = 'portal_user'`; its non-management credential reference may remain null until separately migrated.
Console Session record IDs SHALL be distinct from session bearer values.
The explicit null Console actor rule SHALL be replaced and the discriminator-specific closed payloads in the credential/Portal deltas SHALL govern; fields MUST NOT be appended implicitly.
Historic anonymous rows SHALL remain unchanged.
Effective mutations and success audit rows SHALL commit atomically; audit failure SHALL roll back the effect and success telemetry SHALL occur only after commit.
Preview, denial, and true no-op SHALL NOT emit successful mutation audit rows or observations.

New named setup/disable events SHALL use `payload_schema = 'console_identity.v1'`, cluster scope, and target type `console_identity`.
Exact action/payload mappings SHALL be `console_identity.created` with `{surface, reason, initial_access}`, `console_identity.setup_issued` and `console_identity.setup_replaced` with `{surface, reason, invitation_generation, expires_at}`, `console_identity.setup_redeemed` with `{surface}`, and `console_identity.disabled` with `{surface, reason}`.
API/Console identity administration SHALL carry the same typed actor/authentication references as management revokes.
Setup redemption SHALL use actor type `operator`, target identity UUID as actor, principal type `console_identity`, credential type `console_setup_invitation`, its non-secret persisted invitation UUID, and surface `console_setup` without any other authority.
New `console_identity.*` and `console_session.*` actions SHALL have explicit audit telemetry-domain mappings.
Session creation and effective logout SHALL use `console_session.created` and `console_session.logged_out`, `payload_schema = 'console_session_lifecycle.v1'`, exact payload `{surface}`, cluster scope, target type `console_session`, null `api_key_id`, and the Console Identity actor with the persisted session record reference.
Creation SHALL persist the session/audit before publishing its cookie; logout SHALL atomically revoke/audit once, with no duplicate no-op success event.
Effective policy transitions SHALL use `console_auth.cutover_activated`, `console_auth.rollback_disabled`, and `console_auth.access_restored` with `payload_schema = 'console_auth_lifecycle.v1'`, exact payload `{surface, previous_state, state, required_contract_version}`, cluster scope, target type `console_auth_policy`, target ID `cluster`, and the actual authorized actor.
These events SHALL commit with durable state transitions and receive an explicit `console_auth` telemetry mapping.
Audit failure SHALL deny activation/restoration service enablement; external safety fencing may remain closed when rollback persistence fails but SHALL NOT be reported as a successful durable transition.

#### Scenario: Named Console administrator disables Portal User

- **WHEN** a named Console administrator performs an authorized Portal User disablement
- **THEN** audit attributes the operation to that Console Identity under the explicitly reconciled schema
- **AND** Portal User identity and key-revocation independence remain unchanged
- **AND** older anonymous Console audit rows remain unchanged

#### Scenario: Audit insertion fails during revocation

- **WHEN** the effective revoke transaction cannot persist its required audit row
- **THEN** the target remains unrevoked
- **AND** no successful response or success telemetry is emitted

### Requirement: Authentication audiences remain separate

Under retained `SPEC.md` §§7.4a, 10.2, 10.3, 10.5, and 10.6, Portal User and session authority SHALL remain Portal-scoped and tenant-direct inference keys SHALL still authenticate the Tenant without consulting Portal User state.
Portal User disablement SHALL end that user's sessions without revoking minted inference keys.
Console Identity disablement SHALL NOT disable matching-contact API Clients or Portal Users.
Node certificates, node-join Bootstrap Tokens, and Peer Grants SHALL remain trust/transport credentials and MUST NOT authorize human management operations.
Host-local privileges SHALL NOT be accepted as ordinary remote management caller context.

#### Scenario: Portal User disabled after key mint

- **WHEN** a Portal User who minted a valid tenant-direct key is disabled
- **THEN** its Portal sessions end
- **AND** the key remains valid until its independent expiry, revocation, or existing inference authorization rules deny it

#### Scenario: Node identity requests credential inventory

- **WHEN** a trusted Node presents a certificate or Peer Grant to management credential inspection
- **THEN** management authentication denies without revealing credential metadata
