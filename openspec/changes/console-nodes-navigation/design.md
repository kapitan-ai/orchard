## Decisions

Use whitelisted query parameters for reloadable sections, with a safe default for unsupported values.
Hide inactive sections from both keyboard navigation and the accessibility tree.
Keep target identity and refresh status outside section-specific content.

Retain last-successful evidence only for the same target, label it stale after a failed read, and block action preview and execution until refresh succeeds.
Clear confirmation when refreshed action consequences change.
Restore focus after manually opening or closing a preview; automatic polling must not move focus.

Enrollment handoff opens the registered Node's Actions section and preserves Admission as its return destination.
An explicit successful Prepare action focuses the enrollment heading for the next step.
Registration remains distinct from admission and runtime readiness.
Label durable Node rows as Node Inventory entries and resolved Runtime diagnostic targets as Effective targets.
Empty Inventory links patch to Admission Review and Runtime through the existing section navigation, reuse the loaded page data, and initiate no additional read or Runtime Endpoint probe.

## Risks and validation

Stale evidence must never authorize lifecycle mutation.
Regression tests cover refresh failure and recovery, changed previews, invalid sections, target changes, admission return context, and manual enrollment focus.
Browser review covers selected-section visibility and narrow layouts.
No database migration is required.
