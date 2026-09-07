## Why

The Console exposes Organization and Tenant terminology while operators need a clear place to manage Workspace access and help a colleague use a model.
The existing page mixes scope creation, Portal membership, and credentials, making it difficult to see which action grants which authority.

## What Changes

- Replace the Organizations navigation destination with Access and make Workspaces its primary entry.
- Present the existing seeded Tenant as the default Workspace so onboarding does not require creating a scope first.
- Adopt Workspace as the one-to-one product-facing label for the existing Tenant governance boundary in Console and Developer Portal prose.
- Preserve Tenant schemas, IDs, machine-facing API and CLI names, audit identifiers, existing Portal URLs, and legacy Console links.
- Separate a Workspace's Overview, Model access, Portal users, and API credentials into real navigable sections.
- Define a guided colleague handoff that keeps one Workspace and the selected model visible through model access, invitation review, and delivery instructions.
- Preserve separate model grants, Portal authentication, API credentials, and cluster administration; no action implies completion of another.
- Keep Team as optional API Client grouping metadata, with no new membership or authorization object.

## Capabilities

### New Capabilities

- `console-access-workspaces`: Access navigation, Workspace presentation, compatibility routes, scoped sections, and grounded colleague handoff.

### Modified Capabilities

None of the existing authorization, credential issuance, or inference requirements change.
Existing product prose referring to Organizations must be reconciled with the new display terminology as implementation proceeds.

## Impact

SPEC.md impact: update the Console and Developer Portal product terminology and navigation descriptions, while retaining the normative Tenant authorization boundary and existing role and credential semantics.
Update docs/glossary/CONTEXT.md, docs/DESIGN.md, relevant Portal and provisioning documentation, and the explanatory wording in affected OpenSpec main specs.
The proposal remains subordinate to the current SPEC until these contract changes are made together with implementation.
Affected code includes Console navigation, routes, current Tenant LiveViews or their successors, Workspace-scoped model-grant integration, and Portal display copy.
No database or public machine-protocol migration is proposed.
The implementation must preserve the accepted Models and Nodes navigation and their regression coverage.
