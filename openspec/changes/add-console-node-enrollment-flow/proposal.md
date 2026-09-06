## Why

Orchard already implements secure Node Enrollment creation, certificate-backed registration, explicit Node Admission, and automatic activation after fresh authenticated evidence.
The Console does not expose the normal operator journey that connects those capabilities.
Operators must discover CLI commands from a candidate detail screen, create protected output outside the Console, transfer it to the target Mac, and manually reconstruct where registration and admission stand.

A moderated usability study of the proposed Console flow found one task-blocking problem: the operator could not determine how to carry the Enrollment Bundle to the target Mac or which command consumed it.
The revised prototype resolved that failure by presenting one recommended order, a one-time bundle download, the exact target-Mac command, automatic status refresh, explicit admission, and clear failure recovery.

## What Changes

- Add an **Add Node** action to the Console Nodes workspace.
- Add a guided Controller Console flow for preparing a new machine, creating one Node Enrollment, downloading its one-time bundle, and monitoring registration automatically.
- Show the exact `orchardctl node join --enrollment-bundle PATH` command and identify that it runs on the target Mac.
- Keep the Enrollment in `pending_publication` until the authenticated LiveView client reports that browser delivery started successfully.
- Mark failed browser delivery as `output_failed`, never redisplay the same secret, and direct the operator to create a new enrollment.
- Preserve explicit human Node Admission and automatic `admitted -> active` promotion from fresh healthy authenticated evidence.
- Clarify that the initial `general` Pool is admission intent, not trust, and remains changeable during admission review.
- Add reusable Console design rules for guided progress, one current blocker, automatic polling, one-time secret output, and recovery.
- Keep packaged multi-Mac acceptance, setup resumability across app restarts, and automatic admission outside this slice.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `operator-first-run-journey`: Adds the Controller Console Node Enrollment flow, browser-delivery custody rules, automatic registration monitoring, and handoff into explicit admission review.

## Impact

- Product contract: adds guided Console behavior under the existing Controller-plus-worker journey without claiming packaged multi-Mac support.
- Console: adds one LiveView route, Add Node entry point, guided UI, browser-download hook, and focused tests.
- Enrollment domain: centralizes bundle construction so CLI and Console produce the same versioned artifact.
- Shared endpoint discovery: makes non-secret Controller endpoint metadata available to both CLI and Console without adding a reverse dependency.
- Security: one-time Bootstrap Token material remains response-only, is not stored in client persistence, and cannot be redisplayed.
- `SPEC.md`: no lifecycle, trust, scheduling, or packaging semantics change.
