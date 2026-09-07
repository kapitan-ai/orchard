# ADR 0031: Workspace display and Access navigation

## Status

Accepted.
Supersedes Organization as the product-facing Tenant label in ADR 0002 and ADR 0020 without changing their identity or authority contracts.

## Context

Operators need a clear starting scope and a way to distinguish model authorization, Portal membership, and inference credentials.
The existing Tenant already supplies the governance boundary required by SPEC.md sections 5.2, 6.6, 7.2.3, and 7.4a.
Renaming that boundary in storage or adding another hierarchy would introduce compatibility risk without resolving the navigation problem.

## Decision

Use Workspace for the existing Tenant in Console and Developer Portal, grouped under Access in Console navigation.
Keep Tenant UUIDs, slugs, schemas, CLI vocabulary, API fields, CSV `organization`, audit identifiers, and Portal routes compatible.
Retain `/console/tenants` entry points while using `/console/access` for new navigation.
Team remains optional API Client grouping metadata and provides no authorization or membership boundary.

Use the existing seeded Tenant as the default Workspace.
Display its untouched built-in name as Default workspace; preserve customized names and identify the default by UUID.
Do not create replacement records on page reads or infer grants, credentials, users, or readiness from default status.

Separate Workspace management sections from the guided six-step colleague handoff.
Keep one Workspace and one exact Model visible through model-access review, Portal invitation, scope review, manual colleague handoff, and first-request guidance.
The existing Console session marker is not a per-person role identity, and the shared model-access transaction service is not a caller authorization adapter.
This increment therefore reads model grants and prepares scoped operator commands rather than adding direct browser grant mutations.
Actual Portal acceptance and key minting remain in the Developer Portal under their existing one-time-secret contract.

## Consequences

Existing installations retain their records, automation, and credential scope.
Operators gain a default starting point without an implicit grant or new hierarchy.
Model-grant changes still require the supported operator command workflow until an authenticated, authorized, leader-aware browser command adapter is separately implemented.
Runtime readiness and successful inference remain evidence-based outcomes, not completion inferred from navigation or invitation state.

## SPEC.md impact

Updates sections 2.3 and 7.4a for Workspace terminology, default scope, compatible navigation, and exact-model request guidance.
The governance and identity boundaries remain unchanged.
