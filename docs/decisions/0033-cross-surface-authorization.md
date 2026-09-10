# ADR: Named Console identities and shared management authorization

## Status

Proposed.
This record and the associated `cross-surface-authorization-contract` OpenSpec package are reviewable change intent, not accepted behavior or implementation authorization.
`SPEC.md` remains authoritative until a separately reviewed implementation reconciles the changes below.

## Context

Console currently admits browsers through shared Basic Auth and a boolean session marker in `OrchardConsole.Auth`.
That marker identifies neither a person nor a revocable server-side session.
Admin and Operator APIs instead use enabled API Clients with cluster-scoped RoleBindings under ADRs 0004 and 0007.
ADR 0024 requires normal Console and CLI operations to converge on Controller-owned authority, migrating complete command families while retaining bounded local bootstrap and recovery.
`SPEC.md` §10.9 explicitly requires null Console audit actor IDs, so named attribution requires a contract change rather than only an authentication patch.

## Decision

### Identity and authority

Introduce a **Console Identity** for a named human and a **Console Session** as a revocable authentication result for that identity.
A Console Identity is neither an API Client nor a Portal User, even when names or contact addresses match.
An API Client remains a non-interactive principal; a tenant-direct inference key continues to authenticate its Tenant.
Owner Contact and other descriptive metadata never convey authority.

Treat principal, credential, session, grant, action, resource, scope, and audit actor as distinct concepts.
RoleBindings are role grants to typed principals, and a versioned action policy maps existing roles to permitted operations and explicit cluster or Tenant scopes.
A resource's authoritative parent and privilege class constrain the grant; a submitted Workspace ID or UI filter cannot broaden it.
The Controller denies unknown actions and missing, stale, or mismatched authority.

Console, API, and CLI adapters construct a trusted caller context from their own supported authentication mechanism and invoke one Controller-owned operation boundary.
Admission to a page, route, socket, tool, or command is insufficient authorization for an operation.
Each protected read, preview, and mutation resolves current authority at action time.
After acquiring authority fences, the operation rereads credential/session validity, expiry and epoch, principal status, and current grants before authorizing.
At Console cutover, every non-migrated protected handler and data-delivery path must have an action-time cluster-admin guard or fail closed, including direct events and asynchronous updates.
Scoped identities cannot reach broader legacy authority merely because their session passed Console admission.
Console presentation does not mint or hold an administrator API Token to call the operation on a human's behalf.
Existing Admin and Operator API bearer admission remains intact; identical effective authority receives identical domain decisions, while narrower transport admission may still deny entry.

An agent operating an administrator's browser session has that administrator's authority.
A tool allowlist, hidden button, or agent label does not restrict the session.
Fine-grained agent delegation needs a separate authenticated, server-enforced grant design and is deferred with WebMCP implementation.

### Sessions and migration

Use named local password authentication and opaque, hashed, server-side Console Sessions with absolute and idle expiry, revocation, and an identity authentication epoch.
Identity disablement invalidates all that identity's sessions; individual session revocation invalidates only its target.
Password reset and identity reenablement are deferred; any future reset must invalidate all sessions rather than reuse setup authority implicitly.
Grant changes take effect through action-time policy resolution without relying on session renewal or LiveView remount.
Only successful authorized client operations in an explicit activity class refresh idle time, including explicit previews; background traffic and denied checks never do.
Session activity bookkeeping is the sole preview side-effect exception, cannot revive expired authority, and is not proof of human presence.

Prepare a named cluster administrator through an explicit operator-controlled setup before Console cutover.
A currently authorized cluster-admin API Client creates a `pending_setup` identity through `POST /admin/v1/console-identities`, explicitly requesting the initial cluster-admin grant without an implicit default.
The identity, initial grant, and audit commit together; no Console authority exists until redemption activates the identity.
`POST /admin/v1/console-identities/:id/setup-invitations` issues a 15-minute single-use invitation, and HTTPS `POST /console/setup` redeems it outside legacy Basic Auth admission.
The token never appears in an HTTP request path/query or logs, and retries never recover plaintext.
Each verifier binds the target identity UUID, setup purpose, captured authentication epoch, generation, and expiry; revoking its issuer after committed issuance does not cancel the target's invitation.
A deployment without an available admin credential first uses existing local `orchardctl cluster init --force-new-admin --yes --output <path>`, then calls those same authenticated APIs.
There is no new local identity setup/recovery bypass and no unauthenticated first-authority minting endpoint.
Subsequent provisioning accepts one explicit initial cluster admin/operator or exact-Tenant tenant-admin assignment; general grant editing remains deferred.
Identity disablement is a bounded cluster-admin prerequisite, while setup invitations cannot reset or enable an already activated or disabled identity.

Cutover is cluster-wide and refuses activation without a currently valid, unexpired, unrevoked Console Session for an enabled named cluster administrator and compatible evidence from every non-retired eligible Controller.
Activation revalidates that identity's current enabled state and cluster-admin grant rather than treating a historical login as current authority.
Successful-login evidence must match the identity's current authentication epoch.
Cutover invalidates all legacy Console markers and closes old LiveViews.
Shared Basic Auth and `auth: :none` cannot authorize production Console operations after cutover, and there is no automatic downgrade or parallel fallback.
Cutover uses durable `pre_cutover`, `named_active`, and `rollback_console_disabled` states plus a required Console-auth contract version and fresh Controller capability evidence.
Activation requires a persistent host/service launch gate and verified ingress fencing that exclude incompatible Console binaries, including direct HTTP listeners and the actual LiveView transport.
Compatibility includes every session, grant, credential, authority-fence, and audit writer, including retained direct-DB CLI entry points; stale Controller evidence blocks unless that instance has been explicitly retired.
Old software cannot interpret the new database state; rollback must block access, close sockets, and persist Console-disabled launch configuration before starting it.
Disabling Console alone does not isolate old API, CLI, Portal, or database writers; incompatible software must be stopped or isolated from the live post-cutover authority store before it runs.
An unenforceable isolation/rollback profile is unsupported, and an isolated older environment does not retain the COMPLETE family claim.
After compatible software and host/service/database/ingress isolation are verified, rollback may expose only restricted HTTPS setup redemption, named login/logout, and restoration preview/confirmation, with no legacy Console or general LiveView access.
This permits fresh setup/login when no valid session survives; provisioning still uses authenticated Admin API authority, and local recovery only mints the machine credential.
Activation and restoration use same-origin named-session operations at `/console/auth/activation` and `/console/auth/restoration`, outside Basic Auth and with CSRF, explicit state/version preconditions, and typed confirmation.
Restoration requires the acting named cluster admin's current valid session, epoch, and grant plus compatible deployment proof; `console_auth.access_restored` commits with policy state before general access opens, and failure keeps it closed.
Local recovery remains bounded to minting additional machine recovery authority, followed by ordinary authenticated named identity provisioning.
It cannot impersonate a human or become a general direct-Repo channel.

### Complete credential family

The first COMPLETE migration covers metadata list/inspect and explicit revoke for tenant-direct API Keys, API Client API Tokens, and Console Sessions.
It covers Console, authenticated Admin API, and portable CLI through one domain operation family, including every pre-existing entry point for those operations.
Credential creation, key rotation, API Client disablement, grant editing, and later management families require separate operation contracts; identity/session setup and termination are prerequisites for this family.

Cluster admins can manage the family across the cluster.
A Console Identity holding `tenant_admin` for a Tenant can manage only that Tenant's inference-only API Keys and API Client API Tokens.
Any API Client with cluster authority or authority outside that Tenant is protected from Tenant-admin inspection and revocation, regardless of its declared Tenant or a token's apparent intended use.
Classification conservatively includes retained owner-principal and key-specific grants, including Tenant grants for tenant-direct keys, even when credentials or owners are inactive.
It does not change inference authentication; grantless credentials with matching ownership remain eligible, and multiple Tenant-admin grants cannot combine into cross-Tenant target authority.
An `operator` receives no key-management permission merely from that role.
Console Identities may inspect and revoke their own Console Sessions; only cluster admins may manage another identity's sessions.
Existing Admin API admission continues to require a cluster-admin API Client, so this proposal does not silently expose a Tenant-admin bearer endpoint.
COMPLETE means parity for equivalent authority admitted by each surface; Tenant-admin machine/API/CLI admission remains deferred.

Authorization and mutation serialize against concurrent actor revocation, grant changes, target ownership or privilege changes, and target revocation.
The authoritative transaction is the linearization point: if revocation or a restrictive grant change commits first, a subsequent operation cannot succeed from a cached context.
If the operation commits first, revocation does not retroactively undo that committed effect.
Protected read/data delivery linearizes at server transmission admission under current authority; previously fetched but not yet admitted data must be revalidated, and already admitted bytes cannot be recalled.
Already admitted Public Inference requests keep their existing lifecycle; credential revocation blocks the next authentication and does not silently cancel an in-flight request.

Effective revocation and its audit row commit atomically; replay of an already-revoked target is a true no-op after current authorization succeeds.
Preview is domain-side-effect-free except for explicitly classified Console idle bookkeeping, binds the exact target and revision, and never grants execution authority.
Revocation requires explicit confirmation and a reason, with acknowledgement when ending the caller's own credential or session.
Every unrevoked target, including expired, disabled-owner, or epoch-invalid sessions, requires current revision equality; already-revoked retries waive only that equality check, never request shape or current authorization/scope.
No list, inspect, preview, response, audit row, or error reveals a reusable secret or verifier.

### Attribution and separate trust domains

Authenticated Console operations retain `actor_type = 'operator'` and use the stable Console Identity ID as non-null `actor_id`.
API and CLI operations retain the authenticated API Client actor; surface is provenance and cannot grant authority.
New top-level `actor_principal_type`, `actor_credential_type`, and `actor_credential_id` distinguish the human/API Client and its authenticating record from the target.
`payload_schema = 'credential_management.v1'` selects the closed management revoke payload while retaining `api_key.revoked` and its established target references for both API credential forms.
New Portal-origin audit events select `portal_lifecycle.v1` and retain their current closed payloads, including when the same Portal-minted key is otherwise manageable by an administrator.
Schema selection follows the executing operation, not key ownership; null discriminators identify unchanged legacy rows.
Session creation/logout and effective cutover/rollback/restoration receive explicit atomic lifecycle audit events, and retained authentication references are never nulled by credential/session cleanup.

Portal Users and Portal Sessions remain confined to Portal self-service under ADR 0020.
Disabling a Portal User ends its sessions but does not revoke minted inference keys.
Console identity disablement does not disable an API Client with matching contact metadata.
Node certificates, node-join Bootstrap Tokens, and Peer Grants retain their existing trust and transport roles and cannot authorize management user operations.
Host privileges and local recovery evidence are separate from ordinary remotely authenticated management authority.

## Alternatives and consequences

A shared Basic Auth username mapped to a synthetic administrator would preserve the original attribution and revocation defects and is rejected.
Reusing Portal Users or API Client Owner Contact as human operators would erase intentional trust boundaries and is rejected.
Checks only at HTTP plugs, LiveView mount, UI buttons, or client tool registration would leave stale sessions and alternate entry points unchecked and are rejected.
Independent per-surface policies would recreate drift and are rejected.
A new external policy engine is unnecessary for this bounded role/action model; Postgres remains the authority for persisted grants and revocation.

Named sessions add lifecycle, migration, and recovery work, but make individual revocation and attribution possible.
Serialized authority checks constrain concurrency and require shared lock ordering across mutation families.
The first family is complete only after its alternate paths are closed and parity and adversarial tests pass; OpenSpec structural validation is not evidence of that completion.

## SPEC.md impact

Reconciliation is required in §§2.3, 7.1, 7.3, 7.4, 7.4a, 8, 10.1, 10.4, 10.8, 10.9, 11.9, and 13.
The proposal's impact table identifies changed and preserved contracts.
ADRs 0002, 0004, 0007, 0011, and 0020 retain their machine-principal, transport-admission, bootstrap, and Portal boundaries.
This proposal refines ADR 0024's family migration and introduces first-class humans only for Console administration.
