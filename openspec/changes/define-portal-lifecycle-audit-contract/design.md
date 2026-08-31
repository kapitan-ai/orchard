## Context

PR #300 reconciled the accepted Portal lifecycle with shipped behavior.
Portal User creation persists only an `invited` identity.
The first Copy invite action issues the initial invite, later Copy actions reissue through the same path, and the single hash-only invite row is deleted and replaced without retained invalidation history.
Redemption is invited-only, Organization-bound, and uses `POST /portal/:organization_slug/invites/:token`.
Initial issuance, reissue, redemption, and disablement end the target Portal User's sessions, while existing API Keys remain valid until explicit revocation.

`SPEC.md` section 10.9 nevertheless requires audit evidence for Portal invitation, reissue, redemption, disablement, and API Key creation and revocation.
The current Portal governance functions use direct `Repo` transactions and do not insert those rows.
The ordinary governance paths already provide an atomic audit transaction and post-commit success telemetry seam through `AuditWriter.transaction/1`.

The current metrics implementation recognizes eleven bounded audit action domains, while the accepted metrics worksheet and descriptor ceiling still reserve only 24 audit series from an earlier eight-domain snapshot.
The implementation catalog also includes 229 attempt and retry series that the accepted metrics contract still assigns to issue #121 and excludes from its 2,588-series worksheet.
This proposal adds only the `portal_user` audit domain and makes the accepted future target explicit at twelve domains and three outcomes.
It does not adopt the separate attempt and retry metric families into the accepted contract.
The archived metrics design remains historical and is not rewritten.

## Decision Status

The six choices below are recommendations presented for owner review.
Merging or accepting the proposal is the act that approves them.
Until then, the shipped lifecycle remains authoritative and no implementation should infer these choices from issue #279.

| Decision frontier | Recommendation | Evidence and trade-off |
|---|---|---|
| Separate creation and first issuance | Use `portal_user.invited` and `portal_user.invite_issued` | PR #300 defines separate mutations that may occur far apart and have different secret and session effects. |
| Successful redemption actor | Use `actor_type = "user"` and the Portal User ID | A successful locked redemption identifies the exact Portal User, but this is provenance only and grants no new Portal or Bearer authority. `system` plus null would lose that attribution. |
| Committed row versus persisted outcome | Persist only committed effective mutations and no outcome field | The existing schema has no outcome column, and a committed append-only row already represents success. Telemetry remains the bounded outcome projection. |
| Repeat and no-op transitions | Do not mutate or write another success row | This matches ordinary API Key revoke precedent and prevents audit inflation. Copy invite is never a no-op because it always creates a fresh secret and expiry. |
| Shared Console operator identity | Use `operator`, null actor ID, and `surface = "console"` | Current Console authentication establishes no first-class named operator, and `SPEC.md` explicitly permits null actor ID for this boundary. |
| Bounded metadata | Allow only per-action keys and omit `previous_invite_existed` | `surface` and `expires_at` are useful non-secret context. The action name already records issued versus reissued, so persisting a second classifier creates redundant history. |

## Goals

- Define stable action names for the existing Portal lifecycle.
- Keep authoritative mutation and required audit evidence atomic.
- Preserve PR #300 lifecycle and persistence decisions.
- Record actor and target provenance without granting new authority.
- Keep every audit payload bounded and secret-free.
- Preserve post-commit-only success telemetry.
- Keep audit metrics within the exact pilot series ceiling.

## Decisions

### Five Portal User Actions And Existing API Key Actions

The proposed Portal User actions are:

- `portal_user.invited`
- `portal_user.invite_issued`
- `portal_user.invite_reissued`
- `portal_user.invite_redeemed`
- `portal_user.disabled`

Portal-owned API Key creation and effective revocation reuse `api_key.created` and `api_key.revoked`.
No `portal_api_key.*`, `portal_invite.*`, or other alias is introduced.

### Tenant-Scoped Atomic Audit Writes

Every required row uses `scope = "tenant"` and the owning Organization's non-null `tenant_id`.
The authoritative mutation and audit insertion execute inside one outermost `AuditWriter.transaction/1` boundary.
Wrapping `AuditWriter.transaction/1` inside a pre-existing raw `Repo.transaction/1` is prohibited because successful audit telemetry could then be published before the authoritative outer commit.
An audit insertion failure rolls back the mutation and prevents any secret-bearing success result from being published.
Best-effort audit insertion after mutation commit is prohibited.

### Issued-Versus-Reissued Classification Under Lock

Copy invite acquires the existing Portal User `FOR UPDATE` lock before classification.
No stored invite row at that point selects `portal_user.invite_issued`.
An existing invite row selects `portal_user.invite_reissued`.
The transaction then deletes any prior row, stores exactly one replacement hash-only row, ends the target user's sessions, and inserts the classified audit row.

Classification outside the lock is prohibited because concurrent Copy actions could observe stale state.
Token generation and expiry calculation before the lock are also prohibited because a delayed transaction could otherwise replace a newer invite with an older expiry.
The transaction generates both after acquiring the Portal User lock, persists that exact expiry in the replacement invite and audit payload, and returns the matching plaintext URL only after commit.
No schema column, audit payload key, or retained history row records `previous_invite_existed`.

### Effective Transitions And No-Ops

Audit rows represent effective committed transitions only.
A duplicate Portal User creation, invalid redemption, cross-Organization failure, or rejected key mutation creates no success row.
Every successful Copy invite remains effective because it produces a fresh token and expiry.
Repeated disable of an already disabled Portal User must not rewrite `disabled_at`, advance the session epoch, delete more state, or create another success row.
Repeated revoke of an already revoked Portal-owned key returns the persisted state without another mutation or success row.

### Actor And Target Provenance

Console creation, Copy invite, and disable use `actor_type = "operator"`, null `actor_id`, and payload `surface = "console"`.
Successful redemption, Portal key creation, and Portal key revocation use `actor_type = "user"`, `actor_id = portal_user.id`, and payload `surface = "developer_portal"`.
Redemption records successful possession of a valid invite for that Portal User.
It does not claim a pre-existing authenticated Portal session and does not make the Portal User a platform or Public Inference principal.
The audit-log persistence column is text today, and `user` is already part of the `SPEC.md` actor vocabulary, so this recommendation requires no actor-type schema migration.

Portal User lifecycle actions use `target_type = "portal_user"` and the affected Portal User UUID.
They do not target the ephemeral invite row, token, hash, URL, or email address.
API Key actions use `target_type = "api_key"`, the affected API Key UUID, and the matching `api_key_id` foreign key.

### Secret-Free Bounded Payloads

The lifecycle payload contract is:

| Action | Required payload keys | Permitted optional keys |
|---|---|---|
| `portal_user.invited` | `surface` | none |
| `portal_user.invite_issued` | `surface`, `expires_at` | none |
| `portal_user.invite_reissued` | `surface`, `expires_at` | none |
| `portal_user.invite_redeemed` | `surface` | none |
| `portal_user.disabled` | `surface` | none |

For Console actions, `surface` is exactly `console`.
For redemption and Portal-owned API Key actions, `surface` is exactly `developer_portal`.
Invite `expires_at` is the replacement invite expiry encoded as a UTC ISO 8601 string.

Portal-owned `api_key.created` and `api_key.revoked` require `name`, `token_prefix`, `owner_type`, `surface`, `issuance_surface`, and `portal_user_id`.
They include `expires_at` when the key has an expiry and omit it otherwise.
For those rows, `owner_type` is exactly `tenant`, `surface` and `issuance_surface` are exactly `developer_portal`, `portal_user_id` is the canonical Portal User UUID string, and `expires_at` is a UTC ISO 8601 string.
The API Key target and actor fields remain authoritative when a payload field duplicates that provenance.

Payloads must exclude invite tokens, invite hashes, invite URLs, passwords, password hashes, Portal session tokens, Portal session hashes, API Key plaintext secrets, API Key secret hashes, request headers, source addresses, raw errors, arbitrary request parameters, emails, and `previous_invite_existed`.

### Post-Commit Success Telemetry

Audit insertion occurs inside the authoritative transaction.
The `orchard_audit_events_total{action,outcome}` observation with `outcome = "succeeded"` is emitted only after the outer transaction commits.
A rollback cannot emit a phantom success observation.
Audit insertion failure may remain a bounded `failed` telemetry observation after the failure is known, but it does not create an audit row or change the authoritative mutation outcome.

### Bounded Portal User Metrics Domain

All five `portal_user.*` actions normalize to the single metrics action domain `portal_user`.
Concrete action suffixes, Portal User IDs, tenant IDs, emails, and target IDs never become audit metric labels.
The existing outcomes remain `succeeded`, `failed`, and `denied`.

Current code recognizes eleven audit action domains.
Adding `portal_user` produces twelve domains and a family ceiling of 36 series.
Replacing the accepted worksheet's 24-series audit subtotal with 36 changes the accepted pilot total from 2,588 to 2,600 and leaves 2,400 series below the 5,000-series ceiling.
The current catalog total of 2,817 includes 229 attempt and retry series that the accepted contract excludes.
Their reconciliation remains owned by issue #121 and must occur before the later implementation can update the catalog total without silently accepting unrelated behavior.

## Transaction Flows

### Console Portal User Creation

1. Validate the Organization-scoped creation input.
2. Insert the invited Portal User and `portal_user.invited` row in one audit transaction.
3. Roll back both rows if either insert fails.
4. Create no Portal Invite token or URL.

### Copy Invite

1. Resolve and lock the invited Portal User inside the transaction.
2. Classify issued or reissued from the stored invite row under that lock.
3. Generate the fresh token and calculate its expiry after acquiring the lock.
4. Delete any prior invite row and insert one replacement hash-only row with that exact expiry.
5. End that Portal User's standing sessions.
6. Insert the classified audit row with the same expiry.
7. Commit before returning the matching show-once plaintext URL.

### Invite Redemption

1. Preserve the current generic preflight and Organization-bound candidate discovery.
2. Lock and recheck the invited Portal User, then lock the valid invite.
3. Activate the user, mark the invite redeemed, and end that user's sessions.
4. Insert `portal_user.invite_redeemed` with Portal User provenance.
5. Commit before returning success.

### Portal User Disablement

1. Lock the tenant-scoped Portal User.
2. Return the persisted state without mutation when already disabled.
3. Otherwise disable the user, delete outstanding unused invites, and end that user's sessions.
4. Insert `portal_user.disabled` in the same transaction.
5. Leave every API Key unchanged.

### Portal API Key Mint And Revoke

Portal key mint carries the validated session's tenant ID, Portal User ID, and password epoch into the audit transaction.
It locks the tenant-scoped Portal User first, requires that user to remain active and the captured epoch to equal the locked `session_epoch`, applies the existing cap check, inserts the key and `api_key.created` row atomically, and returns the show-once secret only after commit.

Portal revoke carries the same session identity and epoch into the audit transaction.
It locks and revalidates the tenant-scoped Portal User first, then locks the tenant-, Portal User-, and issuance-surface-scoped API Key.
The lock order is always Portal User then API Key.
It records only an active-to-revoked transition with `api_key.revoked` and treats an already revoked key as a no-op.

## Failure Semantics

- Audit insertion failure rolls back every authoritative row mutation in the operation.
- Invalid and ineligible invite redemptions keep the current generic external response and persist no mutation or success audit.
- A wrong-Organization request cannot consume an invite or produce a success audit in either Organization.
- A stale pre-transaction Portal session cannot authorize mint or revoke after the locked Portal User state or session epoch no longer permits it.
- Telemetry failure remains non-authoritative and cannot reverse a committed audit row or domain mutation.

## Alternatives Rejected

- A single `portal_user.invite_copied` action was rejected because it hides the creation-to-first-issuance boundary settled by PR #300.
- An outcome field in every audit payload was rejected because the committed append-only row already represents success and the bounded metric owns outcome projection.
- `system` plus null for successful redemption was rejected as the recommendation because it loses the Portal User provenance established by locked token validation.
- A named Console actor was rejected because current Console authentication does not establish one.
- Persisting `previous_invite_existed` was rejected because the action name already carries that classification.
- An invite-row target was rejected because invite rows are deliberately deleted and are not retained lifecycle history.
- Best-effort audit after commit and pre-commit success telemetry were rejected because they can create mutation-without-audit or phantom-success states.
- Rewriting the archived PR #300 or metrics designs was rejected because archived packages are historical evidence.

## Risks And Review Focus

- Action names become durable audit vocabulary after acceptance, so owner review must approve them explicitly.
- Successful redemption provenance must not be read as a new authentication or authorization grant.
- Current Portal disable and revoke behavior rewrites timestamps on repeats, so later implementation must deliberately adopt the proposed no-op contract.
- Portal mint and revoke validate their sessions before their mutation transactions today, so later implementation must carry the validated identity and epoch into the transaction and recheck both under a Portal User lock before any API Key lock.
- The accepted metrics spec and current implementation disagree about both the audit-domain count and issue #121-owned attempt/retry families, so this package updates only the accepted audit subtotal and leaves the unrelated 229-series drift for its owning change.
- No ADR is warranted for this focused refinement unless owner review selects a broader identity or authority model.
- No glossary change is warranted because `Operator`, `Portal User`, `API Key`, and `Audit Log` already name every domain concept used here.
