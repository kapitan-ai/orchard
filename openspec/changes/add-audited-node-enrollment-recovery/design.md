## Context

`Orchard.NodeEnrollments.create/2` currently allocates one `provisioned` Node and one Enrollment in the same transaction.
The database enforces one Enrollment per Node, and `latest_for_node/1` chooses by issue time rather than an explicit generation.
Redemption locks the Enrollment and then the Node, while publication transitions and stale-publication reconciliation lock only the Enrollment.
Console and CLI publish the returned bundle once, mark it `issued` only after their publication boundary succeeds, and never persist the plaintext Bootstrap Token.

`docs/DESIGN.md` §15.5 currently requires a new durable record and a distinct Node name after one-time delivery failure.
The active `operator-first-run-journey` package preserves matching-enrollment, matching-key, and matching-CSR resume after token consumption, and leaves list, inspect, revoke, and reissue surfaces open in task 3.6.
Issue #371 asks for a narrower recovery operation that retains the intended name while preserving those boundaries.

## Goals / Non-Goals

**Goals:**

- Recover bootstrap authority only for a completely evidenced, never-trusted `provisioned` Node.
- Retain the provisional Node ID and its stored display name explicitly.
- Keep every prior bundle permanently non-redeemable.
- Produce one ordered, auditable Enrollment generation chain.
- Serialize every competing enrollment and trust-establishing outcome.
- Preserve one-time secret output and distinct consumed-enrollment resume.
- Share domain decisions, stable result codes, validation, and presentation across service, CLI, and LiveView seams.

**Non-Goals:**

- Recover, replace, rename, or take over a registered, admitted, active, trusted, decommissioning, removed, or otherwise non-provisioned Node.
- Recover after any certificate issuance outcome that could have created trust, including an uncertain or failed outcome.
- Revoke or replace a Node Certificate, BEAM Peer Grant, Node Identity Store, or trusted runtime identity.
- Add a remote Admin API endpoint in the first implementation.
- Redisplay, resend, reconstruct, or decrypt a prior Bootstrap Token.
- Treat display-name equality as a Node lookup, identity proof, or implicit recovery request.
- Change Pool intent, admission, activation, scheduling, or packaged multi-Mac support.

## Decision 1: Retain The Proven Never-Trusted Node ID

Recovery retains the existing `node_id` and `display_name` only when the row is still an administrative `provisioned` placeholder and complete history proves that Orchard never established trust for it.
The Action Preview and result call this `identity_disposition = retained_provisional_node`.
The operator confirms the exact Node ID, so retaining identity is never inferred from the display name.

The successor is a new Enrollment generation, not a mutation or replay of the previous Enrollment.
No Node lifecycle transition occurs until ordinary certificate-backed redemption advances `provisioned -> registered`.

A linked replacement Node was considered and rejected for this scope.
It would still need atomic predecessor invalidation, would require moving or aliasing the unique display name, and would introduce identity churn without improving safety for a placeholder that has never established trust.
Trusted, uncertain, or otherwise ineligible identities route to their applicable lifecycle or certificate workflow.
Any replacement Node requires a separately approved operation and is never an automatic escape from unresolved trust.

## Decision 2: Eligibility Is A Complete-History Invariant

Preview and execution use one shared eligibility decision.
Execution recomputes it while holding the serialization locks and fails closed when any required evidence is missing, inconsistent, or unavailable.

All of these conditions are required:

1. The target Node exists and its current lifecycle is exactly `provisioned`.
2. The Node has one complete, acyclic Enrollment generation chain with one explicit current generation and no fork.
3. Every Enrollment generation belongs to that Node, cluster, Controller, and trust authority according to the immutable chain scope.
4. No generation has `consumed_at`, a redemption-bound CSR fingerprint, a certificate identifier, certificate result, or certificate issuance outcome other than `not_started`.
5. No authoritative Node Certificate, trust binding, registered lifecycle history, admission decision, admitted Runtime Endpoint authorization, or BEAM Peer Grant exists for the Node.
6. No audit or durable domain record contradicts the never-trusted conclusion.
7. The selected current generation is `pending_publication`, `issued`, `revoked`, `expired`, or `output_failed`, or has passed its expiry while otherwise remaining unconsumed.

Static creation-time resume algorithm metadata is not trust evidence by itself.
Any consumption-bound resume verifier, CSR, public-key fingerprint, or certificate evidence is trust evidence and rejects recovery.
A `failed` certificate issuance outcome is ineligible because the repository cannot prove that an external signing side effect did not occur.

Recovery must remain disabled until implementation inventory identifies every certificate, trust, registration, admission, and authorization evidence source, every writer, the retention guarantee for negative history, and the writer's participation in the recovery revision and lock protocol.
That inventory must also prove whether certificate issuance can leave a usable external effect after its database transaction rolls back.
If that proof is unavailable, the implementation must add a durable issuance-attempt fence before signing and treat any started attempt as permanent recovery ineligibility.
An empty query against an incomplete or retention-ambiguous evidence set is never proof of never-trusted history.

All other Node lifecycle states reject recovery, including `registered`, `admitted`, `active`, `cordoned`, `draining`, `maintenance`, `decommissioning`, and `removed`.
A legacy provisioned Node with no Enrollment or an incomplete chain is ineligible and requires separately approved repair or a separately approved replacement operation.

## Decision 3: Use An Append-Only Enrollment Generation Chain

Every structurally valid existing Enrollment is backfilled as generation `1` without making recovery eligibility a migration requirement for registered or consumed Nodes.
Rows with incomplete or contradictory recovery history remain representable but are marked recovery-ineligible for separately approved investigation or repair.
Each new generation records a positive generation number, its immediate predecessor, immutable Node and trust scope, creator provenance, and the recovery operation that created it.
The database enforces unique `(node_id, generation)`, at most one successor for a predecessor, and one explicit current generation for a Node.
Current generation selection never depends on `issued_at` ordering.

Enrollment identity, generation, predecessor, Node, cluster, Controller, trust-authority scope, token hash and prefix, creator, and recovery linkage are immutable after insertion.
Publication, expiry, revocation, supersession, and consumption remain explicit lifecycle transitions with their own timestamps and optimistic lock version.

Supersession linkage is independent of the predecessor's terminal cause.
An otherwise live `pending_publication` or `issued` predecessor transitions to `superseded`.
An already `revoked`, `expired`, or `output_failed` predecessor retains that state and receives immutable successor linkage.
Any Enrollment with successor linkage is permanently non-redeemable regardless of state, original expiry, token validity, or a late publication acknowledgement.

One recovery-operation record binds a bounded opaque request ID to the authenticated cluster and operation scope, canonical request fingerprint including Node and predecessor, cause, non-empty reason, actor provenance, predecessor generation, successor generation, and final secret-free result.
The request ID is unique within `(cluster_id, operation_kind)` and remains retained for at least the retained Node history.
The v1 request fingerprint is SHA-256 over a versioned length-delimited encoding of the normalized cluster ID, operation kind, Node ID, predecessor ID and generation, recovery cause, trimmed validated reason, requested expiry, and confirmation claims.
The fingerprint is idempotency evidence stored outside audit and is not a credential, token hash, or authorization input.

## Decision 4: Publish-Gate Every Successor

Recovery atomically invalidates the predecessor authority, creates the successor as `pending_publication`, advances the explicit current-generation pointer, appends the recovery operation, and writes the recovery audit event.
The transaction may return new bundle bytes once to the original caller, but the successor remains non-redeemable until that caller's existing protected publication adapter confirms success.

Publication success may transition only the exact still-current `pending_publication` successor to `issued`.
Publication failure moves that successor to `output_failed` and never reactivates any predecessor.
Output-delivery failure while the durable successor is proven `pending_publication` keeps it non-redeemable and may move it to `output_failed`.
If publication or `mark_issued` may have succeeded but the durable state cannot be read, the result reports successor redeemability and publication as `unknown`, returns nonzero, warns that the bundle may be redeemable, and never regenerates or redisplays the secret.
Reconciliation later reads the durable generation without replaying bytes, never rolls back a consumed identity, and appends linked audit evidence for the resolved or still-unresolved outcome when Postgres becomes available.
Stale-publication reconciliation operates only on the exact generation it locks and cannot invalidate a later successor or restore an earlier generation.

The product reports recovery commit, successor redeemability, and publication outcomes separately.
It does not claim that failed publication had no filesystem, browser, or client-memory side effects, and it does not claim physical secret erasure.

## Decision 5: Share One Node-First Serialization Protocol

The Node row is the common serialization point for recovery, redemption, revocation, expiry normalization, publication acknowledgement, stale-publication reconciliation, and every writer that can establish or contradict Node trust.
All participating writers lock in this order:

1. Lock the Node.
2. Lock the explicit current Enrollment and affected generations in ascending generation and ID order.
3. Lock or re-read relevant trust, certificate, admission, and authorization evidence under the same exclusion boundary.
4. Revalidate authorization, leadership, expected revision, chain integrity, eligibility, expiry, publication state, and confirmations.
5. Commit the authoritative state change and required audit records atomically.

The implementation must refactor the current Enrollment-first redemption order before adding recovery so it cannot deadlock with the new path.
Locking an Enrollment alone is not sufficient because another writer could insert contradictory trust evidence for the same Node.

Each Node receives a monotonic `enrollment_recovery_revision` advanced atomically with every authoritative state change by a participating writer, including eligibility-preserving recovery, revocation, expiry normalization, publication acknowledgement, and stale-publication reconciliation.
Action Preview returns the Node ID, expected recovery revision, current Enrollment ID, current generation, and current Enrollment lock version.
Execution requires those exact values and returns `node_recovery_stale_preview` without mutation when any value changed.
Execution still performs full mutation-time revalidation even when all optimistic values match.

## Decision 6: Define One Authoritative Outcome For Every Race

Execution uses this decision order:

1. Authenticate and authorize the current caller.
2. Resolve the request ID within cluster and operation scope before evaluating current Node state.
3. Return an authorized secret-free duplicate when the canonical fingerprint matches, or `node_recovery_request_conflict` when it differs.
4. For a new request, classify incomplete history and trusted or non-provisioned state.
5. Enforce preview concurrency and confirmations.
6. Execute the locked recovery transition.

Any currently authorized administrator, or a currently authorized local Controller-runtime CLI principal, may inspect an existing operation's secret-free status.
Duplicate status reports both the original recovery commit result and the current successor generation state when readable, and reports current state as `unknown` when it is not readable.
This precedence means a matching duplicate remains `node_recovery_duplicate` after the generation, Node lifecycle, or recovery revision changes.

| Competing boundary | Authoritative outcome |
|---|---|
| Recovery versus redemption | Both lock the Node first. If redemption commits first, the Node becomes registered and recovery returns `node_recovery_ineligible`. If recovery commits first, predecessor redemption returns the existing generic bootstrap rejection and cannot create trust. |
| Recovery versus recovery | One request advances the expected generation. A distinct request using the stale preview returns `node_recovery_stale_preview`. |
| Duplicate request ID | Same ID and canonical fingerprint returns the existing operation's secret-free status and creates no generation or publication event. Same ID with a different fingerprint returns `node_recovery_request_conflict`. |
| Recovery versus revocation | A concurrent revocation advances the recovery revision. Stale execution fails. A fresh preview may recover the revoked generation only when the complete never-trusted invariant still holds. |
| Recovery versus expiry | One authoritative database time is sampled after locks. An expired `issued` generation transitions to `expired`; an expired `pending_publication` generation transitions directly to `superseded` with recovery-time expiry evidence and no fabricated publication; `revoked` and `output_failed` retain their terminal cause. The successor alone receives a fresh bounded lifetime. |
| Recovery versus publication acknowledgement | Only the exact current generation may become `issued`. A predecessor acknowledgement after recovery returns `enrollment_superseded` and changes no authority. |
| Recovery versus stale reconciliation | The shared locks and exact generation predicate ensure only one state transition wins. Reconciliation cannot act on a no-longer-current generation as though it were current. |
| Proven output-delivery failure | The exact pending successor becomes or remains non-redeemable and predecessors remain invalid. Another generation requires a new explicit recovery request and preview. |
| Uncertain publication-state commit | The command returns nonzero with successor redeemability and publication `unknown`, warns that the bundle may be redeemable, and reconciles later without replaying bytes or restoring predecessors. |
| Audit persistence failure | Recovery rolls back predecessor invalidation, successor creation, current-pointer change, request record, and every other authoritative mutation. |
| Consumed Enrollment retry | Recovery rejects. The existing bounded matching-enrollment, matching-key, and matching-CSR resume path alone may return the previously issued identity. |

Duplicate requests never replay plaintext.
If the original response or one-time delivery is lost, the operator must start a new explicitly confirmed recovery with a new request ID.

## Decision 7: Require Administrator Preview, Confirmation, And Provenance

Authenticated Console and any future network surface require a current cluster-scoped `admin` principal.
The local Controller-runtime CLI preserves its existing bootstrap authority, but it must prove Active write authority and record bounded operating-system principal provenance rather than a caller-supplied actor.
Tenant credentials, inference credentials, Node credentials, display-name possession, and unauthenticated local requests never authorize recovery.

Preview is side-effect-free and performs no reconciliation, expiry mutation, token generation, audit write, or row creation.
It exposes the retained Node ID and name, identity disposition, current generation, generations that will become non-redeemable, eligibility blockers, warnings, consequence codes, confirmation requirements, and optimistic concurrency values.
It explicitly warns that every prior bundle remains unusable even if publication of the successor fails.

Execution requires a bounded recovery cause, a non-empty bounded reason, acknowledgement of predecessor invalidation, exact typed Node ID confirmation, and the preview concurrency values.
Authorization, leadership, provenance, eligibility, and all confirmations are revalidated inside the mutation transaction.
Confirmations never bypass blockers.

Free-form reason, request identifiers, and provenance pass value-aware secret-pattern, control-character, and length validation in addition to the existing unsafe-key filtering.
Known secret-shaped or enrollment-bearing values, including an unsafe retained display name, are rejected where caller-controlled or stored in audit as an explicit redacted marker plus a non-reversible redaction digest, never copied verbatim into audit.
The redaction digest identifies repeated unsafe audit input only and is distinct from prohibited credential-derived or token-derived hashes.
The atomic recovery audit contains only bounded non-secret fields: operation and request identifiers, Node ID, retained display name, predecessor and successor Enrollment IDs and generations, identity disposition, cause, safely retained reason evidence, actor type and trusted actor identifier, surface, timestamp, and affected authority states.
Publication success, failure, or unresolved reconciliation is recorded as a separate linked audit event.
Bootstrap Tokens, credential-derived and token-derived hashes, private keys, CSR bodies, certificates, bundle bytes, filesystem paths, and raw request input are excluded.

## Decision 8: Make Name Behavior Explicit And Shared

`orchardctl nodes enrollment create` accepts optional `--display-name NAME`, trims it through the existing shared normalization, and applies the same 128-byte, valid UTF-8, control-character, and uniqueness validation used by Console issuance.
Repeated `--display-name` flags and malformed names fail before trust reads, token generation, output creation, or database mutation.
When the option is omitted, the existing generated `provisioned-<node-id-prefix>` behavior remains unchanged.

Ordinary creation never interprets an existing display name as recovery.
It checks duplicate names through the shared service and database constraint, returns the same result as Console, and creates no Node, Enrollment, audit, or unrelated reconciliation mutation.
Stale-publication reconciliation becomes an independently scheduled or explicitly invoked operation rather than a side effect that runs before issuance validation.
Recovery selects the Node by exact ID through the explicit recovery operation and retains its stored display name without accepting a replacement name.
This preserves the unique `nodes.display_name` constraint and keeps name equality out of identity reconciliation.

Pool-intent parity beyond existing shared issuer behavior is outside this change.

## Public Service And Presentation Contract

The shared service returns versioned `orchard.node_enrollment_recovery.v1` results.
Secret-free fields include operation status, Node ID, identity disposition, predecessor and successor IDs and generations, original recovery commit, current successor state, successor redeemability, publication outcome, recovery revision, blockers, warnings, consequence codes, confirmation requirements, and stable result code.
Only the original successful execution response may additionally carry the successor bundle bytes to its selected one-time publication adapter.

Result fields use closed v1 enums.
`original_recovery_commit` is `committed` or `not_committed`.
`current_successor_state` is `pending_publication`, `issued`, `consumed`, `revoked`, `expired`, `output_failed`, `superseded`, or `unknown`.
`successor_redeemability` is `redeemable`, `non_redeemable`, or `unknown`.
`publication` is `pending`, `confirmed`, `failed`, or `unknown`.

Stable result codes include:

- `node_recovery_preview`
- `node_recovery_committed`
- `node_recovery_duplicate`
- `node_recovery_ineligible`
- `node_recovery_history_inconsistent`
- `node_recovery_authority_changed`
- `node_recovery_stale_preview`
- `node_recovery_request_conflict`
- `enrollment_superseded`
- `node_recovery_output_failed`
- `node_recovery_publication_unresolved`

Detailed eligibility evidence appears only on authorized operator surfaces.
Public bootstrap redemption keeps its existing generic rejection so stale bundles cannot probe Node history.

## Migration And Rollout

1. Inventory every writer and caller that assumes one Enrollment per Node or selects by issue time.
2. Enumerate authoritative negative-history sources, writers, retention guarantees, and certificate-issuance rollback behavior, then add a durable issuance-attempt fence if rollback cannot be proven side-effect free.
3. Add generation, linkage, current-pointer, recovery revision, and cluster-operation-scoped idempotency persistence with validation constraints.
4. Backfill structurally valid Enrollments as generation `1`, mark incomplete recovery history ineligible without blocking valid registered or consumed history, and prevent mixed-version writers during rollout.
5. Refactor redemption, publication, reconciliation, revocation, expiry, trust, and admission writers onto the shared Node-first protocol.
6. Add the preview and execution service behind no presentation entry point and prove the safety and race matrix.
7. Add the CLI and LiveView vertical slices using the same service and presenters.
8. Reconcile `SPEC.md`, `docs/DESIGN.md`, operator journey documentation, and the active operator-first-run package before implementation handoff.

## Risks / Trade-offs

- A current `provisioned` value could hide prior trust history.
  The complete-history eligibility decision rejects missing, contradictory, certificate, admission, or registration evidence.
- Multiple Enrollment rows could create more than one live token.
  The explicit current generation, successor uniqueness, shared lock, publication gate, and permanent predecessor invalidation replace the current one-row constraint.
- Recovery could deadlock with redemption.
  Every participating writer moves to the same Node-first lock order before recovery ships.
- Idempotency could become secret replay.
  Duplicate requests return only durable secret-free status and never reproduce bundle bytes.
- A new bundle could fail after the old token is invalidated.
  Preview requires explicit acknowledgement, publication stays a separate outcome, and no predecessor is reactivated.
- Detailed errors could disclose enrollment history to a stale-bundle holder.
  Only authorized administrator surfaces receive detail, while bootstrap redemption remains generic.
- A long-lived recovery record increases retained metadata.
  The bounded record is necessary to prevent duplicate request reuse and to preserve audit linkage for the retained Node history.

## Implementation Prerequisites And Deferred Interfaces

No recovery surface may be enabled until the authoritative evidence inventory, retention proof, certificate-issuance rollback assessment or fence, shared revision participation, first-slice negative matrix, and applicable race tests pass.
These are implementation safety gates selected by this contract, not unresolved permission to weaken eligibility.

The exact future remote Admin API route, if any, remains outside scope and requires a separate reviewed interface decision.
Controller replacement, trust-authority rotation, and any successor whose cluster, Controller, or trust-authority scope differs from its predecessor are rejected by this change and require separately approved migration semantics.
