## ADDED Requirements

These requirements are accepted target behavior under `SPEC.md` §10.11 and remain pending implementation and cutover; they do not establish a COMPLETE family.

### Requirement: Complete credential inspection and revocation surfaces

Under the accepted target in `SPEC.md` §§7.4 and 11.9, the first migrated family SHALL provide list, inspect, domain-side-effect-free revoke preview with the explicit Console idle-bookkeeping exception, and revoke for `api_key`, `api_token`, and `console_session` through shared Controller-owned operations.
Console, Admin API, and portable CLI SHALL use the same action identifiers, scope policy, domain outcome codes, and target semantics.
COMPLETE SHALL mean equivalent policy outcomes for equivalent authority admitted by each surface; Tenant-admin machine/API/CLI admission SHALL remain deferred without a scoped cross-surface parity claim.
The new Admin API surface SHALL use `GET /admin/v1/credentials`, `GET /admin/v1/credentials/:kind/:id`, and `POST /admin/v1/credentials/:kind/:id/revoke` under existing cluster-admin API Client admission.
The CLI SHALL provide `credentials list`, `credentials inspect <kind> <id>`, and `credentials revoke <kind> <id>` with stable human and JSON output.
Existing management key-list and revoke entry points SHALL delegate to the same authority or be explicitly removed through compatible migration documentation.
`SPEC.md`'s key list/revoke routes are currently specified but unwired; this migration SHALL introduce them as thin family delegates with the same envelope and execution gates.
Implemented baseline paths SHALL be inventoried explicitly: Console `TenantDetailLive`, scoped/unscoped governance revoke, `orchardctl api-keys revoke` through direct `RepoRuntime`, Portal own-key revoke, and rotation's multi-key revoke.
Console paths SHALL delegate, unscoped direct revoke SHALL become internal or be removed, and the old CLI command SHALL become a portable alias with server-side kind resolution under authorized lookup so API Client tokens in the shared table remain addressable without an existence leak.
Creation/rotation SHALL remain separate families while their credential/grant writes participate in the common authority fences.
Portal self-service SHALL retain its narrower authenticated Portal-owned-key contract and MUST NOT gain management-family authority.
Credential creation/rotation, API Client disablement, and grant editing SHALL require separate migration contracts.

#### Scenario: Equivalent administrators revoke on three surfaces

- **WHEN** Console, Admin API, and CLI callers with equivalent cluster-admin authority request the same target operation and preconditions
- **THEN** the Controller evaluates the same action and policy and returns equivalent domain outcomes
- **AND** surface provenance does not alter permissions

#### Scenario: Previously specified key route is introduced

- **WHEN** an administrator invokes the newly wired `/admin/v1/api-keys/:key_id/revoke` delegate after family cutover
- **THEN** it uses the same current authorization, target scoping, confirmation, concurrency, and audit enforcement as the new family route

#### Scenario: Legacy CLI alias targets an API Client token

- **WHEN** an authenticated caller uses `api-keys revoke --api-key-id` with an API Client token row UUID
- **THEN** the server resolves the stored kind under current authorized lookup and executes the shared token revoke with the same explicit gates
- **AND** the alias neither assumes tenant-direct kind nor invokes local Repo authority

### Requirement: Credential authority is scoped to full target privilege

Under the accepted target in `SPEC.md` §10.4, cluster admins SHALL have family authority across the cluster.
A Console Identity with exact-Tenant `tenant_admin` SHALL inspect/revoke only inference-only API Keys and API Client API Tokens whose entire effective authority is inside that Tenant.
An API Client with any cluster grant, cross-Tenant grant, or non-inference management grant SHALL be excluded from Tenant-admin token inspection and revocation even when its owning Tenant matches.
For tenant-direct keys, including Portal-owned and legacy unowned Portal keys, management classification SHALL inspect the union of Tenant-principal and key-specific RoleBindings.
For API Tokens it SHALL inspect API Client-principal and key-specific RoleBindings.
Eligibility SHALL require matching authoritative Tenant ownership and every union member to be `inference_client` with that exact Tenant scope; an empty union SHALL be eligible when ownership matches.
Cluster, foreign-Tenant, or non-inference bindings SHALL remain disqualifying even when a target or owner is expired, revoked, or disabled.
Every consulted binding namespace SHALL participate in authority fencing, including addition of absent grants.
This conservative classification SHALL NOT change Tenant-direct inference principal resolution or make unsupported grants authorize a bearer audience.
The `operator` role alone SHALL grant no inference-key management authority.
A valid Console Identity SHALL be able to inspect/revoke its own Console Sessions; management of another identity's sessions SHALL require cluster admin.
API Clients SHALL continue to satisfy existing Admin API cluster-admin admission, and this change MUST NOT create an implicit Tenant-admin bearer endpoint.
Resource lookup, policy, and filtering SHALL use server-resolved parent and privilege state rather than submitted Workspace IDs.
Caller grants SHALL be additive, but multiple Tenant-admin scopes SHALL NOT combine to authorize one cross-Tenant or privileged target.

#### Scenario: Cluster administrator token owned by matching Tenant

- **WHEN** a Tenant-admin Console Identity targets a token whose API Client belongs to that Tenant but has cluster `admin` or `operator` authority
- **THEN** inspect/revoke returns the same `not_found` outcome as an unknown target
- **AND** list, counts, and pagination do not reveal the token

#### Scenario: Another identity's session

- **WHEN** an operator-only Console Identity requests another identity's session metadata or revocation
- **THEN** Orchard hides the target as missing
- **AND** the same caller can manage only its own sessions

#### Scenario: Allowed Tenant key

- **WHEN** a Tenant-admin Console Identity targets an inference-only key wholly scoped to its granted Tenant
- **THEN** the shared domain policy permits inspection and confirmed revocation subject to current authentication and operation preconditions

#### Scenario: Disabled owner retains privileged grants

- **WHEN** a token's disabled API Client retains a cluster grant, or a direct key's Tenant/key grant union contains management authority
- **THEN** the target remains hidden from Tenant-admin inspection and revocation
- **AND** inactivity does not downgrade its classification to grantless inference-only access

#### Scenario: Multiple caller scopes do not combine

- **WHEN** a caller holds Tenant-admin grants for two Workspaces and targets one credential with bindings spanning both
- **THEN** neither grant nor their union authorizes the cross-Tenant target

### Requirement: Inspection exposes bounded metadata only

Under the accepted target in `SPEC.md` §§10.2 and 10.8, list/inspect/preview SHALL return a closed non-secret projection containing typed target ID, display name or token prefix where applicable, typed owner ID, Tenant scope, lifecycle timestamps, effective status, and revision.
Console Session metadata SHALL include activity timestamps and a current-session indicator without exposing the bearer.
No response, audit payload, error, or diagnostic SHALL expose passwords, credential/session/invite hashes, bearer cookies, raw request fields, or recoverable secrets.
List SHALL use cursor pagination with default 50 and maximum 100 items and apply authorization filtering before counts and pagination.
Metadata responses SHALL use `Cache-Control: no-store`.
Missing and out-of-scope targets SHALL have indistinguishable `not_found` results.
Supported kind values SHALL be exactly `api_key`, `api_token`, and `console_session`; a valid-but-wrong kind for a UUID SHALL return hidden `not_found`, and an unsupported kind SHALL return invalid input.
Allowed list filters SHALL be exactly `kind`, `tenant_id`, `owner_type`, `owner_id`, `token_prefix`, `status`, `limit`, and `cursor`, with owner type/ID paired and unknown filters rejected.
`token_prefix` SHALL match only a complete persisted non-secret prefix for either API credential form, never a substring or secret, supporting authenticated recovery without disclosing out-of-scope targets.
Status SHALL be `revoked`, `expired`, `owner_disabled`, `epoch_invalid`, or `active` in that precedence without changing privilege classification.
Ordering SHALL be ascending `(created_at, kind, id)` with kind order `api_key`, `api_token`, `console_session`; integrity-protected opaque cursors SHALL bind actor, filters, and last tuple without secret values.
Each continuation SHALL reauthorize current scope and state after that tuple, without stable snapshot/total guarantees; filter/actor changes or malformed cursors SHALL be rejected rather than restarted.
List SHALL return no total count, and rows inserted before the cursor SHALL require a new traversal.

#### Scenario: Out-of-scope key supplied directly

- **WHEN** a caller supplies another Tenant's known credential UUID directly
- **THEN** no name, prefix, existence, owner, or state is disclosed
- **AND** the result matches an unknown UUID

#### Scenario: Inspect revoked token

- **WHEN** an authorized caller inspects a revoked token
- **THEN** Orchard returns its bounded non-secret status and revision
- **AND** no original token value or hash is recoverable

#### Scenario: Recovery resolves a stranded credential by exact prefix

- **WHEN** an operator with another usable administrator credential lists the exact stored prefix reported by failed credential publication
- **THEN** the operation returns only authorized non-secret target kind/UUID/state metadata for explicit preview and revoke
- **AND** it neither remints automatically nor treats failed delivery as credential rollback

### Requirement: Credential carriers preserve exact request and result contracts

Under the accepted target in `SPEC.md` §§7.4 and 11.9, successes SHALL use `{data: ...}` and errors `{error: {code, message}}` with bounded generic messages.
List data SHALL be `{items, next_cursor}`, inspect data the closed metadata object, revoke data `{status: "revoked" | "already_revoked", credential}`, and preview data `{status: "preview", target: {kind, id, revision}, blockers, warnings, consequence_codes, confirmation_requirements}` using the shared presenter.
The revoke body SHALL accept only `dry_run`, `expected_revision`, `reason`, `confirmed`, and `acknowledge_self_revocation`; preview SHALL need only `dry_run: true`, while execution SHALL require revision, reason, and confirmation.
CLI SHALL expose `--dry-run`, `--expected-revision`, `--reason`, `--yes`, `--acknowledge-self-revocation`, and `--json`, with list flags matching the allowed filters.
Portable calls SHALL explicitly select `--controller <https-origin>` and `--token-file <path>` containing one API Token in an owner-only regular file, with mandatory TLS verification and no plaintext token argument.
Credentials SHALL NOT be forwarded on redirects; a non-Active refusal SHALL require explicit Controller selection rather than local Repo/release-evaluation fallback.
Adapters SHALL NOT substitute a freshly fetched revision for a caller-supplied stale revision or silently run an execution preview on the caller's behalf.
CLI JSON SHALL preserve the HTTP envelope without secret output; human output SHALL present the same target/revision/consequences/outcomes.

#### Scenario: Script executes an earlier preview

- **WHEN** a script passes its saved revision using `--expected-revision` with reason and required acknowledgements
- **THEN** the CLI sends that revision unchanged and preserves the server's result/error envelope
- **AND** a stale revision is never silently refreshed to make execution succeed

#### Scenario: Controller redirects an authenticated CLI

- **WHEN** the selected Controller returns a redirect or non-Active refusal
- **THEN** the CLI does not forward the bearer to another origin or fall back to local Repo access

### Requirement: Revocation requires current preview preconditions and explicit acknowledgement

Under the accepted target in `SPEC.md` §§7.4 and 11.9, revoke preview SHALL be domain-side-effect-free except for eligible Console idle bookkeeping and return exact target kind/ID, current revision, blockers, warnings, consequences, and confirmation requirements.
Execution SHALL require `expected_revision`, a reason of 1-512 Unicode characters after trimming, and explicit confirmation through `confirmed: true`, CLI `--yes`, or the equivalent Console confirmation.
A current-session or current-token revoke SHALL additionally require `acknowledge_self_revocation` and SHALL permit the action even for the last working credential after that acknowledgement.
Preview SHALL NOT confer authority or exempt mutation-time authentication, grant, target, or leadership checks.
An unrevoked target's revision mismatch SHALL return `conflict` only after current scope authorization; scope loss after preview SHALL return hidden `not_found` first.
Every unrevoked target, including expired credentials, disabled-owner credentials, and epoch-invalid Console Sessions, SHALL require current revision equality and remain inspectable/revocable by a valid authorized caller under retained privilege classification; expired caller authentication SHALL fail.
Target revision SHALL encode a monotonic target generation and relevant authority-namespace generations, excluding passive token-use/session-activity updates while advancing for changed revocation consequences.
Ownership and privilege SHALL still be revalidated under authority fences; revision SHALL NOT establish authority.
An already-revoked target SHALL return `already_revoked` with unchanged timestamps/revision and no new success audit row after current caller authorization, including retries carrying its earlier revision.
Already-revoked handling SHALL waive only revision equality, not a well-formed required revision/reason/confirmation/acknowledgement request, current caller authentication, target kind, or scope checks.
First effective revoke SHALL return `revoked` and commit its mutation/audit once.
Revocation SHALL take effect at the next authentication or operation boundary without undoing an already-committed effect or canceling admitted inference work.

#### Scenario: Target changes between preview and execution

- **WHEN** a caller confirms revocation with an old revision for an unrevoked, still-in-scope target changed since preview
- **THEN** Orchard returns `conflict` without revocation or success audit
- **AND** a fresh preview is required

#### Scenario: Scope is lost after preview

- **WHEN** target privilege or ownership changes after preview so the caller no longer has scope
- **THEN** execution returns the same `not_found` as an unknown target before revision checks
- **AND** it does not disclose the scope change through `conflict` or `forbidden`

#### Scenario: Authorized caller revokes an expired target

- **WHEN** a valid authorized caller confirms revocation of an expired but unrevoked credential with current revision
- **THEN** Orchard commits its revocation and audit under the retained target privilege class
- **AND** expiry of the target is not confused with expiry of the caller's authentication

#### Scenario: Already-revoked retry omits confirmation

- **WHEN** a caller retries a revoked target without valid required request fields or confirmation
- **THEN** Orchard rejects the malformed request rather than using terminal target state to bypass execution gates
- **AND** a properly formed authorized in-scope retry waives only equality with the earlier revision

#### Scenario: Response lost after effective revoke

- **WHEN** a successful revoke response is lost and a still-authorized caller retries the same target with its earlier revision
- **THEN** Orchard returns `already_revoked` with the committed terminal state
- **AND** no timestamp is rewritten or duplicate success audit recorded

#### Scenario: Caller revokes its own session

- **WHEN** the caller supplies explicit self-revocation acknowledgement and other valid preconditions
- **THEN** Orchard commits and returns its revocation result once
- **AND** any subsequent operation using that session fails authentication, including a replay of the revoke

### Requirement: Family leadership failures and audit are coherent

Under the accepted target in `SPEC.md` §§7.4, 10.9, and 11.9, family reads, previews, and mutations SHALL execute only on the active Controller against available authoritative Postgres state.
Standby SHALL refuse as `not_active_controller`; unavailable authority SHALL refuse as `authority_unavailable` without cached authorization success or local Repo fallback.
HTTP adapters SHALL map those refusals to retryable `503`, invalid authentication to `401`, hidden targets to `404`, forbidden actions to `403`, stale revisions to `409`, and invalid input/confirmation to `422`.
CLI SHALL expose matching domain codes in JSON and exit nonzero on refusal; Console SHALL NOT present refusal as completion.
Effective revoke and its correctly scoped audit row SHALL commit atomically with the actual authenticated actor and non-secret authentication-record reference.
Tenant-direct key and API Client token events SHALL both preserve `api_key.revoked`, target type `api_key`, and the existing `api_key_id` reference for their shared persisted representation.
The closed `credential_kind` field SHALL distinguish the two product forms without renaming existing audit actions or losing action-domain telemetry.
Console Session events SHALL use `console_session.revoked` and target type `console_session`, with an explicitly added Console-session telemetry mapping.
Console Session targets SHALL have null `api_key_id`; actor/authentication/target audit references SHALL remain historically intact when their source records are later revoked, disabled, or cleaned up.
Session targets and API credentials of either form with retained cluster, cross-Tenant, or non-inference bindings SHALL use cluster scope with null Tenant ID even if the owner has a Tenant field or is disabled.
Inference-only keys/tokens wholly contained in one Tenant SHALL use that exact Tenant audit scope, never both scopes.
New management revokes SHALL use top-level `payload_schema = 'credential_management.v1'`, including management revocation of Portal-minted keys, selected by executing operation rather than issuance provenance.
For API credential revokes its exact required payload SHALL be `name`, `token_prefix`, `owner_type`, `surface`, `credential_kind`, `reason`, `previous_revision`, and `revision`.
Only `service_account_id`, `expires_at`, `issuance_surface`, and `portal_user_id` SHALL additionally appear when the corresponding persisted values exist; no other payload fields are permitted.
For Console Session revokes its exact payload SHALL be `surface`, `credential_kind`, `reason`, `previous_revision`, and `revision`.
`actor_principal_type`, `actor_credential_type`, and `actor_credential_id` SHALL be required top-level references for new authenticated management revokes, with the caller credential distinct from target `api_key_id`.
Management actor type SHALL remain `operator`; Console uses principal/credential types `console_identity`/`console_session`, and API/CLI uses `service_account`/`api_key`.
Server-known surface SHALL be `console` or `admin_api`; a CLI header SHALL NOT be treated as trusted provenance.
Portal-origin events SHALL select `portal_lifecycle.v1` with existing payloads unchanged; null schema/typed fields SHALL retain legacy interpretation without historical updates.
Reads, previews, denials, and true no-ops SHALL NOT create successful mutation audit rows.
Success telemetry SHALL occur only after commit, and loss of a post-commit response SHALL be reported as an unknown client outcome resolved through authorized inspection or retry.

#### Scenario: Active Controller fails before commit

- **WHEN** leadership or authoritative storage is unavailable before revoke commits
- **THEN** the operation returns the appropriate refusal without a success claim
- **AND** the CLI does not perform a local Repo write to compensate

#### Scenario: Audit rejects a revoke row

- **WHEN** the required audit row cannot be committed with the revocation
- **THEN** both effect and audit are rolled back
- **AND** the target remains unrevoked and the failed operation changes no lifecycle fields
- **AND** existing expiry, owner-state, and session-epoch rules continue to apply with no success telemetry
