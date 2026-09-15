## Why

Node inventory and diagnosis currently mix admission, runtime evidence, and lifecycle actions on long pages.
Operators need explicit navigation and recovery that preserves the authority of current evidence.

## What Changes

- Separate Nodes into Inventory, Admission Review, Runtime, and Diagnostics sections and Node detail into Overview, Evidence, and Actions.
- Name durable Node rows Node Inventory and resolved Runtime diagnostic targets Effective targets, explain how empty Inventory relates to enrollment, join, and admission candidates, and link empty Inventory to Admission Review and Runtime without initiating another read or probe.
- Preserve labeled last-successful evidence after refresh failure while blocking actions until recovery.
- Preserve admission return context, focus action previews, and focus the next enrollment step after an explicit Prepare action.

## Capabilities

### New Capabilities

- `console-node-navigation`: Task-focused Node navigation, evidence recovery, and enrollment handoff context.

### Modified Capabilities

None.

## Impact

SPEC.md remains unchanged and authoritative.
This change builds on the Add Node enrollment flow without changing enrollment custody, lifecycle transitions, trust, scheduling, or action authorization.
Affected surfaces are three Console LiveViews, their tests, and docs/DESIGN.md.
