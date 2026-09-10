## Why

Console admission currently uses shared Basic Auth and a boolean browser marker, while APIs authenticate API Clients and normal CLI authority is migrating to Controller-owned operations.
A named, revocable principal and one action-time policy contract are needed before Orchard can offer consistent scoped administration across these surfaces.

## What Changes

This package is an **accepted target contract**, reconciled with `SPEC.md` §10.11 and accepted ADR 0033.
Acceptance settles the policy decisions and supplies the contract for a separately reviewed implementation.
It does not implement named authentication or schema changes, authorize production cutover, or claim a COMPLETE command family.
The change remains open with implementation tasks pending and the current pre-cutover baseline explicitly retained.

- Define principal, credential, session, grant, action, resource, scope, and audit actor as separate concepts with a default-deny Controller-owned authorization boundary.
- Introduce named Console Identities and revocable server-side Console Sessions, separate from non-interactive API Clients and Portal Users.
- **BREAKING**: Replace shared Basic Auth and anonymous Console audit attribution at an explicit cutover, with no conversion of old browser markers into named sessions and no authentication fallback.
- Preserve local first-admin recovery and add a bounded operator-controlled first Console Identity setup flow without environment-seeded admins or a network bootstrap endpoint.
- Require fresh authorization for every protected read, preview, and mutation, including already-mounted LiveViews, using current principal, credential or session, grants, resource ownership, and leadership state.
- Make credential inspection and revocation the first COMPLETE family across Console, authenticated Admin API, and portable CLI, with explicit scope, concurrency, audit, confirmation, failure, and secret-handling semantics.
- Preserve Portal, Public Inference, Node trust, Peer Grant, and host-local recovery boundaries.
- Defer other operation-family migrations, fine-grained delegated agent credentials, and WebMCP exposure to separately reviewed changes.

## Capabilities

### New Capabilities

- `management-authorization`: Named Console identities and sessions, shared action-time authorization, trust-domain separation, cutover, and accountable audit actors.
- `credential-management`: Complete metadata inspection and revocation for tenant-direct API Keys, API Client API Tokens, and Console Sessions.

### Modified Capabilities

- `operator-command-authority`: Define the family completion gate and explicitly migrate credential inspection and revocation through shared Controller authority.
- `developer-api-key-portal`: Replace anonymous Console attribution and select explicit audit schemas by the executing operation while preserving Portal-origin payloads.

## Impact

### SPEC.md impact statement

`SPEC.md` §10.11 now owns the accepted core invariants, and the following affected sections have been reconciled with ADR 0033 and these deltas.
The current implementation remains the pre-cutover baseline; later implementation review must prove runtime behavior, migrations, tests, compatible-writer closure, and cutover against the accepted contract before declaring completion.

| Section | Accepted target change or retained invariant |
|---|---|
| §§2.3, 7.1 | Add Console Identity and Console Session without merging Portal User or API Client identities; reconcile the Admin API summary's `admin/tenant-admin` wording with retained cluster-admin API Client admission. |
| §§7.3, 7.4 | Define shared operation policy and credential-family endpoints; preserve Operator API cluster operator/admin and existing Admin API cluster-admin admission. |
| §7.4a | Preserve Portal scope and inference-key independence; change only attribution for Console-originated Portal administration. |
| §8 | Add pending-setup identities, sessions, initial RoleBindings, and typed/schema audit columns; reconcile audit foreign-key `ON DELETE SET NULL` behavior so cleanup cannot null historical actor/authentication/target references. |
| §§10.1, 10.4, 10.11 | Add named Console authentication, session lifecycle, explicit action/resource/scope evaluation, and cross-surface authority rules. |
| §§10.2, 10.3, 10.5, 10.6 | Preserve inference principals and credential formats, API Client disablement, certificates, node-join Bootstrap Tokens, and Peer Grant authority. |
| §§10.8, 10.9 | Store only credential/session verifiers; replace the explicit null Console `actor_id` rule with named attribution, including a deliberate amendment of affected closed audit allowlists. |
| §11.9 | Preserve `cluster init` and protected one-time output; add bounded named Console setup and migrate only the complete credential inspection/revocation family away from local Repo authority. |
| §13 | Add authority-writer compatibility, named-Console cutover and rollback states, persistent service/ingress fencing including direct HTTP/LiveView, isolation of incompatible DB writers, and unsupported-downgrade limits. |

Accepted [ADR 0033](../../../docs/decisions/0033-cross-surface-authorization.md) refines ADR 0024 and the Console identity boundary without silently superseding accepted ADRs 0002, 0004, 0007, 0011, or 0020.
Affected implementation areas are Controller governance, authentication, audit, Console LiveViews, API request contexts, and CLI client routing.
This documentation-only change adds no runtime dependency or migration.
The later implementation must stage database compatibility before Console cutover and pass the security and parity scenarios in this package.
