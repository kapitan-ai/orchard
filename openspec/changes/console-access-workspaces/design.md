## Context

The existing Console combines scope creation, Portal users, tenant-direct credentials, and API Clients under Organizations.
The durable boundary is `Tenant`, and model access remains deny-by-default under SPEC.md sections 5.2, 6.6, 7.2.3, and 10.9.
SPEC.md section 7.4a gives Portal Users a separate interactive session and self-service tenant-direct API Keys.
Console authentication currently supplies a Basic-auth or development session marker, not a per-person Workspace role identity.
The shared model-access service exists, but calling it directly from a new LiveView would not itself establish authenticated, leader-aware command authority.

## Goals / Non-Goals

**Goals:**

- Give operators an Access destination and a clear, plural Workspace list.
- Keep one Workspace and an exact catalog model visible through a colleague handoff.
- Preserve return paths, deep links, keyboard focus, empty/error recovery, and the accepted Models and Nodes navigation.
- Use real Portal and credential operations where implemented and truthful handoffs where authority or runtime support is absent.

**Non-Goals:**

- No new organization hierarchy, installation-wide Workspace switcher, or ownership transfer of Models and Nodes.
- No new Team identities, memberships, policy, or quotas.
- No schema, API field, CLI flag, audit identifier, or existing Portal URL rename.
- No synthetic invitation acceptance, automatic email, automatic model grant, credential impersonation, or simulated request success in the product.
- No new browser-based cluster RoleBinding editor or actor-specific Console RBAC in this change.

## Decisions

### Product terminology with stable machine contracts

Use Workspace in Console and Developer Portal headings, forms, explanations, and new navigation.
A Workspace maps to exactly one existing Tenant UUID; existing IDs, slugs, records, grants, and isolation survive unchanged.
Keep `tenant_id`, `/admin/v1/tenants`, local command vocabulary, CSV `organization`, audit event names, and `/portal/:organization_slug` URLs stable.
Describe this mapping in SPEC.md section 2.3, section 7.4a, the glossary, and relevant provisioning/Portal documentation before changing UI copy.
Do not blanket-replace Organization or Tenant inside protocol examples, code identifiers, historical records, or accepted technical contracts.
A wholesale storage/protocol rename was considered but would add compatibility risk without improving the intended navigation.

### Default Workspace for onboarding

Fresh installations already seed one Tenant with the stable UUID `00000000-0000-0000-0000-000000000000` and slug `legacy` in the governance foundation migration.
Use this record as the default Workspace rather than creating a second onboarding Tenant.
Display the untouched built-in name `Legacy Single Tenant` as `Default workspace` in product surfaces; preserve an operator-customized name and identify the same record with a Default badge.
Default identity is determined by the stable UUID, not by matching a name or slug.
Keep persisted names, slug, IDs, credentials, grants, and legacy Portal links compatible.
Show this Workspace first in Access with a primary Open workspace action and keep Create Workspace secondary.
When it is the only Workspace, a new colleague handoff starts in it directly with its identity visible, avoiding a redundant scope-creation or selection form.
When multiple Workspaces exist, require deliberate scope selection for a new handoff; never overwrite an explicit Workspace route or an existing scoped draft with the default.

Default means a starting governance scope, not an automatic model grant, invited user, credential, quota exemption, or ready runtime.
The Console Playground's existing seeded Tenant maps to this same default Workspace; request guidance must still report its actual scope and authorization.
The existing migration supplies the fresh-install record; repeated page visits, restarts, or upgrades must not insert duplicates or reset customized state.
If the expected seeded record is missing or cannot be read, show a setup/recovery error rather than silently creating it from a page read or selecting another Workspace.
Additional Workspace creation remains available for later separation of projects or access.

### Access and Workspace routes


| Destination | New canonical route | Content |
| --- | --- | --- |
| Access | `/console/access` | Workspace list, scope explanation, create action |
| Workspace list alias | `/console/access/workspaces` | Same list, no second competing destination |
| Create Workspace | `/console/access/workspaces/new` | Separate creation form with a return path |
| Workspace detail | `/console/access/workspaces/:id` | Overview by default |
| Workspace sections | Detail URL with whitelisted `section` | Overview, Model access, Portal users, API credentials |
| Colleague handoff | Detail URL with explicit handoff state | Scoped model and invitation journey |

Existing `/console/tenants` and `/console/tenants/:id` remain compatible entry points to the same underlying records and authentication boundary.
Preserve useful legacy anchors with a whitelisted client hook that reads the initial URL fragment and patches to its corresponding section.
Fragments are not sent to Phoenix, so this mapping cannot rely on server-side handle_params alone.
The hook accepts only known legacy fragment identifiers, preserves the server-resolved Workspace, and ignores unknown fragments without changing scope.
Workspace section navigation switches content rather than scrolling through an unrelated stack of cards.
Each section retains the Workspace name, slug, and accessible return control.
Access is a cluster-level navigation container; the first increment manages Workspace access and explicitly distinguishes cluster administration without presenting an unimplemented cluster-permissions tab.

### Two implementation increments

**Increment A: navigation and real scoped management.**
Deliver the terminology mapping, compatible routes, Workspace overview and sections, real model-access reads, and the existing Portal user/API credential management paths.
Model access shows exact catalog identity and enabled, disabled, or not-granted state, with failed reads distinct from denial or emptiness.
Offer a scoped administrator handoff using the supported operator workflow instead of a new unchecked grant mutation.
Team appears only as API Client grouping metadata, with an Ungrouped state and no membership controls.

**Increment B: guided colleague handoff.**
Carry one server-resolved Workspace through Model access, Portal invitation, Review scope, and Colleague handoff.
A six-step orientation includes Choose Workspace and First request, but completion reflects actual evidence rather than advancement through the UI.
When model access is missing, preserve the colleague email and model context while preparing the existing operator handoff; refresh reads confirm whether a grant actually changed.
Creating a Portal User creates its invited identity but does not issue an invite link.
Copy invite issues or reissues a fresh single-use token through the existing service, invalidating the previous token.
If link issuance fails after user creation, retain the persisted user state and retry issuance without recreating the user.
The flow preserves expiry, disablement, and one-time-secret contracts.
The operator separately copies and delivers the invite URL; no email is implied.
Portal acceptance and key creation occur in the actual Portal as the colleague, not through a Console role-switch simulation.

The personal developer path uses the Portal User's own tenant-direct API Key, as specified in section 7.4a.
Application/API Client provisioning remains a separate workflow; a Portal invitation does not create an API Client or a RoleBinding.
The existing PortalActivationCurl model selector currently returns no models even though tenant-filtered active listing is implemented.
Reconcile that selector with the existing authorization read model, including exact-version selection and exclusion of inactive or unauthorized models.
Preserve the handoff-selected exact Model when it remains authorized; report its absence or changed eligibility rather than silently substituting another Model.
Use deterministic selection only when no exact Model was requested.
Console request examples always use a literal placeholder credential and remain inert.
Only the actual Portal mint response may show that Portal User's newly minted secret or curl during its existing one-time display; no key is carried back into Console handoff state.
Neither surface may select somebody else's token or mark an unexecuted request successful.
The existing Console Playground resolves its seeded legacy Tenant and must not be presented as a request executed in the selected Workspace.

### Journey presentation and review criteria

The guided colleague flow has six ordered steps: Workspace, Model access, Portal invitation, Review scope, Colleague handoff, and First request.
Keep the full sequence and current step number visible, with unavailable future steps dimmed and non-interactive.
Each step replaces the previous content instead of appending another card or scrolling to a separate destination.
The management sections support returning operators and do not substitute for this guided journey.
Use Orchard's existing surface, typography, icon, color, focus, motion, and responsive tokens under docs/DESIGN.md.

Starting in the only default Workspace resolves step 1 visibly; it does not remove that step, renumber the journey, or imply Model access has been granted.
The current Workspace name remains visible through all subsequent steps, alongside exact Model identity where relevant.
When selection is necessary, explain that the list contains available destinations, not the invitee's permissions.
Model access in this journey applies to one Workspace; administration of one Model across multiple Workspaces remains a separate Model-management task.

Back and retry within a Workspace preserve safe non-secret selections and inputs, with focus returned to the relevant heading or originating control.
A previously activated Portal User with a missing Model grant returns to the grant/handoff task without requiring another invitation or resetting unrelated completed work.
Runtime availability, Model grant state, invitation state, and credential readiness are labeled separately; a successful step does not imply the next condition is met.
Verify navigation and recovery at narrow widths with natural page scrolling, reachable bottom controls, and no document-level horizontal overflow.

### Authority and recovery


Existing Console authentication and each existing service's server-side scope checks remain mandatory.
New model grant mutations are deferred until an authenticated, authorized, leader-aware Controller command path is explicitly available; a direct `Models.Access` call is not sufficient.
The denial branch from a prototype does not justify inventing a per-person Console role system.
All child-resource reads and mutations resolve the Workspace from the server-held target and verify that resource ownership matches it.
Changing Workspace clears scoped selection, invitation draft, and secret-bearing UI state; Back within the same Workspace retains non-secret inputs where safe.
A Workspace selection list describes destinations and never claims that the invitee has access to every listed Workspace.
Re-read relevant scope and status at submission; stale data or unavailable services cannot display successful mutations.
Do not put credentials, invite secrets, or raw tokens into query parameters, data attributes, flashes, reports, or durable handoff drafts.

### Durable rationale

Update the glossary's current instruction to avoid Workspace and add a focused decision record for display terminology versus stable machine vocabulary.
Keep the prior API Client/Team decision intact and explicitly preserve its non-authorizing Team semantics.
The existing Models slice remains separate; it does not silently acquire Workspace or identity-management scope.

## Risks / Trade-offs

- Mixed display and machine vocabulary can confuse operators; document the exact mapping near integration examples and retain recognizable command names.
- A scoped page can imply resource ownership; keep Models and Nodes cluster-scoped and describe grants as Workspace access to exact catalog records.
- Creating an invitation can be mistaken for delivering it or granting inference; show persisted invitation state, manual delivery, and separate credential/model access explicitly.
- The guided journey cannot complete every step in every deployment; preserve progress and show the real blocker rather than a simulated success.
- Legacy deep links can target hidden content; cover old routes and section anchors in browser and route regressions.

## Migration Plan

First reconcile SPEC, glossary, tactical design, and product docs with the display mapping.
Then add compatible routing and Workspace sections, followed by the scoped handoff increment.
No data migration is required.
Keep existing routes and machine fields through rollout; rollback restores the old display without transforming records or credentials.
Run the required Elixir workflow, coverage, strict OpenSpec validation, and light/dark/narrow browser checks for each implementation increment.

## Open Questions

The proposal recommends the display-only rename boundary and Team-as-metadata behavior above.
A first-class Team system and a new authenticated Console actor model require separate product and security decisions and are not prerequisites for Increment A.
