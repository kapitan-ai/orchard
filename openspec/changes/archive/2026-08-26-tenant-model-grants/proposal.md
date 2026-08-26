# Tenant-scoped model grants and routing snapshots (#219)

## Why

`SPEC.md` requires tenant-scoped model visibility and inference authorization, but Orchard currently exposes every active catalog model to every authenticated Tenant and accepts any active model during shared Chat Completions and Responses preparation.

The effective Tenant is already resolved by public authentication. The missing persistence, operator lifecycle, filtered listing, and pre-admission enforcement are a direct access-control gap and block specification-compliant pilot approval under #196.

## What changes

- Add deny-by-default `routing_policies` and `tenant_model_access` persistence matching the apex contract.
- Add supported local operator commands to create and inspect constrained routing policies and to grant, disable, revoke, list, and inspect tenant-model access.
- Keep grant decisions keyed only by effective Tenant and catalog Model, regardless of direct or Service Account credential ownership.
- Filter `GET /v1/models` to active Models with an enabled grant for the effective Tenant.
- Resolve the Console Playground's effective Tenant to the seeded legacy Tenant and filter its model picker and runs to that Tenant's enabled grants.
- Enforce model access in the shared Chat Completions and Responses preparation path after tokenization/context validation and before Request persistence or admission/execution side effects.
- Return exact `403 model_not_authorized` for an existing active but ungranted or disabled Model.
- Resolve a null grant policy to the existing canonical routing defaults; attach an explicit same-Tenant or global policy only by UUID.
- Persist the resolved routing policy snapshot on authorized Requests.
- Audit state-changing grant, disable, revoke, and routing-policy operations without credentials, artifact paths, prompts, or responses.
- Migrate without implicitly granting existing Tenants access to existing active Models.

## Out of scope

- Weakening `SPEC.md` or adding a pilot-only global authorization bypass.
- Cancelling already authorized or running Requests after a later revoke.
- Implicit selection of a global routing policy by name, priority, or creation order.
- Executing non-empty pool allowlists or preferences before scheduler support exists.
- A partial Admin API or Console grant-management surface in the first slice.
- A Console-only grant scope or per-operator Console Tenant identity.
- Model import, activation, artifact distribution, placement, or scheduler redesign.

## SPEC.md impact

This change implements the existing apex requirements for:

- §5.2 admission ordering and failure precedence;
- §6.6 model publication and tenant visibility;
- §7.2 effective-Tenant model listing and exact public errors;
- §10.9 governance evidence;
- persisted `routing_policies` and `tenant_model_access` relations; and
- the canonical resolved routing snapshot used by Requests.

No `SPEC.md` behavior is relaxed. Authorization remains after mandatory tokenization and context-limit enforcement, while denial remains before Request creation, quota, queueing, scheduling, node contact, model loading, or inference execution.

## Rollout

The migration creates no grants and no implicit default policy row. Operators must stop or drain public inference, migrate, explicitly create any desired policies and grants, verify positive and negative Tenant behavior, and only then expose the upgraded Controller.

Rolling application code back to a version that ignores grants reintroduces the access-control defect and is not a security-preserving rollback.

The Console Playground shares the seeded legacy Tenant, so operators must grant a Model to that Tenant before the Playground can list or run it, and that grant equally authorizes existing legacy-Tenant API credentials for the same Model.

## Delivery state

Issue #219 owns this contract and implementation. Issue #196 remains the pilot-approval owner.
