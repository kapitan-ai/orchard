## Context

The secure enrollment tracer already owns the durable identity and trust transitions.
`Orchard.NodeEnrollments.create/2` allocates a `provisioned` Node and a `pending_publication` Enrollment while returning the Bootstrap Token exactly once.
`mark_issued/2` makes that Enrollment redeemable only after protected output publication succeeds.
`orchardctl node join --enrollment-bundle PATH` validates the bundle locally, pins the Controller, generates the Node key locally, redeems the token, and registers the Node.
Node Admission remains an explicit administrator mutation, and later fresh healthy authenticated evidence advances `admitted -> active` automatically.

The Console currently exposes inventory, pending admission review, detailed status, and action previews.
It does not create or publish Node Enrollment Bundles.

## Goals / Non-Goals

**Goals:**

- Connect the existing secure domain operations through a usable Console journey.
- Give the operator one recommended order and identify where every action runs.
- Produce the same versioned bundle from CLI and Console.
- Keep one-time secret output fail-closed across success, client failure, disconnect, and lost acknowledgement.
- Monitor durable registration and activation state automatically.
- Preserve the existing explicit admission and scheduler eligibility boundaries.

**Non-Goals:**

- Implement the target-Mac Orchard.app **Join existing Orchard** workflow.
- Certify packaged multi-Mac operation.
- Add automatic admission.
- Add cross-restart guided-setup checkpoints.
- Add enrollment revocation, reissue, list, or retention management surfaces.
- Treat Pool intent as trust, registration evidence, or a scheduler guarantee.
- Change Node lifecycle states or add a persisted `activating` state.

## Decision 1: One Guided Controller Console Route

The Nodes workspace links to `/console/nodes/new`.
One LiveView owns the Controller-side sequence:

1. Explain that the operator is preparing a new machine.
2. Separate the validated source-development split-role path from the packaged multi-Mac rehearsal path and name the packaged path's remaining prerequisites and acceptance gap.
3. Collect intended Node name, initial Pool intent, and bundle lifetime.
4. Create one Enrollment and push one browser download event.
5. Show the exact target-Mac join command.
6. Poll the durable Enrollment and Node records every five seconds.
7. When registration completes, link to the existing Node admission review.

The route does not persist arbitrary wizard checkpoints.
Refresh before issuance restarts the explanation and form.
Refresh after issuance recovers from durable Node and Enrollment state only when the URL names that non-secret Enrollment identifier.
The recovery route accepts only Enrollments whose audit metadata identifies the Console publication surface.
Returning to `/console/nodes/new` resets any delivery or monitor state to a fresh enrollment form.
The Bootstrap Token never enters the URL.
Recovery of `pending_publication` shows only that browser confirmation is unresolved and never shows a join command.

## Decision 2: CLI And Console Share Bundle Construction

Bundle construction moves behind one Controller-owned public function that receives the intended Node metadata, expiry, actor, and publication surface.
It reads public Node trust and non-secret Controller endpoint metadata, reconciles stale pending publications, creates the Enrollment, and returns encoded bundle bytes plus non-secret metadata.
The shared function validates bounded display-name, Pool-intent, publication-surface, and expiry inputs before trust reads or persistence so CLI and Console cannot diverge.

The function does not mark the Enrollment issued.
Each publication adapter owns its delivery confirmation:

- CLI confirms exclusive owner-only file publication before `mark_issued/2`.
- Console confirms the client-side browser delivery start before `mark_issued/2`.

The artifact fields and JSON encoding are identical across both adapters.

## Decision 3: Browser Delivery Is One-Time And Fail-Closed

After successful domain creation, the LiveView sends the encoded bundle through one authenticated same-origin LiveView event.
The secret is never placed in a URL, flash message, session, cookie, log, audit payload, `data-*` attribute, or reusable server-side download endpoint.

The client hook:

1. Receives the bytes in memory.
2. Creates an `application/json` Blob.
3. Starts a download with a sanitized filename.
4. Revokes the object URL.
5. Clears its in-memory reference.
6. Reports success or failure with only the Enrollment identifier.

On reported success, the server verifies that the identifier matches the current pending issuance and calls `mark_issued/2`.
On reported failure, it calls `mark_output_failed/2` and shows a safe recovery action.
The issuance event is accepted only while the socket is at the enrollment-form stage, so duplicate or fabricated submissions cannot replace the in-flight delivery.
Acknowledgements apply only while that exact Enrollment is in the socket-owned delivery stage, so stale success or failure events cannot overwrite a later UI state.
If a durable transition returns an ambiguous error, Console fetches the current Enrollment and derives its claim from stored state instead of assuming success or failure.
If a failure acknowledgement leaves the durable Enrollment in `pending_publication`, Console reports an uncertain state and continues polling rather than claiming completed output failure.
If the client disconnects or acknowledgement is lost, the Enrollment remains non-redeemable in `pending_publication` and the existing stale-publication reconciler later moves it to `output_failed`.
The Console never resends or redisplays that bundle.

Browser success proves only that the client accepted the download attempt.
It does not prove the destination filesystem, later transfer channel, or target-Mac custody.
The UI says this directly and requires the operator to protect the file during transfer.

## Decision 4: Registration And Activation Are Observed, Not Recorded

The Console polls durable Enrollment and Node state every five seconds and offers **Refresh now** as a fallback.
Polling uses one replaceable timer generation so manual refresh or reconnect cannot accumulate competing poll loops.
It never asks the operator to record package installation, service start, registration, Peer Grant activation, or Node activation.

Before registration, the page shows one current blocker:

- Run `orchardctl node join --enrollment-bundle PATH` on the target Mac.

After registration, the page links to Node detail and explicit admission review.
After admission, existing Node detail polling continues to show system-managed authorization, health, and lifecycle evidence.
No manual **Activate** action is added.

## Decision 5: Pool Is Admission Intent

The first slice presents `general` as the default initial Pool intent.
The operator may change it before issuance.
The value is carried as non-secret Enrollment audit metadata and prefilled during admission review when available.
It does not alter lifecycle, trust, registration, or scheduling eligibility by itself.

Custom Pool management remains outside this flow.
The UI calls Pool an existing scheduling group and says that it can be changed during admission review.

## Decision 6: Failure Copy Names Cause And Recovery

The flow renders one primary blocker or failure card at a time.
Every failure contains:

- what failed;
- why the current Enrollment cannot continue;
- whether trust or identity was established;
- the safe next action.

Expired, revoked, and `output_failed` Enrollments remain non-redeemable.
An already `consumed` Enrollment remains in the registration and admission lifecycle even after its original token expiry.
After consumption or registration, Console hides bundle-transfer instructions and the join command because the one-time registration action has completed.
The recovery action is **Create new enrollment**.
The flow never offers restore, secret redisplay, or automatic renewal.
The first slice does not reissue onto the previous provisioned Node: the old record remains for audit, and a new Enrollment requires a distinct Node name.

## Security And Privacy

- Bootstrap Token and encoded bundle bytes exist only in the domain call result, one LiveView push event, and transient browser memory.
- Logs and audit payloads contain only bounded identifiers, timestamps, surface, and non-secret intent.
- LiveView event acknowledgements carry only the Enrollment identifier.
- The server validates all acknowledgement identifiers against socket-owned state.
- The server accepts bundle issuance only from the socket-owned enrollment-form stage.
- Durable status recovery requires `audit_metadata["surface"] == "console"` before browser-specific claims are rendered.
- Child-resource reads are scoped to the server-side Enrollment and Node relationship.
- Filename sanitization permits only a bounded safe basename.
- Browser download does not weaken Controller leadership, trust initialization, HTTPS endpoint, expiry, or one-use gates.

## Accessibility And Motion

- Progress uses text, numbers, and state labels rather than color alone.
- Dynamic polling results use a polite live region.
- Focus order follows document order and all controls retain the shared focus ring.
- Failure and blocker text is visible without tooltips.
- Automatic state refresh does not automatically move focus.
- Reduced-motion preferences disable decorative progress animation.

## Rollback

Removing the Add Node route, link, and client hook returns Console behavior to the existing CLI-guidance path.
The shared bundle builder remains usable by CLI and does not change the artifact contract.
No migration is required for the first slice because Pool intent uses existing sanitized audit metadata.
