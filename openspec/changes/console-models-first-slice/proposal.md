## Why

Operators currently navigate between Models and Model Hub to import a model, with unclear discovery filters and no guarantee that the inspected provider revision is the revision imported.
The Console needs one Models entry and a truthful path from provider evidence to the stored catalog record.

## What Changes

- Consolidate catalog and discovery under Models with Catalog and Discover navigation, retaining the existing Model Hub URL.
- Distinguish empty catalogs, filtered results, provider errors, and unavailable revision evidence.
- Label discovery filters explicitly and use Import for the import action.
- Carry the selected server-held revision into the existing coordinator and reject a changed provider snapshot before downloading.
- Show the resulting registered catalog identity and artifact digest, retaining separate activation and runtime readiness.

- Add visible download management and cooperative pause, resume, and cancel before Catalog finalization.
- Restore terminal download recovery through exact-revision restart and history removal.
- Make Catalog directly reachable with imported models and session download activity.

## Capabilities

### New Capabilities

- `console-models-journey`: Navigation, discovery, exact revision import, and catalog handoff.

### Modified Capabilities

None.

## Impact

SPEC.md sections 6.5 and 10.2 remain unchanged and authoritative.
This implements the existing artifact identity contract and changes Console navigation and failure handling, without new persistence, permission, credential, or runtime semantics.
Affected surfaces are Console components, routes, Models and Model Hub LiveViews, the import pipeline, their tests, and docs/DESIGN.md.
