## Why

Node Enrollment deliberately publishes each Bootstrap Token once and refuses to redisplay or reuse it.
When an unregistered provisioned Node's bundle is lost, inaccessible, expired, revoked, or not published successfully, the current recovery guidance creates another Node with a distinct display name.
That preserves the secret boundary but leaves the intended name reserved by a placeholder that has never established trust.

Issue #371 requires a narrow recovery contract that retains the intended name without making name equality an identity decision, reviving stale bootstrap authority, or routing a consumed enrollment into replacement recovery.
The change must also give `orchardctl nodes enrollment create` the same optional display-name input that Console already uses.

## What Changes

- Add an explicit audited recovery operation for a provably never-trusted Node whose lifecycle remains `provisioned`.
- Retain that Node's allocated `node_id` and stored display name while creating a new append-only Enrollment generation linked to its predecessor.
- Make retained identity an explicit preview, confirmation, result, and audit fact rather than an implication of display-name reuse.
- Revoke or supersede all older bootstrap authority atomically before the successor can become redeemable.
- Serialize recovery with redemption, revocation, expiry, publication acknowledgement, and stale-publication reconciliation through one shared Node-first locking protocol.
- Keep matching-enrollment, matching-key, and matching-CSR resume for a consumed Enrollment as a separate operation that creates no new generation.
- Require side-effect-free Action Preview, explicit administrator authorization, bounded actor provenance, a non-empty reason, typed Node confirmation, and optimistic concurrency.
- Add optional `--display-name NAME` support to `orchardctl nodes enrollment create` through the existing shared validation and uniqueness contract.
- Preserve generated names when `--display-name` is omitted, and reject duplicate names during ordinary creation unless the operator explicitly invokes recovery by Node ID.
- Define stable, secret-free results for committed authority, publication, duplicate request, conflict, and failure outcomes.

## Capabilities

### New Capabilities

- `node-enrollment-recovery`: Defines eligibility, retained provisional identity, append-only Enrollment generations, serialization, authorization, audit, one-time delivery, display-name behavior, and public-interface acceptance.

### Modified Capabilities

None.

## Impact

- Persistence impact: the one-Enrollment-per-Node invariant becomes an ordered generation chain with one explicit current generation, a recovery revision, and durable idempotency evidence.
- Domain impact: recovery, redemption, revocation, expiry, publication, and trust-establishing writes must share one serialization protocol and mutation-time eligibility check.
- CLI impact: ordinary creation gains optional `--display-name`; recovery gains an explicit preview-and-confirm command and never follows from a duplicate name.
- Console impact: only an eligible failed Enrollment offers same-Node recovery, and the preview identifies the retained Node ID, retained name, invalidated authorities, and output-failure consequence.
- Security impact: no predecessor bundle becomes redeemable again, no secret is replayed for duplicate requests, and public bootstrap redemption remains a generic rejection boundary.
- Audit impact: one atomic recovery record links the Node, predecessor, successor, request, cause, reason, actor provenance, and affected authority without secret material.

This proposal closes the contract gap in issue #371 but does not implement product code.
The implementing pull request will close #371 after all slices and validation are complete.

### SPEC.md Clarification Required During Implementation

The implementation must clarify `SPEC.md` §§4.2 through 4.4, 7.3.1, 7.4.1, 10.1 through 10.2, and 11.9.
The clarification will state that recovery retains only a provably never-trusted `provisioned` Node's allocated ID, creates a new Enrollment generation without performing a Node lifecycle transition, and never permits re-enrollment of a registered or trusted identity.
It will also add the Action Preview, authorization, audit, CLI, and concurrency contracts selected here.

### docs/DESIGN.md Clarification Required During Implementation

The implementation must narrow `docs/DESIGN.md` §15.5 rather than weaken it.
Eligible same-Node recovery creates new one-time output under a new durable Enrollment generation while retaining the explicitly identified provisional Node ID and name.
Consumed Enrollments route only to the existing matching-enrollment, matching-key, and matching-CSR resume path.
Trusted or non-provisioned Nodes route to their applicable lifecycle or certificate workflow, while incomplete or uncertain history remains blocked for investigation or separately approved repair.
No ineligible case silently creates a distinct replacement Node.
The no-redisplay, no-resend, no-silent-renewal, transient-delivery, and browser-custody rules remain unchanged.

## Owner Decisions

This package resolves the product and security choices needed for implementation.
Recovery is administrator-authorized on authenticated product surfaces, while the existing local Controller-runtime CLI authority remains available with bounded operating-system principal provenance, leader proof, and the same confirmation and audit rules.
Explicit revocation is generation-scoped and does not prohibit a later explicit recovery when the Node still satisfies the complete never-trusted eligibility invariant.
Legacy provisioned Nodes without a complete coherent Enrollment history are ineligible rather than inferred safe.
Recovery-operation idempotency evidence remains durable for at least the lifetime of the retained Node history.

No unresolved owner choice broadens the first implementation slice, but the operational proof prerequisites in the design must be satisfied before any recovery surface is enabled.
A future remote Admin API endpoint, trusted-Node replacement, recovery after uncertain certificate issuance, and repair of incomplete legacy history each require separate approval.
