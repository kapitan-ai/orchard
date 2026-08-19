# Design: tenant-scoped model grants and routing snapshots

## Context

Public authentication already resolves one effective `tenant_id` for both Tenant-direct and Service Account credentials. The authorization gap begins after that point:

- `/v1/models` calls a global active-catalog query;
- shared request preparation accepts any active catalog Model;
- no tenant-model access or routing-policy relation exists;
- no supported operator lifecycle can grant or revoke access; and
- no exact `model_not_authorized` public error is emitted.

`RequestPreparation` is the shared Chat Completions and Responses boundary. It completes before `RequestOrchestrator` creates a durable Request or reaches quota, queue, scheduler, Node, model-load, or inference execution paths.

## Decisions

### 1. Access is deny-by-default and keyed by effective Tenant

An enabled `tenant_model_access` row for `(tenant_id, model_id)` authorizes a new listing or inference check. A missing or disabled row does not.

Credential principal type, Service Account identity, Owner Contact, Team, API Key ownership form, and credential metadata do not create or widen model access. Both credential forms use the effective Tenant already assigned by `RequestContext`.

Existing Models and Tenants receive no migration backfill. The legacy Tenant has no special implicit access.

### 2. Disable and revoke are distinct

- **Disable** sets `enabled=false` and preserves the attached policy for later review or re-enable.
- **Revoke** deletes the access row and leaves the routing-policy row unchanged.
- Repeated desired-state operations are deterministic and succeed without duplicate audit rows.

A grant creates a missing row, re-enables a disabled row, or replaces/clears its explicit policy. Omitting a policy explicitly selects canonical defaults.

### 3. Null policy means canonical defaults only

A null `routing_policy_id` resolves directly to the defaults owned by `AdmissionPolicy`:

- `routing_policy_id: nil`;
- `allowed_pool_ids: []`;
- `residency_preference: :allow_cold_load`;
- `max_cold_start_ms: 15_000`; and
- `queue_wait_ms: 3_000`.

Orchard does not implicitly search global policies by name, priority, creation time, or any other order.

### 4. Explicit policies are Tenant-scoped or global

A grant may reference:

- a policy owned by the same Tenant; or
- a global policy whose `tenant_id` is null.

A database integrity trigger rejects cross-Tenant policy attachment. Application validation provides a friendly error but is not the integrity boundary. Policy Tenant scope is immutable after creation.

### 5. Pool constraints are not claimed before scheduler support

The current scheduler consumes residency preference and cold-start budgets but does not enforce `allowed_pool_ids` or `preferred_pool_ids`.

This slice persists the apex policy shape but requires both arrays to be empty. The CLI does not expose pool flags. A later scheduler change must remove that constraint only with its own contract, enforcement, and tests.

Policy priority is stored as a constrained value for schema compatibility but is not used for implicit selection.

### 6. Authorization preserves apex failure precedence

Shared preparation performs:

1. request validation and canonicalization;
2. Model identity and active-state resolution;
3. tool support validation;
4. tokenization;
5. context-limit enforcement;
6. Tenant-model authorization and routing resolution; and
7. return of the authorized canonical snapshot.

This preserves `SPEC.md` §5.2. An unauthorized request may contact the tokenizer, but it cannot create a Request, reserve quota, enter a queue, schedule, contact a Node, load a Model, or execute inference.

Missing or inactive Models remain `404 model_not_found`. An existing active Model without an enabled grant returns exact `403 model_not_authorized` with `param=model`.

### 7. Routing is snapshotted into the canonical Request

Authorization returns the resolved policy values. `AdmissionPolicy.resolve/2` applies them to the canonical Request before `RequestOrchestrator` persists it.

The persisted snapshot, not a later mutable policy lookup, governs the accepted Request. Disable, revoke, or later policy changes apply to new authorization checks and do not cancel already authorized Requests.

### 8. The first operator surface is local `orchardctl`

The first slice extends the existing Repo-backed `orchardctl models` command group:

```text
orchardctl models access grant <model_id@version> --tenant <uuid-or-slug> [--routing-policy-id <uuid>]
orchardctl models access disable <model_id@version> --tenant <uuid-or-slug>
orchardctl models access revoke <model_id@version> --tenant <uuid-or-slug>
orchardctl models access list --tenant <uuid-or-slug>
orchardctl models access inspect <model_id@version> --tenant <uuid-or-slug>

orchardctl models routing-policy create (--tenant <uuid-or-slug> | --global) --name <name> --residency-preference <value> [--max-cold-start-ms <n>] [--max-queue-wait-ms <n>]
orchardctl models routing-policy list (--tenant <uuid-or-slug> | --global)
orchardctl models routing-policy inspect --id <uuid>
```

The CLI validates Model and Tenant identities before reporting idempotent outcomes. Policy references are UUID-only to avoid ambiguous lookup.

A partial Admin API or Console surface would expand authorization and compatibility scope without being required to close the public inference defect.

### 9. State changes and audit evidence are atomic

Grant, re-enable, policy replacement, disable, revoke, and policy creation use `AuditWriter.transaction/1`. Mutation and append-only audit either both commit or both roll back.

No-op operations emit no duplicate audit. Payloads may include Tenant, Model, previous/new policy IDs, transition, and operator surface. They exclude credentials, artifact paths, prompts, responses, and raw model content.

### 10. Public authorization is uncached

Listing and authorization query Postgres for each operation. A committed disable or revoke therefore affects the next listing and new preparation check without an invalidation channel.

## Persistence

### `routing_policies`

- UUID primary key.
- Nullable Tenant FK; null denotes an explicitly shareable global policy.
- Nonblank name.
- Empty UUID arrays for allowed and preferred pools in this slice.
- Closed residency preference.
- Non-negative cold-start, queue-wait, and priority values.
- Unique `(tenant_id, name)` for Tenant policies and unique global name for null-Tenant policies.
- Immutable Tenant scope.

### `tenant_model_access`

- Composite primary key `(tenant_id, model_id)`.
- Tenant and Model FKs with cascade delete.
- `enabled` non-null, default true.
- Nullable routing-policy FK with restrictive delete behavior.
- Indexes for Tenant enabled listing, Model lookup, and policy references.
- Database validation that an attached policy is global or belongs to the same Tenant.

## Concurrency

Mutation operations take a transaction-scoped Postgres advisory lock derived from the `(tenant_id, model_id)` identity before reading or writing the access row. This serializes both first creation and later state changes; the composite primary key remains the database backstop against duplicate grants.

The final committed state governs later authorization checks. Already snapshotted Requests are not retroactively changed.

## Migration and rollback

Upgrade procedure:

1. Stop or drain public inference traffic.
2. Back up Postgres.
3. Run the migration.
4. Create explicit policies when defaults are insufficient.
5. Grant approved Tenant/Model pairs.
6. Verify positive listing/inference and negative cross-Tenant denial.
7. Expose the upgraded Controller.

The migration inserts no grants or policies. A schema rollback destroys grant/policy data. An application rollback to globally authorized behavior is a security regression and requires public inference to remain stopped.

## Alternatives rejected

- Automatic grants for every existing Tenant and active Model.
- A legacy-Tenant bypass.
- Authorization before mandatory tokenization/context validation.
- Implicit global/default-policy selection.
- Treating disable and revoke as aliases.
- Exposing unenforced pool-routing flags.
- Shipping only `/v1/models` filtering without inference enforcement.
- Shipping inference enforcement without a supported operator lifecycle.

## Risks

- **Upgrade outage:** deny-by-default blocks traffic until explicit grants exist. Mitigate operationally; do not add a bypass.
- **Rollback exposure:** old application code ignores grant tables. Treat rollback as security-sensitive.
- **Policy scope race:** enforce at the database boundary.
- **Test masking:** model creation fixtures must never grant implicitly.
- **Partial enforcement:** Chat Completions and Responses must share the same preparation path and failure mapping.
- **False routing claims:** keep pool arrays empty until scheduler enforcement is implemented.
