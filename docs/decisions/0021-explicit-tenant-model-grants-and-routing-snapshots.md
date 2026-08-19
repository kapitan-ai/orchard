# ADR: Explicit Tenant-model grants and routing snapshots

## Status

Accepted.

## Context

`SPEC.md` requires active catalog state, an enabled Tenant grant, and routing resolution before a Model is visible or usable by a public inference caller.
Current code resolves an effective Tenant but lists every active Model and accepts any active Model during shared request preparation.
The apex schema permits Tenant-scoped and global routing policies and allows a grant to omit a policy, but it does not define an implicit global-policy selection order, migration backfill, or whether disable and revoke are identical.
The scheduler does not yet enforce pool allowlists or preferences.

## Decision

Model access is deny-by-default and keyed only by effective Tenant plus catalog Model.
Existing active Models, existing Tenants, and the legacy Tenant receive no automatic grants.

An enabled access row authorizes new listing and inference checks.
Disable preserves the row and its policy while denying access.
Revoke deletes only the access row.
Repeated desired-state operations are deterministic and do not create duplicate audits.

A null routing-policy reference resolves directly to canonical `AdmissionPolicy` defaults.
Orchard does not implicitly select a global policy by name, priority, creation order, or scope.
An explicit policy must be global or owned by the same Tenant; the database enforces that boundary.

The initial routing-policy surface requires empty pool allowlists and preferences because the scheduler cannot yet enforce them.
No operator interface claims pool isolation before that enforcement exists.

Authorization occurs at shared request preparation after Model validation, tokenization, and context-limit enforcement, preserving `SPEC.md` failure precedence.
Denial occurs before Request persistence, quota, queueing, scheduling, Node contact, Model loading, or inference execution.

The first supported operator surface is local `orchardctl models` commands for policy create/list/inspect and access grant/disable/revoke/list/inspect.
A partial Admin API or Console surface is not required for the first slice.

Authorized Requests persist the resolved routing snapshot.
A later disable, revoke, or policy mutation governs new checks and does not retroactively cancel an already authorized Request.

## Consequences

Upgrading Controllers is intentionally fail-closed until operators create explicit grants.
The rollout must stop or drain public inference, migrate, grant, verify positive and negative Tenant behavior, and only then expose the upgraded Controller.
There is no temporary global-access feature flag.

Application rollback to code that ignores grants reintroduces the access-control defect and is not security-preserving.
Pool-routing enforcement requires a later contract and scheduler change before non-empty pool arrays can be accepted.

State-changing policy and access operations require atomic append-only audit evidence without credentials, artifact paths, prompts, or responses.

## SPEC.md impact

No apex behavior is weakened.
This decision implements and makes explicit the operational choices under `SPEC.md` §5.2, §6.6, §7.2, §10.9, and the persisted `routing_policies` and `tenant_model_access` relations.

The associated OpenSpec change is `openspec/changes/tenant-model-grants/` and issue #219 owns implementation.
