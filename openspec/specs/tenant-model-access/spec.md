# tenant-model-access Specification

## Purpose
Define deny-by-default, lifecycle-aware Model access grants for each effective Tenant across listing, inference, CLI, and Console surfaces.

## Requirements
### Requirement: Model access is deny-by-default for the effective Tenant
Orchard SHALL authorize public Model listing and new inference only when the effective Tenant has an enabled access record for the active catalog Model.
Tenant-direct and Service Account credentials that resolve to the same effective Tenant SHALL receive the same model-access decision.
Principal metadata, credential ownership form, Owner Contact, and Team SHALL NOT create or widen model access.
Existing Models and Tenants SHALL NOT receive automatic access during migration.
This implements `SPEC.md` §5.2, §6.6, and §7.2.3.

#### Scenario: Another Tenant's grant does not authorize the caller
- **GIVEN** Tenant A has an enabled grant for an active Model
- **AND** Tenant B has no enabled grant for that Model
- **WHEN** a credential whose effective Tenant is Tenant B lists Models or requests inference with that Model
- **THEN** Orchard does not use Tenant A's grant
- **AND** Tenant B cannot list or infer with that Model

#### Scenario: Service Account uses its owning effective Tenant
- **GIVEN** a Tenant-direct credential and a Service Account credential resolve to the same effective Tenant
- **WHEN** each credential lists Models or requests the same Model
- **THEN** Orchard makes the same grant decision for both credentials

#### Scenario: Console Playground resolves the seeded legacy Tenant
- **GIVEN** the Console Playground has no per-Tenant credential
- **WHEN** an operator loads the Playground Model picker or sends a Playground message
- **THEN** Orchard resolves the effective Tenant to the seeded legacy Tenant
- **AND** offers and authorizes only Models with an enabled grant for that Tenant
- **AND** a Model granted for Playground use is equally authorized for API credentials scoped to that same Tenant

### Requirement: Tenant-model access has explicit lifecycle states
An enabled access record SHALL authorize new listing and inference checks.
A disabled access record SHALL preserve its routing-policy reference and SHALL NOT authorize.
A revoked access record SHALL be deleted and SHALL NOT delete its referenced routing policy.
Repeated grant, enable, disable, and revoke operations SHALL converge on the requested durable state without duplicate audit records for no-op outcomes.
This implements the `tenant_model_access` persistence and governance requirements in `SPEC.md` §10.9.

#### Scenario: Disable preserves policy but denies access
- **GIVEN** a Tenant has an enabled grant with an explicit routing policy
- **WHEN** an operator disables the grant
- **THEN** Orchard preserves the routing-policy reference
- **AND** subsequent listing and new inference checks deny access

#### Scenario: Revoke removes the grant only
- **GIVEN** a Tenant grant references a routing policy
- **WHEN** an operator revokes the grant
- **THEN** Orchard deletes the access record
- **AND** Orchard retains the routing policy
- **AND** a repeated revoke reports an idempotent not-granted outcome

### Requirement: Routing-policy attachment preserves Tenant scope
Orchard SHALL permit a Tenant-model grant to reference only a routing policy owned by the same Tenant or a global routing policy whose Tenant is null.
Orchard SHALL reject attachment of another Tenant's routing policy at the database integrity boundary.
Routing-policy Tenant scope SHALL be immutable after creation.
This implements the `routing_policies` and `tenant_model_access` integrity requirements in `SPEC.md` §10.9.

#### Scenario: Cross-Tenant policy attachment is rejected
- **GIVEN** a routing policy owned by Tenant A
- **WHEN** an operator attempts to attach it to Tenant B's Model grant
- **THEN** Orchard rejects the mutation
- **AND** no access or audit mutation commits

#### Scenario: Global policy attachment is explicit
- **GIVEN** a routing policy whose Tenant is null
- **WHEN** an operator attaches its UUID to a Tenant grant
- **THEN** Orchard accepts the explicit global policy
- **AND** Orchard does not select any other global policy implicitly

### Requirement: Null routing policy resolves canonical defaults
A grant with no routing-policy reference SHALL resolve directly to the canonical defaults owned by `AdmissionPolicy`.
Orchard SHALL NOT select a policy implicitly by name, priority, creation order, or global scope.
The resolved values SHALL enter the canonical Request snapshot before persistence.
This implements `SPEC.md` §5.2 and §6.6 routing resolution.

#### Scenario: Grant without policy uses defaults
- **GIVEN** an enabled grant whose routing-policy reference is null
- **WHEN** Orchard authorizes a new inference Request
- **THEN** the canonical Request records no routing-policy ID
- **AND** records empty allowed pool IDs
- **AND** uses `allow_cold_load`, the canonical cold-start budget, and the canonical queue-wait budget

### Requirement: Initial routing policies do not claim unenforced pool isolation
Until scheduler pool enforcement is implemented, routing policies SHALL require empty allowed and preferred pool arrays.
The initial operator surface SHALL NOT expose pool-routing flags.
A non-empty pool array SHALL be rejected by persistence constraints.
This implements the executable-routing boundary in `SPEC.md` §5.2 and the `routing_policies` shape in §10.9.

#### Scenario: Non-empty pool constraint is rejected
- **WHEN** a caller attempts to persist a routing policy with a non-empty allowed or preferred pool array
- **THEN** Orchard rejects the policy
- **AND** no audit mutation commits

### Requirement: Public Model listing is Tenant-filtered
`GET /v1/models` SHALL return only active catalog Models with an enabled grant for the effective Tenant.
Disabled, revoked, ungranted, inactive, and other-Tenant-only Models SHALL be absent.
Grant changes SHALL affect the next listing after commit.
This implements `SPEC.md` §7.2.3.

#### Scenario: Tenants receive different Model lists
- **GIVEN** Tenant A and Tenant B have different enabled grants
- **WHEN** each Tenant calls `GET /v1/models`
- **THEN** each response contains only that Tenant's active authorized Models

#### Scenario: Revocation removes Model from listing
- **GIVEN** an active Model is visible through an enabled grant
- **WHEN** the grant is revoked and committed
- **THEN** the next Model listing omits that Model

#### Scenario: Console Playground reports why a Model cannot run
- **GIVEN** an operator submits a Model that the Playground picker does not offer
- **WHEN** the Model is active in the catalog but has no enabled grant for the Playground Tenant
- **THEN** the Playground reports an ungranted-Model reason naming the operator grant command
- **AND** when the Model is absent or not active in the catalog it reports an unavailable-Model reason instead
- **AND** neither reason authorizes the run or discloses another Tenant's grants

### Requirement: Shared inference enforces Model access with exact precedence
Chat Completions and Responses SHALL enforce Tenant-model access through their shared preparation boundary.
Model identity, active-state validation, tokenization, and context-limit enforcement SHALL precede access enforcement as required by `SPEC.md`.
Access denial SHALL precede Request persistence, quota, queueing, scheduling, Node contact, model loading, and inference execution.
A missing or inactive Model SHALL remain `404 model_not_found`.
An existing active Model without an enabled grant SHALL return `403 model_not_authorized` with type `invalid_request_error`, message `Model not authorized for tenant`, and `param=model`.
This implements `SPEC.md` §5.2 and §7.2.7.

#### Scenario: Active ungranted Model returns exact forbidden error
- **GIVEN** an active catalog Model without an enabled grant for the effective Tenant
- **WHEN** the Tenant requests that Model through Chat Completions or Responses
- **THEN** Orchard returns HTTP 403
- **AND** error code is `model_not_authorized`
- **AND** error type is `invalid_request_error`
- **AND** error message is `Model not authorized for tenant`
- **AND** error parameter is `model`
- **AND** no Request or admission/execution side effect is created

#### Scenario: Context failure precedes access denial
- **GIVEN** an active Model is ungranted for the effective Tenant
- **AND** the request exceeds the Model context limit
- **WHEN** Orchard prepares the request
- **THEN** Orchard returns the context-limit error required by `SPEC.md`
- **AND** does not continue to access enforcement or Request persistence

### Requirement: Access and routing mutations are audited atomically
Routing-policy creation and state-changing grant, enable, policy replacement, disable, and revoke operations SHALL commit with append-only audit evidence or roll back together.
No-op desired-state operations SHALL NOT emit duplicate audit records.
Audit payloads MUST NOT contain credentials, artifact paths, prompts, responses, or raw Model content.
This implements `SPEC.md` §10.9.

#### Scenario: Audit failure rolls back a grant
- **WHEN** a grant mutation succeeds but its required audit insertion fails
- **THEN** Orchard rolls back the access mutation
- **AND** no enabled grant becomes visible

### Requirement: Local operator commands provide the first supported lifecycle
The first implementation SHALL provide local `orchardctl models` commands to create, list, and inspect constrained routing policies and to grant, disable, revoke, list, and inspect Tenant-model access.
Tenant references SHALL accept an exact UUID or slug.
Model references SHALL use exact `<model_id>@<version>` identity.
Policy references SHALL use UUIDs.
The commands SHALL distinguish enabled, disabled, revoked/not-granted, default-policy, and explicit-policy outcomes.
This implements the local operator command authority defined by `SPEC.md` and the §10.9 governance lifecycle.

#### Scenario: Operator grants default access
- **WHEN** an operator grants an exact Model to an exact Tenant without a routing-policy UUID
- **THEN** Orchard creates or enables the access record
- **AND** records a null policy reference
- **AND** reports the canonical default routing outcome

#### Scenario: Invalid identity does not create access
- **WHEN** an operator supplies an unknown Tenant, Model, or policy identity
- **THEN** the command exits with an error
- **AND** no access or audit mutation commits
