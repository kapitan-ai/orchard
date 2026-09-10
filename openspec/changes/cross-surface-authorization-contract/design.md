## Context

This design is proposed and depends on acceptance of [ADR 0033](../../../docs/decisions/0033-cross-surface-authorization.md).
`OrchardConsole.Auth` currently trusts `_orchard_console_authenticated = true` on requests and LiveView mount or reconnect.
`Orchard.Governance.RoleBinding` currently has no Console Identity principal type.
`SPEC.md` §10.9 requires anonymous Console actors and closed per-action Portal audit payloads.
ADRs 0004, 0007, 0011, 0020, and 0024 constrain API admission, first-admin recovery, Portal independence, and Controller-owned operation migration.

## Goals / Non-Goals

**Goals:**

- Name human Console actors, give their sessions durable revocation, and authorize operations against current grants and target state.
- Share policy and domain enforcement across Console, API, and portable CLI while retaining explicit authentication audiences.
- Specify one complete credential inspection/revocation migration and its failure semantics before implementation.

**Non-Goals:**

- Implement runtime behavior in this proposal or declare existing operation families complete.
- Introduce SSO, arbitrary custom policy languages, delegated agent credentials, WebMCP tools, or automatic email delivery.
- Merge Portal Users, API Clients, Tenants, Node identities, or host-local authority into Console identities.
- Migrate all Console operations or all CLI commands at once.

## Decisions

### Vocabulary and trusted caller context

| Concept | Contract |
|---|---|
| Principal | Stable typed subject: Console Identity for human management, API Client for machine management, or existing audience-specific inference/Portal/Node subject. |
| Credential | Secret proof bound to a principal and authentication audience, such as password or API Token; never itself a role grant. |
| Session | Revocable server-side authentication result bound to one Console Identity and authentication epoch; cookie contains only an opaque bearer. |
| Grant | Persisted RoleBinding connecting a principal, role, and explicit cluster or Tenant scope; resolved into named actions by Controller policy. |
| Action | Closed operation identifier such as `credential.inspect` or `credential.revoke`; unknown identifiers deny. |
| Resource | Typed target with server-resolved ownership and privilege class; IDs supplied by the client are lookup candidates only. |
| Scope | `cluster` or one exact Tenant UUID; Workspace is display vocabulary and creates no new hierarchy. |
| Audit actor | Stable identity that actually exercised authority, plus non-secret authentication-record reference and surface provenance; never a client-submitted identity. |

The server derives a caller context from Console session authentication or the existing API Client bearer admission boundary.
Clients cannot submit role lists, actor IDs, grants, or a local-recovery marker to create authority.
Sessions do not cache authoritative role grants.
Console identities use their own role grants directly inside Controller operations and do not acquire machine credentials behind the UI.
Existing `/admin/v1` and `/ops/v1` authentication audiences remain API Client-only with their current cluster role requirements.
A Console cookie is not an API or inference credential, and an API Token is not a Console login.

### Named authentication and session lifecycle

A Console Identity has a stable UUID, unique normalized login name, `pending_setup | enabled | disabled` state, password verifier only after setup, and authentication epoch.
Choose local named password login for the first slice, reusing the repository's vetted password hashing and generic credential-failure patterns without sharing Portal identity records or sessions.
No public signup is provided.
Setup activates only pending identities; password reset and reenablement are deferred and must never be inferred from an invitation request.
Disablement invalidates outstanding invitations and every standing session under the identity fence.

Each session has an independent random bearer whose hash is persisted with identity ID, captured authentication epoch, creation time, last activity, absolute expiry, and revocation state.
Use a 12-hour absolute lifetime and a 30-minute idle lifetime; activity cannot extend absolute expiry.
Using Controller time, expiry occurs when `now >= min(created_at + 12 hours, last_activity_at + 30 minutes)`.
Only successful authorized client-initiated operations in the server-owned activity class advance activity monotonically, including explicit credential list, inspect, and revoke-preview requests.
Heartbeats, automatic refreshes, background polling, subscriptions, asynchronous deliveries, and denied checks never touch activity.
An eligible touch revalidates under the session protocol and cannot revive expired, revoked, or epoch-invalid authority; delayed completion after expiry cannot touch or publish a fresh protected result.
An explicit preview may perform only this authentication-session bookkeeping in addition to its domain-side-effect-free read; it creates no domain mutation or audit success.
The classification identifies protocol actions, not a human gesture; an agent using the session can invoke the same eligible actions.
Successful login rotates the cookie and session record rather than upgrading an existing anonymous marker.
Use a distinct Console cookie with Secure, HttpOnly, SameSite=Lax, appropriate path scoping, CSRF protection for browser writes, and origin validation for LiveView connections.
Production named Console login requires effective HTTPS under the configured trusted-proxy contract; degraded `plain_http_localhost` does not serve it.
Any source-development authentication fixture must remain explicitly non-production and cannot enable a production authorization bypass.
Login failures have generic responses and bounded rate limiting by login and source fingerprints without identity enumeration or a cluster-wide lockout.
Logout revokes the server-side session and clears the cookie.
Revocation notifications may close connected LiveViews promptly, but fresh checks provide the security guarantee even if notification is lost.
Named `GET /console/login`, `POST /console/session`, and `POST /console/logout` are available on the restricted preparation surface before cutover outside Basic Auth; those sessions authorize preparation operations only until named activation opens general Console access.

### Authenticated setup and recovery carriers

The setup APIs are available before Console cutover under existing cluster-admin API Client admission and the active Controller's operation/fence/audit boundary.
They accept a nonempty reason of at most 512 Unicode characters and explicit `confirmed: true`; no reason is echoed in denial diagnostics.
`POST /admin/v1/console-identities` accepts exactly `login_name`, `initial_access`, `reason`, `confirmed`, and UUID `idempotency_key`.
`initial_access` contains exactly `role` and `tenant_id`: cluster `admin` or `operator` requires null Tenant, and `tenant_admin` requires one existing exact Tenant UUID.
The first identity requires explicitly supplied cluster `admin`, with no implicit default; scoped/operator creation is allowed only after a currently enabled named cluster admin exists.
Creation serializes the first-admin guard, persists `pending_setup` identity, initial grant, and cluster audit atomically, and returns only identity ID, state, revision, and initial assignment.
Retry with the same authenticated principal, idempotency key, and canonical inputs returns that original non-secret result after current authorization; different inputs return `conflict`.
The non-secret idempotency record is retained with the identity, and duplicate normalized login under a different key returns `conflict` without creating another identity.
`GET /admin/v1/console-identities/:id` and the equivalent named cluster-admin Console operation return exactly `{data: {identity_id, state, revision}}` under current cluster-admin authorization, active Controller/storage requirements, and `Cache-Control: no-store`.
The projection never contains a password, invitation secret/verifier, or authentication material.
Identity revision is a monotonic generation initialized to `1` at creation and advanced once per effective invitation issue/replacement, redemption, disablement, or grant change in the same authoritative transaction.
Repeated no-ops, idempotency replay, failed attempts, inspection, login/session activity, and passive invitation expiry do not advance it; expiry is still checked independently at action time.
Creation/issuance retries retain their original result and do not refresh revision; after a conflict or another administrator's change, obtain current state through this read before a separately confirmed mutation retry.
A recovered administrator using a different API Client uses current inspection rather than another principal's idempotency record.

`POST /admin/v1/console-identities/:id/setup-invitations` accepts exactly `expected_revision`, `replace`, `reason`, `confirmed`, and UUID `idempotency_key`.
It accepts only `pending_setup` identities, locks the identity before invitation state, generates a fresh independent random verifier, and stores only its hash, identity ID, generation, and expiry exactly 15 minutes after issuance.
The invitation also binds purpose `console_identity_setup` and the target's captured authentication epoch; redemption must match every bound field.
Issuer identity/credential is audit provenance: its revocation after committed issuance does not invalidate the invitation, whose termination is controlled by target state/epoch, replacement, consumption, and expiry.
An existing unconsumed invitation requires `replace: true`, a fresh idempotency key, current revision, and explicit confirmation; replacement invalidates the old generation atomically.
The first committed response returns `{data: {identity_id, revision, invitation_generation, expires_at, delivery: "issued", setup_token}}` once with `Cache-Control: no-store`.
A same-key retry returns only the original non-secret fields with `delivery: "already_issued"`; it never returns a token and cannot create a second invitation.
A lost one-time result requires explicit replacement, and a stale revision or reused key with changed inputs returns `conflict`.
No secret is persisted in retry records or emitted in ordinary summaries, logs, audit, or diagnostics; intended HTTPS one-time delivery is the sole exception to metadata-only results.

Static `GET /console/setup` and CSRF-protected HTTPS `POST /console/setup` are outside legacy Basic Auth admission.
A delivery link may put the verifier in a fragment, never an HTTP path/query; the page clears the fragment before instrumentation or LiveView connection, uses no third-party scripts, and sends `Referrer-Policy: no-referrer` and `Cache-Control: no-store`.
The operator delivers the one-time token through a protected channel; POST sends the token and chosen password in a log-excluded body.
GET never consumes authority.
POST atomically validates the current pending identity, invitation generation, unexpired unused verifier, consumes it, sets the password, enables the identity, increments its authentication epoch, and commits cluster audit.
It returns only setup completion and requires a fresh ordinary Console login; the verifier never becomes a session or authorizes any other action.
Unknown, expired, replaced, replayed, disabled, and wrong-state redemption have one generic failure with no mutation, and concurrent redemption permits one commit only.

`POST /admin/v1/console-identities/:id/disable` accepts `expected_revision`, `reason`, and `confirmed`; it disables pending/enabled identities and ends sessions/invitations atomically, while an already-disabled target is an authorized true no-op.
Named cluster-admin Console callers use the same creation, invitation, and disable operations after cutover; these are narrow prerequisites, not a claim of complete general identity/grant administration.
Their actions are `console_identity.created`, `console_identity.setup_issued`, `console_identity.setup_replaced`, `console_identity.setup_redeemed`, and `console_identity.disabled`, with exact audit payloads specified below.
When machine administrator authority is unavailable, recovery remains `orchardctl cluster init --force-new-admin --yes --output <path>`, followed by these ordinary authenticated APIs to provision an additional named admin.
If recovery credential publication fails, first obtain another usable administrator credential through that existing recovery path before attempting authenticated revocation of a stranded token; failed delivery is not authority to bypass authentication.
Preserve the reported credential-authority/publication/containment outcomes and do not automatically retry minting or publication.
With another usable admin credential, resolve the exact reported stored `token_prefix` through metadata-only family listing, identify its returned kind/UUID, then explicitly preview and revoke with current revision and confirmation.
Do not treat failed publication as rollback or guess a target from a partial prefix.
No local identity-recovery command or unauthenticated first-authority minting endpoint is added, and existing identities need not be reset or reenabled to recover.

### Activation and restoration carriers

Activation uses `GET/POST /console/auth/activation`, and restoration uses `GET/POST /console/auth/restoration`, as same-origin HTTPS controller/form routes outside Basic Auth and without general LiveView transport.
GET renders only the authenticated preparation form/current policy state; POST uses the acting named cluster-admin Console Session, normal CSRF/rate-limit/fence/audit rules, and does not accept API Bearer or another session's UUID as authority.
The exact POST body is `dry_run`, `expected_state`, `expected_contract_version`, `confirmed`, and `typed_confirmation`.
Preview uses `dry_run: true` and expected state/version; execution additionally requires `confirmed: true` and literal `ACTIVATE NAMED CONSOLE` or `RESTORE NAMED CONSOLE` respectively.
Activation requires expected state `pre_cutover`; restoration requires `rollback_console_disabled`; stale state/version returns `conflict`, with no silent refresh.
Preview returns the shared `{data: {status: "preview", state, required_contract_version, blockers, warnings, consequence_codes, confirmation_requirements}}` envelope without domain/policy/audit mutation, and execution returns `{data: {state, required_contract_version}}` only after the policy/audit transaction commits.
The acting session itself supplies the live current-epoch enabled-admin proof under identity/session fences; no additional API Client session-reference carrier is introduced.

During rollback, only after compatible software and host/service/database/ingress isolation are verified may a restricted HTTPS preparation surface expose `/console/setup`, named login/logout, and restoration form/preview/confirmation plus their minimal static assets.
Every other Console route and general LiveView handshake/transport remains blocked, including Basic Auth and legacy markers.
If all sessions expired, an operator may log in again or obtain machine authority through existing local recovery, provision/invite through the authenticated Admin API, redeem the new pending identity, and perform fresh named login on this restricted surface.
Restoration revalidates the acting named administrator's current session/epoch/grant and full deployment compatibility, commits `console_auth.access_restored` atomically with `named_active`, and only then enables general Console access.
Validation, authentication, audit, or enablement failure keeps general access closed; a committed policy with unconfirmed external enablement is not reported as restored access and must be reconciled through verified compatible deployment controls.

### Shared operation boundary and concurrency

For each operation, authenticate the current credential/session, resolve the typed principal, acquire authority fences, resolve current grants and resource ownership, authorize the action, validate preconditions, perform the effect, and commit its required audit row.
Initial authentication identifies candidate authority only; after acquiring fences, reread principal status, credential/session revocation and expiry, session idle/absolute expiry and captured epoch, and grants before authorizing.
Protected list/inspect and preview read consistent authoritative data and use the same policy; a page render or previous preview is never authorization for another call.
Disconnected LiveView renders contain no protected data.
Connected events, parameter changes, refreshes, asynchronous completions, and subscription deliveries must recheck before exposing newly fetched protected data or performing a mutation.
Protected data linearizes at admission to the server's HTTP/socket transmission queue under current authority and its serialization protocol, not at an earlier fetch or application callback.
Data fetched before a restrictive change but not yet admitted for transmission must be revalidated and suppressed if authority is lost; already admitted bytes cannot be recalled even if the client receives them later.
The single bounded acknowledgement of a committed mutation, including self-revocation, remains deliverable under that transaction's authorization without another protected read.
Before named Console cutover, inventory all reachable handlers and protected data paths, including non-migrated families.
Each non-migrated path must enforce a fresh server-side cluster-admin guard or fail closed, so Tenant-admin, operator-only, and roleless sessions cannot inherit legacy full-Console authority.
This transitional guard includes events, routes, parameter changes, asynchronous results, and subscriptions; hidden navigation is insufficient.

All principal disablement, credential/session revocation, grant mutation, target privilege changes, and protected operations must participate in a common transaction protocol.
Use transaction-scoped authority fences acquired in deterministic typed-principal UUID order, then credential/session and resource rows in deterministic typed-ID order.
Fences are keyed independently of grant-row existence by a fixed principal-type ordinal and UUID; batch writers acquire the complete affected set in sorted order before any mutation.
Grant mutations lock the affected principal's authority fence even when adding a previously absent RoleBinding.
Existing grant, credential, identity, and API Client mutation paths must join this protocol even when their operation family is not otherwise migrated.
API Client target grants and ownership participate in the same fence as credential inspection/revocation, so a concurrent cluster grant cannot turn a Tenant-admin operation into cluster credential control.
Self-revocation deduplicates actor and target fences.
The implementation must prove the lock order and absence of bypasses rather than relying only on transaction isolation or authentication plug timing.

An effective mutation linearizes at its authoritative transaction; protected read/data delivery linearizes at server transmission admission as defined above.
A restrictive authority change committed first denies the operation; an operation committed first is not undone retroactively.
Revocation takes effect on the next authentication or operation boundary, including a stale LiveView event and a request already admitted by an API plug but not yet authorized by the domain operation.
This does not change cancellation semantics for already admitted Public Inference work.

### Retained authority-writer ledger

Every writer below remains in the cutover compatibility and fence/audit closure ledger even when its larger command family is not COMPLETE.
No standalone management revoke may survive outside the credential operation or the explicitly retained Portal self-service operation.

| Writer | Required authority/fences and audit | Completion disposition |
|---|---|---|
| Console/API/CLI credential revoke, including old aliases and governance overloads | Current caller plus every consulted owner/key namespace, target row, and atomic `credential_management.v1` event. | Delegate to the complete family; remove direct-Repo standalone revoke. |
| Portal own-key mint/revoke | Current Portal session/epoch, Portal User fence and row before key row, plus affected credential namespace; retain narrower ownership policy and `portal_lifecycle.v1` audit. | Retained explicit self-service operation, with common serialization participation proven. |
| Portal invitation/redeem/disable and Portal logout/epoch writers | Portal or authorized management context, Portal User/session fences, existing row order and defined lifecycle audit; logout may omit mutation audit under its existing contract but still invalidates authority atomically. | Retained Portal family, never exempt from writer compatibility because Console is disabled. |
| Console login/logout/session revoke/identity disable/setup | Identity/session/invitation fences and epoch revalidation, with explicit Console lifecycle or management audit. | Required named-auth prerequisites; no parallel unfenced session termination path. |
| API Client disable, grant edits, initial grants, bulk provisioning and rotation | Full sorted owner/key/affected-principal fence set before changes, including absent grants; preserve existing batch, rotation, and effective-mutation audit contracts. | Larger families deferred, but authority-affecting writes must be compatible before cutover. |
| `cluster init` including forced recovery and any retained local Controller-runtime CLI authority | Existing narrowly authorized recovery/command boundary, common applicable fences, leader gate, and existing atomic audit/protected publication contract. | Inventory and version-gate every direct-DB entry point; no old writer may attach to the post-cutover store. |

Passive activity/expiry maintenance also participates where it can affect session validity and cannot revive or bypass authority; unchanged read-only tooling does not gain write authority from this ledger.

### First COMPLETE family

The family includes list, inspect, preview revoke, and revoke for `api_key`, `api_token`, and `console_session` targets.
Creating or rotating inference credentials, disabling API Clients, editing grants, or administering Portal identities is outside this operation migration.
Named identity setup, login, logout, disablement, and session invalidation are security prerequisites with direct tests; password reset, reenablement, and general grant editing remain deferred.
Existing Portal self-service key actions retain their narrower Portal-owned-key boundary and transaction ordering.
Console/API/CLI credential paths must not bypass it by accepting a Portal session as a management caller.

| Caller authority | Keys and tokens | Console Sessions |
|---|---|---|
| Cluster `admin` Console Identity or admitted cluster-admin API Client | All management-family metadata and revoke operations. | All session metadata and revoke operations. |
| Console Identity with exact-Tenant `tenant_admin` | Only inference-only credentials whose entire effective target authority is within that Tenant. | Own sessions only. |
| Console Identity with `operator` or no management grant | No inference-key management through this family. | Own sessions only while the identity/session remains valid. |
| API Client without Admin API cluster-admin admission | Existing transport denial; no new Tenant-admin endpoint. | No new transport access. |
| Portal User, inference-only credential, Node certificate, Bootstrap Token, Peer Grant | No management-family admission. | No management-family admission. |

For a tenant-direct key, including Portal-owned and legacy unowned Portal keys, management classification examines the union of current Tenant-principal and key-specific RoleBindings.
For an API Token it examines API Client-principal and key-specific RoleBindings.
Every binding in that union must be `inference_client` scoped to the authoritative Tenant for Tenant-admin eligibility; zero bindings are eligible when ownership matches.
Any retained cluster, foreign-Tenant, or non-inference binding disqualifies the target even when the owner is disabled or the credential expired/revoked.
Every consulted principal/key namespace is fenced, including insertion of previously absent bindings.
This conservative management classification does not change the existing inference principal or grant presently unsupported bearer authority.
The COMPLETE claim covers equivalent effective authority admitted by each surface; Tenant-admin machine/API/CLI admission remains deferred and is not part of that parity claim.
Caller grants are additive, but multiple Tenant-admin grants cannot combine into permission over one cross-Tenant or privileged target.
Until other families migrate, scoped Console identities see only their supported credential/session operations with an honest explanation of available access.
Out-of-scope inspect/revoke targets return the same `not_found` result as missing targets, and list pagination, counts, and filters never expose excluded resources.
Target scope is checked before revision handling: scope lost after preview returns `not_found`, while `conflict` is reserved for still-visible authorized targets.

Proposed new Admin API routes are `GET /admin/v1/credentials`, `GET /admin/v1/credentials/:kind/:id`, and `POST /admin/v1/credentials/:kind/:id/revoke`.
`SPEC.md` lists `GET /admin/v1/api-keys` and `POST /admin/v1/api-keys/:key_id/revoke`, but neither is wired at this baseline; implement both as thin delegates with the family envelope and execution gates, never independent authority.
Actual baseline paths are `TenantDetailLive` key list/revoke, `orchardctl api-keys revoke` through `RepoRuntime` and unscoped `Governance.revoke_api_key/2`, the scoped governance overload, Portal own-key revoke, and bulk rotation's multi-key revoke.
Console paths delegate to family authority; the old CLI revoke becomes a portable alias that resolves persisted key kind server-side under the same policy, and unscoped direct revoke becomes internal to the operation or is removed.
Portal retains its own narrower operation, and rotation/creation remain separate families whose auth mutations nevertheless join the common fences.
Portable commands are `orchardctl credentials list`, `orchardctl credentials inspect <kind> <id>`, and `orchardctl credentials revoke <kind> <id>` with stable human/JSON presenters.
Console credential lists and revoke actions invoke the identical operation.
List is cursor-paginated with default 50 and maximum 100 items; filtering precedes pagination and counts.
Public kinds are exactly `api_key`, `api_token`, and `console_session`; a supported wrong kind for an existing UUID is hidden `not_found`, while an unsupported kind is invalid input.
List filters are exactly optional `kind`, `tenant_id`, `owner_type`, `owner_id`, `token_prefix`, `status`, `limit`, and `cursor`; owner type/ID are supplied together, and unknown filters are rejected.
`token_prefix` matches only the complete persisted non-secret prefix for either API credential form, never substring or secret material, and supports authenticated failed-publication recovery.
`status` is one of `active`, `expired`, `revoked`, `owner_disabled`, or `epoch_invalid`; projection gives revocation precedence, then expiry, owner disablement, session epoch mismatch, and active, without changing privilege classification.
Ordering is ascending `(created_at, kind, id)` with kind order `api_key`, `api_token`, `console_session`; the opaque integrity-protected cursor binds actor, normalized filters, and last sort tuple without embedding secret values.
Each page reauthorizes current scope and reads current state after the last tuple, without a snapshot or stable-total guarantee; removed access disappears, and newly inserted earlier tuples require a new traversal.
Changed actor/filters or malformed cursor returns invalid input rather than silently restarting; responses include no total count.

### Credential carrier envelope

All credential/setup successes use `{data: ...}`; family errors use `{error: {code, message}}` with bounded generic messages and no target metadata on hidden-target errors.
List data is `{items, next_cursor}`; inspect data is the closed metadata object; revoke data is `{status: "revoked" | "already_revoked", credential}`.
Preview data is `{status: "preview", target: {kind, id, revision}, blockers, warnings, consequence_codes, confirmation_requirements}` using the shared Action Preview presenter.
The revoke JSON body accepts exactly `dry_run`, `expected_revision`, `reason`, `confirmed`, and `acknowledge_self_revocation`; preview needs only `dry_run: true`, while execution requires the revision, reason, and confirmation.
The CLI exposes `--dry-run`, `--expected-revision`, `--reason`, `--yes`, `--acknowledge-self-revocation`, and `--json`, with list flags matching the allowed filters and no hidden automatic preview/revision substitution.
Every portable call explicitly selects `--controller <https-origin>` and `--token-file <path>` containing one API Token in an owner-only regular file; no token argument, local Repo, release evaluation, or implicit host fallback is supported.
Controller TLS verification is mandatory, credentials are never forwarded on redirects, and callers explicitly select another Controller after a non-Active refusal.
JSON output preserves the HTTP envelope without secrets; human output presents the same target, revision, consequences, and outcomes.

Metadata uses a closed projection: target kind and UUID, non-secret display name or token prefix when applicable, typed owner ID, Tenant scope, created/expiry/revoked timestamps, effective status, and a non-secret revision.
A Console Session projection adds creation/last-activity timestamps and whether it is the caller's current session; its record UUID is distinct from its bearer.
The non-secret revision is an opaque encoding of a monotonic target generation and the relevant authority-namespace generations; changes affecting revocation consequences advance it, while passive token use/session activity does not.
Authority and ownership are still reread under fences; a revision alone never proves current authorization.
No response includes password hashes, token/session/invite hashes, cookies, secret suffixes, raw request metadata, or recoverable credentials.
Responses and Console pages containing this metadata use `Cache-Control: no-store`.

Revoke preview uses `dry_run: true` or CLI `--dry-run` and returns the exact kind/ID, target revision, warnings, consequence codes, blockers, and confirmation requirements without domain mutation or audit persistence, apart from eligible Console idle bookkeeping.
Execution requires the same target and `expected_revision`, a reason of 1-512 Unicode characters after trimming, and explicit confirmation (`confirmed: true` or CLI `--yes`).
Console displays the target and consequences before confirmation.
Revoking the current API Token or Console Session additionally requires `acknowledge_self_revocation`; success ends subsequent authority without suppressing the already-committed response.
Self-revocation, including the last working credential, is permitted after acknowledgement because the separately authenticated local recovery path remains available.
No caller may revoke a target it cannot currently inspect and revoke under this policy.

For an authorized already-revoked target, return `already_revoked` with its unchanged revision/timestamps and no additional successful audit row, including retries with the pre-revocation revision.
This waives only revision equality: the request must still contain a well-formed revision, reason, confirmation and required acknowledgements, and pass current caller authentication, scope, and kind checks.
For an unrevoked, still-in-scope target whose revision changed since preview, return `conflict` without effect and require a fresh preview.
Every unrevoked target, including expired credentials, disabled-owner credentials, and epoch-invalid sessions, requires current revision equality and remains inspectable/revocable by a valid caller under retained privilege classification; an expired actor fails authentication.
A first revoke sets revocation state once and returns `revoked` with the committed revision.
Both paths first validate current caller authority, so a successfully self-revoked caller cannot replay with its now-invalid credential.
The natural kind/ID target and terminal revoked state provide retry idempotency; no secret-bearing replay cache is required.

### Leadership, failures, and audit

Family reads, previews, and writes execute on the active Controller against available authoritative Postgres state.
This intentionally makes the family unavailable on Standby or without authoritative storage rather than serving cached credential metadata.
Standby returns a stable `not_active_controller` refusal; unavailable authority returns `authority_unavailable` without cached success or fallback to local Repo access.
HTTP adapters map these to retryable `503`, authentication failures to `401`, scope-hidden targets to `404`, forbidden actions to `403`, stale revisions to `409`, and invalid confirmation/input to `422`.
CLI JSON preserves domain codes and exits nonzero on refusal; Console presents the same outcome without claiming completion.
A lost response after commit is an unknown client outcome and is resolved by an authorized inspect or retry against the same target.

Effective revoke and successful audit persistence share the outer transaction; audit failure rolls back the mutation.
Tenant-direct API Key and API Client API Token revocation both preserve `api_key.revoked`, `target_type = 'api_key'`, and the existing `api_key_id` reference because both forms use the persisted API Key representation.
The closed `credential_kind` field distinguishes their product forms without renaming existing audit actions or breaking action-domain telemetry.
Console Session revocation uses `console_session.revoked` with `target_type = 'console_session'` and an explicitly added Console-session telemetry mapping.
Session events and API credentials of either form with any cluster, cross-Tenant, or non-inference binding use `scope = 'cluster'` and null `tenant_id`, even when an owner has a Tenant field or is disabled.
Inference-only keys/tokens wholly contained in one Tenant use that exact Tenant audit scope.
Add nullable top-level `payload_schema`, `actor_principal_type`, `actor_credential_type`, and `actor_credential_id`; historical nulls mean legacy decoding, never inferred modern attribution, and append-only rows are not backfilled.
New management revokes require `payload_schema = 'credential_management.v1'`, `actor_type = 'operator'`, and `actor_id` equal to the actual authenticated principal UUID.
Console uses `actor_principal_type = 'console_identity'`, `actor_credential_type = 'console_session'`, and its persisted session record UUID; API calls use `service_account`, `api_key`, and the authenticating API Key UUID.
The target `api_key_id` remains the revoked key, never the caller's credential; these typed authentication fields distinguish the two.
Session targets always have null `api_key_id`, and later identity/credential/session cleanup must neither null nor rewrite historical actor/target references; use retained stable audit identifiers without destructive foreign-key cascading.
Server-known `surface` is `console` or `admin_api`; a portable CLI's HTTP call is audited as `admin_api`, because a client header cannot prove official CLI provenance or alter authority.

For `credential_management.v1` API credential revokes, the closed required payload is exactly `name`, `token_prefix`, `owner_type`, `surface`, `credential_kind`, `reason`, `previous_revision`, and `revision`.
It additionally includes only `service_account_id`, `expires_at`, `issuance_surface`, and `portal_user_id` when their corresponding persisted values exist, preserving existing metadata while adding explicit management context.
For `console_session.revoked` under that schema, the closed payload is exactly `surface`, `credential_kind`, `reason`, `previous_revision`, and `revision`.
Selection follows the executing management operation even when its target key was minted through Portal.
New Portal lifecycle/self-service audit rows use `payload_schema = 'portal_lifecycle.v1'` and preserve their existing exact per-action payloads; Console-originated Portal administration gets named actor fields without altering those payloads.
Portal-origin rows retain `actor_type = 'user'`, Portal User `actor_id`, and `actor_principal_type = 'portal_user'`; non-management authentication references may remain null until their own typed migration, without inferring authority from that null.
Existing null-discriminator rows retain their original decoding, and consumers dispatch by explicit schema plus action instead of guessing from key ownership.

Named setup/disable audit uses `payload_schema = 'console_identity.v1'`, cluster scope, target type `console_identity`, and the named/API caller's typed authentication references.
Its exact payloads are: creation `{surface, reason, initial_access}`, invitation issue/replacement `{surface, reason, invitation_generation, expires_at}`, redemption `{surface}`, and disablement `{surface, reason}`.
Redemption uses `actor_type = 'operator'`, the setup target's Console Identity UUID, `actor_principal_type = 'console_identity'`, and `actor_credential_type = 'console_setup_invitation'` with its non-secret persisted invitation UUID; `surface = 'console_setup'` grants no additional authority.
Local recovery retains its distinct existing actor/protected-output contract and can be typed `local_recovery` with no invented human or credential UUID; system and legacy/non-management rows may retain null authentication fields.
New `console_identity.*` and `console_session.*` actions receive explicit action-domain telemetry mappings.
Session creation uses `console_session.created`, logout uses `console_session.logged_out`, both with `payload_schema = 'console_session_lifecycle.v1'`, exact payload `{surface}`, cluster scope, target type `console_session`, and null `api_key_id`.
Their actor is the Console Identity with its session record as the non-secret authentication reference; creation persists the session and audit before publishing the cookie, and effective logout atomically revokes it and audits once without duplicate no-op events.
Effective policy transitions use `console_auth.cutover_activated`, `console_auth.rollback_disabled`, and `console_auth.access_restored` with `payload_schema = 'console_auth_lifecycle.v1'`, cluster scope, target type `console_auth_policy`, target ID `cluster`, and exact payload `{surface, previous_state, state, required_contract_version}`.
They persist atomically with the durable policy transition and actual authorized actor, with an explicit `console_auth` telemetry mapping; failure to persist activation/restoration audit denies service enablement, while external safety fencing may remain closed on a failed rollback transaction without claiming transition success.
True no-ops, denied calls, and previews produce no successful mutation audit row or success telemetry.
Protected reads and denied actions use bounded security telemetry with explicit outcome, not fabricated mutation audit successes.
Success telemetry is emitted only after commit.
All Console actions migrated to named authentication use stable named actors, including existing Portal administration actions.
Amend §10.9's null actor rule and apply these discriminator-specific allowlists before accepting implementation; historic anonymous records stay unchanged.
Reasons are bounded operator input and absent from denial diagnostics; audit validation rejects secret-bearing fields and retains the repository's redaction rules.

## Risks / Trade-offs

- Cutover can lock out operators if named setup is incomplete; require successful named login and verified local recovery before activation.
- Incompatible Controllers or direct-DB CLI writers could mutate live authority even with Console disabled; require whole-writer compatibility and isolate incompatible software from the post-cutover store.
- Shared authority fences may serialize busy administration; use narrow principal/resource fences and prove lock order and race behavior before optimizing.
- A broad browser session remains broad agent authority; defer delegation and never claim a UI or tool allowlist provides isolation.
- Existing direct domain callers can bypass a new facade; family completion requires a searched inventory, removal or delegation of alternate entry points, and negative tests at the domain boundary.
- New actor fields can violate closed audit schemas; reconcile each affected schema and regression test instead of blanket payload expansion.

## Migration Plan

1. Accept the contract and reconcile the precise `SPEC.md` sections and ADR status before implementing changed behavior.
2. Add backward-compatible identity/session and actor-context persistence, keeping existing inference credentials and historical audit rows unchanged.
3. Implement and test shared authority fences, named setup/login/session lifecycle, and the complete credential family while production cutover remains disabled.
4. Use an existing cluster-admin API credential for explicit named setup, or invoke local `cluster init --force-new-admin` recovery when none is usable, preserving protected one-time output.
5. Deliver the expiring setup invitation through a protected one-time result; never seed an identity/password from Basic Auth configuration, installers, or environment.
6. Establish persistent launch, ingress, and database-access gates before activating the durable singleton from `pre_cutover` to `named_active`, with `required_console_auth_contract_version` covering action-policy version and all session/grant/fence/audit writers, plus fresh support evidence from every non-retired eligible Controller including Standby and disconnected instances that may return.
   Stale, missing, or expired evidence blocks until refreshed or the instance is explicitly retired and isolated; inventory/version-gate retained direct-DB CLI writers too.
   The cluster-admin activation operation requires preview, typed confirmation, expected contract version, and a currently live unexpired/unrevoked Console Session for an enabled named cluster admin, with current epoch and grants revalidated under identity/session fences; historical login evidence alone is insufficient.
7. The launch gate rejects incompatible authority writers before execution, and cutover-aware Controllers refuse authority access if their contract is below the recorded requirement.
   Ingress enforcement covers direct backend HTTP access and the actual Console LiveView handshake/transport, closes old sockets, and blocks the whole affected listener when it cannot distinguish Console transport safely.
   Invalidate old markers, deny Basic Auth and production `:none`, and close every alternate credential-family path before declaring COMPLETE.
8. Before starting any pre-cutover binary, transition to `rollback_console_disabled`, block Console HTTP/LiveView access, terminate existing sockets, and persist Console-disabled service launch configuration plus direct-listener fencing.
   Old binaries cannot enforce the database marker; stop them or isolate all their API/CLI/Portal/session writers from the live post-cutover authority database before execution, in addition to Console ingress fencing.
   Disabling Console alone is insufficient, and downgrade is unsupported if database isolation cannot be verified; an isolated historical environment does not retain the COMPLETE family claim.
9. After compatible software and host/service/database/ingress isolation are verified, enable only the restricted setup/login/logout/restoration routes described above, so absence of a surviving session does not deadlock recovery.
   Restoration requires the acting named admin's fresh valid session/epoch/grant and compatible deployment proof; commit the policy and `console_auth.access_restored` before enabling general access.
   Neither software rollback nor configuration restoration may erase the durable cutover decision, and any failed verification or enablement keeps general Console/LiveView closed across restart/failover.

## Open Questions

No policy or scope decision is delegated to implementation by this proposal.
Implementation review must verify the concrete database lock mechanism, password-verifier parameters, transport compatibility, and mixed-version rollout evidence before acceptance.
Those details may refine implementation but cannot relax the authority, recovery, or completion requirements here.
