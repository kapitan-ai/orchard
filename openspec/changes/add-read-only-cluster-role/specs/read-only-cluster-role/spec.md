## ADDED Requirements

### Requirement: Cluster reader is an API Client role grant

Under the accepted, inactive target in `SPEC.md` §§7.1, 8.3 and 10.4, Orchard SHALL support `cluster_reader` only on a RoleBinding whose principal is an API Client (`service_account`) and whose `tenant_scope_id` is null, after the activation prerequisites below are implemented and proven. The existing service-account-owned API Token SHALL authenticate the enabled owner; a token-specific, Tenant, Console Identity or tenant-scoped reader binding MUST NOT authorize this surface. The role SHALL confer neither public inference nor browser, bootstrap or Node trust authority.

#### Scenario: Dedicated machine reader

- **WHEN** a valid API Token authenticates an enabled API Client with only a cluster-scoped `cluster_reader` binding
- **THEN** it can perform only the explicitly admitted reader actions
- **AND** its Workspace ownership does not restrict or expand that cluster grant

#### Scenario: Wrong subject or scope

- **WHEN** provisioning attempts a reader grant on an API Key or with a non-null Tenant scope
- **THEN** storage and application validation reject the grant
- **AND** such a binding cannot authorize management reads

### Requirement: Reader admission is an explicit route and data contract

For each management request by a principal with a valid `cluster_reader` grant, the Controller SHALL select the reader path when that principal lacks independently sufficient existing cluster `operator` or `admin` authority for that action, whatever other grants it holds. All reader admission/refusal, projection, side-effect and leadership requirements SHALL apply to this path, including for reader-plus-inference clients. Independently sufficient existing authority SHALL retain its current behavior. “Reader-only” SHALL describe provisioning and display, not execution-path selection.

Under the accepted `SPEC.md` §7.3 amendment, the reader path SHALL admit exactly these current GET routes: `/ops/v1/health`, `/ops/v1/cluster`, `/ops/v1/nodes`, `/ops/v1/nodes/:node_id`, `/ops/v1/worker-recovery/nodes/:node_id/models/:model_id`, `/ops/v1/scheduler/explanations/:request_id`, `/ops/v1/circuit-breakers/nodes/:node_id`, and `/ops/v1/circuit-breakers/placements/:node_id/:model_id`.

The Controller SHALL enforce [the closed reader projections](../../design.md#closed-reader-projections), with recursive type/vocabulary validation, fixed non-content errors and `Cache-Control: no-store`. Successful reduced JSON SHALL contain top-level `projection: "cluster_reader.v1"` and its own `orchard.cluster_reader.<shape>.v1` `contract_version`, using the exact root/nested shape names and inheritance in the design. Reduced nested versioned objects MUST NOT retain full operator versions. Each reader projection SHALL be a recursive field subset of the same route's shared operator builder output, extended with the declared schema and caller-authority metadata; retained domain values SHALL agree for the same facts. Existing full wire presenters SHALL retain their bodies. No caller-selectable `?projection=` mode SHALL be added; adapter tests SHALL use reader-provisioned clients. Unknown fields SHALL be excluded; invalid required evidence SHALL fail closed under the existing route error envelope. Authorization SHALL depend on resolved server action/current authority, not GET alone, tool annotations or caller flags.

The reader cluster body SHALL include exactly `authority.roles` and `authority.read_only` as its caller-authority fields, computed from the complete current owner-plus-token grant union under transmission fences. Role names SHALL be declared, sorted and unique; `read_only` SHALL be true only for solely valid cluster-reader authority, never for mixed inference or unknown grants. The projection marker SHALL NOT attest exclusive read-only authority. Node detail SHALL admit validated canonical `agent_version`; Node status SHALL admit only the design's numeric `dispatch_capacity` fields together with its closed counterfactual, phase, policy, decision and freshness metadata under the [capacity serialization exception](../dispatch-capacity/spec.md#requirement-counterfactual-capacity-diagnostics). Neither SHALL expose hostnames or display names. Reader recovery SHALL omit runtime `key.model_id`, which is free-form catalog naming content rather than the route's catalog UUID; valid non-UUID runtime names SHALL NOT cause reader refusal. Reader recovery inspection SHALL use the same `404 worker_recovery_target_not_found` for well-formed unknown/inactive models and exact-version mismatches, while malformed required inputs MAY retain existing 422 validation. Existing operator/admin errors SHALL remain unchanged.

Shared-builder subset tests SHALL establish provenance, not disclosure safety. The recursive closed schema, value validation and malicious-field tests SHALL enforce the disclosure boundary independently of shared builders' permissive string handling. Health SHALL omit arbitrary `build_channel` text; all retained IDs, versions, timestamps and enum/code values SHALL satisfy the reader design's validation rules.

Both current Admin candidate GETs and `GET /metrics` SHALL refuse this role. All specified future reads SHALL follow [the future-read matrix](../../design.md#specified-but-unimplemented-reads): Controller inventory and dispatch-capacity-policy reads are eligible only after their own bounded, leader-aware implementations and regression gates; request details and all listed Admin reads remain excluded. Bounded placement inventory and tenant-dimension-free aggregate telemetry SHALL remain named follow-ups without routes or admission in this change. Initial recovery/placement inspection requires externally supplied Model UUID/version inventory, and scheduler inspection requires an externally supplied Request ID. New or unclassified routes MUST NOT inherit reader admission. Content exclusion SHALL NOT be described as metadata privacy or traffic-analysis protection: cross-tenant operational IDs, existence, scores, codes and changing counts remain disclosed.

#### Scenario: Reader inspects operational state

- **WHEN** a reader calls any admitted current GET under its required leadership and data-availability conditions
- **THEN** it receives only that route's declared reader projection
- **AND** neither arbitrary nested metadata nor free text added later is exposed automatically

#### Scenario: Metrics and governance remain restricted

- **WHEN** a reader calls `/metrics` or either Admin admission-candidate GET
- **THEN** metrics returns `403 operator_required` and Admin returns `403 admin_required`
- **AND** no scrape, candidate lookup or target-existence information is returned

#### Scenario: Future GET is added without reader classification

- **WHEN** an implementing change registers a new GET without the explicit reader action, approved projection and regression gate
- **THEN** reader authority does not authorize it even if an operator or admin can read it

#### Scenario: Projection marker does not establish read-only authority

- **WHEN** a reader-plus-inference client requests cluster status
- **THEN** it receives the reader schema and `authority.read_only: false` with both declared role names
- **AND** a dedicated reader receives the same schema with `read_only: true`, subject to current grants at admission

#### Scenario: Recovery target mismatch is hidden uniformly

- **WHEN** a reader supplies a well-formed unknown model, inactive model or incorrect exact catalog version
- **THEN** each response has the same 404 code and fixed message without catalog or version details
- **AND** existing operator/admin 404-versus-422 behavior remains unchanged

#### Scenario: Valid runtime model name is not disclosed

- **WHEN** a reader supplies an existing catalog Model UUID and exact version whose already-hydrated recovery evidence uses a distinct sensitive non-UUID runtime model name
- **THEN** the read succeeds with the bounded recovery projection and no runtime model name or `key.model_id` field anywhere in its body
- **AND** full operator/admin recovery retains its original runtime `key.model_id` without substituting the catalog UUID

#### Scenario: Builder provenance does not admit arbitrary strings

- **WHEN** a shared builder supplies arbitrary build-channel text or content in an admitted ID, version, timestamp, state, tier or capacity-label field
- **THEN** the reader omits build channel and rejects or nulls other invalid values according to the closed reader schema without echoing the content
- **AND** subset membership alone cannot permit that disclosure, while valid asymmetric fixtures still produce successful bounded reads

### Requirement: Reader authority excludes tenant content and write previews

Under `SPEC.md` §§7.3.1, 7.4.1, 10.4 and 10.10, the reader path SHALL refuse every mutating management operation and every Action Preview, including a valid `dry_run: true` request. Preview refusal SHALL NOT redefine previews as domain writes. The role SHALL exclude request details/captured output, prompts, completions, reasoning, tool schemas/arguments/results, raw events/errors/diagnostics, credentials/invitations and unrestricted metadata. Capture mode or a requested redaction flag MUST NOT authorize otherwise excluded reads.

For valid authenticated requests on the reader path, Operator action refusals SHALL use `403 operator_required` and Admin refusals SHALL use `403 admin_required` in the existing `{"error":{"code","message"}}` envelope and existing role-required messages, without target details. Invalid authentication SHALL retain `401 invalid_api_key`; a valid token with a disabled API Client SHALL retain the surface's role-required 403, not be reclassified as invalid authentication. Authorization SHALL precede controller target lookup, preview/action handling and leadership checks; existing earlier transport/media/parser failures remain unchanged.

#### Scenario: Reader attempts each existing write

- **WHEN** a reader supplies a valid body and existing target to request retry, worker recovery, either breaker clear, candidate reject, candidate clear-rejection or Node admit
- **THEN** the route returns its existing role-required 403
- **AND** no domain effect, runtime write command, preview or write-action audit occurs

#### Scenario: Preview cannot bypass the role

- **WHEN** a reader requests Node admit or reject with `dry_run: true` and otherwise valid fields
- **THEN** it receives the same 403 as execution, without a preview or target disclosure

#### Scenario: Full-capture scheduler metadata contains content

- **WHEN** an admitted scheduler explanation references a Request whose diagnostics or component maps contain tenant content
- **THEN** only validated IDs, tier, numeric score, booleans and stable codes are delivered
- **AND** content and raw validation-error details do not appear in success or error responses

### Requirement: Additional grants do not become read-only restrictions

Under `SPEC.md` §§10.4 and 10.11, grants SHALL remain additive. An API Client holding `cluster_reader` plus `operator` or `admin` SHALL retain the latter's current permissions and response projections; inference grants SHALL continue to confer inference authority. The reader role MUST NOT be advertised as token attenuation. Clients with any additional retained authority SHALL NOT be labeled read-only. The reader role SHALL count as cluster privilege in credential target classification, including inactive owners/tokens and retained key grants; Tenant-admin credential management SHALL NOT treat such targets as inference-only.

#### Scenario: Mixed administrator client

- **WHEN** the same API Client has cluster `admin` and `cluster_reader` grants
- **THEN** its tokens retain existing admin operations and full admin/operator projections
- **AND** Console/provisioning presentation does not describe it as read-only

#### Scenario: Mixed inference client uses the reader path for management

- **WHEN** an API Client has valid `cluster_reader` and `inference_client` grants but no independently sufficient cluster operator/admin authority for the requested management action
- **THEN** its management requests use the reader projections, non-observing health, leadership gates and write refusals, including `503 controller_standby` for scheduler reads on Standby
- **AND** it retains its granted inference authority and is displayed as Not read-only

#### Scenario: Tenant administrator targets a disabled reader owner

- **WHEN** a Tenant-admin credential operation targets a token of a disabled API Client retaining `cluster_reader`
- **THEN** the complete retained grant union classifies it as cluster-privileged and refuses Tenant-admin inspection/revocation

### Requirement: Reader provisioning is explicit and preserves secret custody

Under the accepted `SPEC.md` §§8.3, 10.4 and 11.9 amendments, Controller-host `orchardctl api-clients bulk-provision` SHALL accept `--access-level cluster_reader` as an explicit alternative to the existing inference default. Reader mode SHALL create/ensure the cluster grant without an inference grant and SHALL require an otherwise grantless new client or an existing reader-only client, checking the complete retained owner-plus-token grant union under relevant writer fences at apply time. Mixed grants SHALL reject the whole batch without replacement/removal. Default mode MUST NOT silently add inference to an existing reader-only client.

Existing CSV/rotation/atomic batch and protected one-time output contracts SHALL remain. Dry-run/apply summaries SHALL identify access level and cluster scope without secrets. RoleBinding and batch/token audit SHALL commit under their existing schemas with effective writes; read or preview audit payloads SHALL NOT be invented. Console SHALL show the actual grant and cluster scope rather than No Access, without admitting a reader bearer to Console.

The role-value migration SHALL preserve existing grants/subjects and null-scope uniqueness, enforce the reader subject/scope constraint, and perform no default backfill. New-role provisioning SHALL wait for compatible readers/writers; downgrade SHALL refuse while new-role rows remain rather than delete authority automatically.

#### Scenario: Reader-only batch

- **WHEN** an authorized Controller-host operator applies a valid explicit reader batch
- **THEN** each intended owner receives only cluster-reader authority and no automatic inference grant
- **AND** secrets are delivered once through the existing protected output path, with atomic grant/batch/token audit

#### Scenario: Grant inserted after dry-run

- **WHEN** another writer commits an operator, inference or other grant before the reader batch's authoritative apply check
- **THEN** apply rejects the conflicting authority and rolls back the entire batch
- **AND** dry-run results cannot authorize stale provisioning or strip the new grant

### Requirement: Reader operations are current-authority and side-effect-free

Consistent with `SPEC.md` §§7.3, 10.11 and the `add-operator-api-reads` contract, operations on the reader path SHALL change no durable domain/audit state except existing API Token `last_used_at` bookkeeping. That update occurs before authorization, including refusals and Standby requests; it SHALL NOT prove successful access, extend expiry or advance revocation-relevant credential revision. Coarsened polling bookkeeping and bounded non-authoritative denial logging SHALL remain follow-ups. Existing aggregate HTTP status metrics do not supply a per-principal denial audit; no mutation audit SHALL be invented for reads/refusals. Existing authentication-failure audit remains outside successful-read semantics. Successful probes and rejected peer verification SHALL NOT persist observations, candidates, capacity refresh/clear, recovery state or repair. Health SHALL use non-observing runtime reads; omitted Node detail memory-budget evidence SHALL NOT trigger its probe. Breaker inspection SHALL NOT take dispatch target advisory/row write locks; shared authority fences still apply. Reader recovery SHALL use already-hydrated evidence or return `503 worker_recovery_unavailable` without hydration or checkpoint effects.

Under the accepted explicit §10.11.2 exception, health and cluster SHALL report only serving-Controller evidence and the caller's bounded authority on Active or Standby with existing readiness outcomes. This observation exception SHALL retain authoritative Postgres and common current-authority fences; unavailable authority SHALL return `503 authority_unavailable`, not cached success or a replica/local Repo fallback. It SHALL NOT admit credential-family inspection or other managed-target reads on Standby. The other six reader GETs SHALL require active/proven leadership and retain `503 controller_standby` / `503 controller_leadership_unproven` refusals. Reader authorization failures SHALL precede leadership/target-dependent responses. No read SHALL acquire leadership or trigger reconciliation.

The reader contract SHALL land first; activation SHALL remain blocked on completion and proof of `cross-surface-authorization-contract` tasks 3.1–3.2, including shared policy/fences and retained-writer closure. Protected delivery for every request entering with a reader grant SHALL revalidate token/owner/grants and reselect execution path, leadership eligibility and projection at transmission admission under those fences, even when a stronger grant initially selected full output. A full payload fetched before operator/admin grant removal MUST NOT be sent merely because the remaining reader grant still authorizes the GET. It SHALL be discarded and rebuilt on the current reader path with fresh admission, or refused without data. This newly fenced path does not claim today's operator-only reads have migrated; it SHALL NOT claim named-Console cutover or a COMPLETE CLI family, or authorize MCP implementation.

#### Scenario: Health probe succeeds without observation

- **WHEN** a reader health call receives authenticated Runtime Endpoint evidence
- **THEN** bounded status may be returned and the API Token usage timestamp may advance
- **AND** Node/candidate/audit/capacity state remains unchanged on both successful and rejected peer-verification paths

#### Scenario: Standby durable read

- **WHEN** a valid reader asks Standby for Node, scheduler, recovery or breaker evidence
- **THEN** it receives `503 controller_standby` without a domain read result or runtime probe
- **AND** a forbidden mutation on that Controller still receives its role-required 403

#### Scenario: Revocation wins before delivery admission

- **WHEN** token revocation, owner disablement or reader-grant removal commits before protected data transmission admission
- **THEN** the read cannot deliver previously fetched data from a stale caller context
- **AND** data already admitted before the restrictive change is not claimed to be recalled

#### Scenario: Full response loses disclosure authority but retains read admission

- **WHEN** operator or admin removal commits after a mixed client's full response was built but before transmission admission, leaving a valid reader grant
- **THEN** the full response is discarded and rebuilt using the current reader projection and execution rules, or refused without data
- **AND** rebuilding health uses non-observing execution, and rebuilt output passes admission again

#### Scenario: Downgraded scheduler request is on Standby

- **WHEN** a reader-plus-operator/admin scheduler request built a full response on Standby and loses the stronger grant before transmission admission
- **THEN** current reader leadership rules return `503 controller_standby`, never the full or reduced scheduler payload

#### Scenario: Standby self-observation still requires current authority

- **WHEN** a reader requests health or cluster on Standby with authoritative Postgres and shared fences available
- **THEN** it may receive only the serving Controller's bounded evidence and, for cluster, its own current authority
- **AND** loss of that authority source returns `503 authority_unavailable` rather than cached success

#### Scenario: Dispatch lock does not serialize a reader inspection

- **WHEN** dispatch holds the breaker target advisory lock while an authorized reader inspects that target
- **THEN** the reader returns bounded committed-state evidence without waiting for that lock or changing breaker state
- **AND** the result does not reserve dispatch eligibility
