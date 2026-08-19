# Tasks: tenant-scoped model grants and routing snapshots

## 1. Contract and review

- [x] 1.1 Review `proposal.md`, `design.md`, and the tenant-model-access delta against the cited `SPEC.md` clauses.
- [x] 1.2 Confirm the initial operator surface is local `orchardctl`, with no partial Admin API or Console requirement.
- [x] 1.3 Confirm deny-by-default rollout with no automatic grant for existing Models, Tenants, or the legacy Tenant.
- [x] 1.4 Confirm null policy means canonical defaults and never an implicit global lookup.
- [x] 1.5 Confirm pool arrays remain empty until scheduler enforcement exists.
- [x] 1.6 Validate the change strictly before production code begins.

## 2. Persistence foundation

- [x] 2.1 Add `routing_policies` with Tenant/global scope, closed residency preference, non-negative budgets/priority, empty pool-array constraints, indexes, and immutable Tenant scope.
- [x] 2.2 Add `tenant_model_access` with composite identity, Tenant/Model cascade FKs, enabled state, restrictive policy FK, and indexes.
- [x] 2.3 Enforce at the database boundary that an attached policy is global or belongs to the grant Tenant.
- [x] 2.4 Add `RoutingPolicy` and `TenantModelAccess` Ecto schemas and associations.
- [x] 2.5 Add migration tests for uniqueness, ranges, enum values, cascades, policy delete restriction, scope immutability, and cross-Tenant policy rejection.

## 3. Access and routing domain

- [x] 3.1 Add atomic audited routing-policy create/list/inspect operations.
- [x] 3.2 Add deterministic grant, re-enable, policy replacement, disable, revoke, list, inspect, and authorize operations.
- [x] 3.3 Serialize concurrent grant changes and converge safely after duplicate-create races.
- [x] 3.4 Add one audit per actual state change and none for no-op outcomes.
- [x] 3.5 Expose canonical default routing values from `AdmissionPolicy` without duplicating constants.
- [x] 3.6 Add domain tests for lifecycle transitions, policy scopes, two-Tenant isolation, concurrency, audit atomicity, and default/explicit routing resolution.

## 4. Public model listing

- [x] 4.1 Add `Models.list_active_models_for_tenant/1` while preserving the trusted global catalog query.
- [x] 4.2 Make `ModelsController` use the effective Tenant assigned by `RequestContext`.
- [x] 4.3 Update controller documentation to describe active-and-authorized listing.
- [x] 4.4 Test active granted, ungranted, disabled, revoked, inactive, cross-Tenant, direct-token, and Service Account listing behavior.

## 5. Shared inference authorization

- [x] 5.1 Enforce access in `RequestPreparation` after tokenization/context validation and before returning an executable canonical Request.
- [x] 5.2 Apply the resolved routing snapshot through `AdmissionPolicy` before Request persistence.
- [x] 5.3 Add exact `403 model_not_authorized` normalization and public mapping.
- [x] 5.4 Preserve missing/inactive `404 model_not_found` precedence.
- [x] 5.5 Test authorized and denied behavior for both Chat Completions and Responses.
- [x] 5.6 Prove denial happens before Request persistence, quota, queue, scheduler, Node, model-load, or inference side effects.
- [x] 5.7 Prove tokenizer/context failures precede authorization as required by `SPEC.md`.
- [x] 5.8 Prove committed disable/revoke affects new listing and inference checks without cancelling already authorized Requests.

## 6. Operator lifecycle

- [x] 6.1 Add shared Model, Tenant UUID/slug, and policy UUID reference parsing.
- [x] 6.2 Add `orchardctl models access grant|disable|revoke|list|inspect`.
- [x] 6.3 Add `orchardctl models routing-policy create|list|inspect`.
- [x] 6.4 Render deterministic mutation/no-op outcomes without credentials or artifact paths.
- [x] 6.5 Test help, parsing, missing identities, scope failures, lifecycle distinctions, default/explicit policy output, and repeat operations.
- [x] 6.6 Document deny-by-default rollout and command usage in the CLI/operator documentation.

## 7. Fixture and regression migration

- [x] 7.1 Add explicit grant helpers; do not make Model creation grant implicitly.
- [x] 7.2 Update successful public API and direct preparation tests to create explicit grants.
- [x] 7.3 Preserve global catalog tests that intentionally exercise trusted unscoped listing.
- [x] 7.4 Preserve the existing streaming `chatcmpl-*` public-ID persistence regression.
- [x] 7.5 Convert the existing two-Tenant idempotency test to grant both Tenants and add a separate one-Tenant-only denial test.
- [x] 7.6 Search the whole test tree for active ungranted success fixtures and reconcile each explicitly.

## 8. Validation and rollout

- [x] 8.1 Run strict OpenSpec validation after every contract change.
- [x] 8.2 Run focused migration, domain, listing, inference, error, and CLI tests during implementation.
- [x] 8.3 Run `mise exec -- mix format`.
- [x] 8.4 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 8.5 Run `mise exec -- mix credo --strict`.
- [x] 8.6 Run `mise exec -- mix dialyzer`.
- [x] 8.7 Run `mise exec -- mix test`.
- [x] 8.8 Run `mise exec -- mix test --cover`.
- [x] 8.9 Review generated specifications for placeholders and accidental global-access language.
- [x] 8.10 Document the stop/drain, migrate, grant, verify, and expose rollout procedure.
