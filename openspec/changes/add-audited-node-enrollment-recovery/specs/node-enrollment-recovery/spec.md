## ADDED Requirements

### Requirement: Recovery Retains Only A Proven Never-Trusted Provisioned Node

An audited Node Enrollment recovery SHALL retain the existing Node ID and stored display name only when the Node lifecycle is exactly `provisioned` and complete authoritative history proves that the Node has never established trust.
The retained identity SHALL be explicit as `retained_provisional_node` in Action Preview, confirmation, execution result, and audit evidence.
Recovery SHALL create a new Enrollment generation and SHALL NOT perform a Node lifecycle transition.
Recovery SHALL remain disabled until every trust-establishing evidence source and writer, its retention guarantee, its lock and revision participation, and certificate-issuance rollback or durable attempt-fence behavior are explicitly inventoried and tested.
This refines `SPEC.md` §§4.2 through 4.4, 7.3.1, 7.4.1, 10.1 through 10.2, and 11.9.

#### Scenario: Output-failed placeholder retains its identity and name

- **WHEN** an authorized administrator recovers a coherent `output_failed` Enrollment whose Node remains `provisioned` and has no consumption, certificate, trust, admission, or authorization evidence
- **THEN** Orchard retains the exact Node ID and stored display name
- **AND** Orchard creates one linked successor Enrollment generation for that Node
- **AND** Orchard identifies the retained provisional identity explicitly rather than inferring it from the display name

#### Scenario: Non-provisioned lifecycle rejects recovery

- **WHEN** recovery targets a Node in `registered`, `admitted`, `active`, `cordoned`, `draining`, `maintenance`, `decommissioning`, or `removed`
- **THEN** Orchard returns `node_recovery_ineligible`
- **AND** Orchard creates no Enrollment, token, audit event, or identity mutation

#### Scenario: Historical trust evidence rejects recovery

- **WHEN** any Enrollment or authoritative domain history contains token consumption, a redemption-bound CSR or public-key fingerprint, a certificate issuance outcome other than `not_started`, a certificate identifier or result, registered lifecycle history, a trust binding, an admission decision, or a BEAM Peer Grant for the Node
- **THEN** Orchard returns `node_recovery_ineligible`
- **AND** confirmation cannot bypass the blocker

#### Scenario: History is incomplete or inconsistent

- **WHEN** the Enrollment chain is missing, forked, cyclic, cross-Node, has multiple current generations, contradicts authoritative audit or trust history, or cannot be read completely
- **THEN** Orchard fails closed with `node_recovery_history_inconsistent`
- **AND** Orchard does not infer that absent or unreadable evidence means never trusted

#### Scenario: Trust evidence inventory is incomplete

- **WHEN** any certificate, trust, registration, admission, or authorization writer or retention guarantee has not been incorporated into the shared eligibility decision and recovery revision
- **THEN** Orchard exposes no recovery execution surface
- **AND** an empty query does not count as proof of never-trusted history

#### Scenario: Controller or trust authority changed

- **WHEN** the current cluster, Controller, or trust-authority scope does not exactly match the immutable predecessor chain
- **THEN** Orchard returns `node_recovery_authority_changed`
- **AND** Orchard creates no cross-authority successor or implicit migration

### Requirement: Enrollment Recovery Uses Append-Only Generations

Each recovered Enrollment SHALL have an immutable positive generation, immediate predecessor, Node and trust scope, creator provenance, and recovery-operation link.
Orchard SHALL enforce one explicit current generation, unique `(node_id, generation)`, and at most one successor per predecessor.
Current generation selection MUST NOT depend on issue-time ordering.
Any predecessor with successor linkage SHALL remain permanently non-redeemable.

#### Scenario: Live predecessor is superseded

- **WHEN** recovery commits for a current unconsumed `pending_publication` or `issued` generation
- **THEN** Orchard transitions that predecessor to `superseded`
- **AND** Orchard records immutable successor linkage and supersession time
- **AND** the predecessor cannot redeem even before its original expiry

#### Scenario: Terminal predecessor keeps its cause

- **WHEN** recovery commits for a current `revoked`, `expired`, or `output_failed` generation
- **THEN** Orchard preserves that terminal state and its cause-specific timestamps
- **AND** Orchard records immutable successor linkage
- **AND** the predecessor remains non-redeemable

#### Scenario: Successor awaits publication

- **WHEN** recovery authority commits successfully
- **THEN** the successor begins as `pending_publication`
- **AND** the successor cannot redeem until the exact current publication adapter confirms success
- **AND** no predecessor authority is reactivated while publication is pending

#### Scenario: Stale bundle is presented after recovery

- **WHEN** any superseded predecessor bundle is presented for redemption
- **THEN** the public bootstrap boundary returns its existing generic rejection
- **AND** Orchard creates no Node Certificate, trust, registration, or new Enrollment

### Requirement: Recovery Is Serialized With Every Competing Authority Outcome

Recovery, redemption, revocation, expiry normalization, publication acknowledgement, stale-publication reconciliation, and every writer that can establish or contradict Node trust SHALL use the Node row as their common first lock.
Affected Enrollment generations SHALL then be locked in deterministic generation and ID order.
Every participating writer SHALL atomically advance the Node's monotonic recovery revision with each authoritative state change, including eligibility-preserving recovery, revocation, expiry normalization, publication acknowledgement, and stale-publication reconciliation.
Execution SHALL revalidate authorization, leadership, complete-history eligibility, chain integrity, publication state, expiry, optimistic concurrency, and confirmation while those locks are held.

#### Scenario: Redemption commits before recovery

- **WHEN** redemption and recovery race for the same current generation and redemption commits first
- **THEN** redemption establishes at most one registered Node identity through the existing contract
- **AND** recovery observes the registered or trusted state and returns `node_recovery_ineligible`

#### Scenario: Recovery commits before redemption

- **WHEN** recovery and redemption race and recovery commits first
- **THEN** predecessor authority is permanently invalid before the successor exists as current
- **AND** the stale redemption returns the existing generic rejection
- **AND** only the published successor may later establish trust

#### Scenario: Distinct recovery uses a stale preview

- **WHEN** an eligibility-preserving recovery, revocation, expiry, or publication writer changes the Node recovery revision or expected generation after preview
- **THEN** execution returns `node_recovery_stale_preview`
- **AND** Orchard commits no recovery mutation or audit event

#### Scenario: Trust or lifecycle changed after preview

- **WHEN** redemption, registration, admission, or another trust-establishing writer makes the Node non-provisioned or no longer never-trusted after preview
- **THEN** execution returns `node_recovery_ineligible` before preview-staleness classification
- **AND** Orchard commits no recovery mutation or audit event

#### Scenario: Revocation wins the race

- **WHEN** revocation commits after preview and before recovery execution
- **THEN** stale recovery fails without mutation
- **AND** a new preview may offer recovery of the revoked generation only if the complete never-trusted invariant still holds

#### Scenario: Issued authority expires during execution

- **WHEN** one authoritative database time sampled after locking shows that the current `issued` authority expired before recovery commits
- **THEN** Orchard records the predecessor as `expired` under the shared lock
- **AND** the successor receives a new bounded expiry without extending or rewriting its predecessor

#### Scenario: Unpublished authority expires during execution

- **WHEN** the sampled database time shows that the current `pending_publication` generation expired before recovery commits
- **THEN** Orchard supersedes that unpublished predecessor and records recovery-time expiry evidence
- **AND** Orchard does not fabricate `published_at` or represent the predecessor as previously redeemable

#### Scenario: Terminal authority passes its expiry

- **WHEN** a current `revoked` or `output_failed` generation is past its validity timestamp
- **THEN** recovery preserves the existing terminal state and cause-specific timestamps
- **AND** elapsed validity does not overwrite the revocation or output-failure evidence

### Requirement: Recovery Requests Are Idempotent Without Replaying Secrets

Each execution SHALL require a bounded opaque request ID unique within `(cluster_id, operation_kind)` and bound to a canonical request fingerprint that includes authenticated scope, Node, expected predecessor, cause, reason, expiry, and confirmations.
The v1 fingerprint SHALL use SHA-256 over a versioned length-delimited encoding of those normalized fields and SHALL be stored outside audit as idempotency evidence rather than credential or authorization material.
The request record SHALL commit atomically with recovery and remain retained for at least the lifetime of the retained Node history.
Idempotency SHALL mean one durable operation and MUST NOT authorize plaintext replay.
After authorization, Orchard SHALL resolve the request ID before classifying current lifecycle, trust eligibility, preview staleness, or confirmation state.
An authorized duplicate response SHALL report the original commit result and the current successor state when readable, or `unknown` current state when it is unavailable.

#### Scenario: Concurrent duplicate request matches

- **WHEN** concurrent executions use the same request ID and canonical request fingerprint
- **THEN** Orchard creates at most one successor generation and one recovery operation
- **AND** duplicate callers receive `node_recovery_duplicate` with secret-free durable status
- **AND** duplicate callers receive no bundle bytes or publication event

#### Scenario: Matching duplicate arrives after state changed

- **WHEN** a matching request ID and fingerprint is retried after the recovery revision, current generation, Node lifecycle, or successor state changed
- **THEN** Orchard returns `node_recovery_duplicate` rather than stale-preview or ineligible classification
- **AND** the result remains secret-free and distinguishes original commit from current readable state

#### Scenario: Request ID is reused with different input

- **WHEN** a request ID is reused with a different Node, predecessor, reason, cause, expiry, confirmation, or other canonical input
- **THEN** Orchard returns `node_recovery_request_conflict`
- **AND** Orchard commits no mutation

#### Scenario: Original recovery response is lost

- **WHEN** recovery committed but its one-time bundle response or delivery acknowledgement is lost
- **THEN** retrying the same request returns only secret-free operation status
- **AND** issuing another generation requires a new explicit recovery request, fresh preview, and confirmation

### Requirement: Publication Failure Never Restores Predecessor Authority

Recovery SHALL report credential-authority and publication outcomes separately.
Only the exact still-current `pending_publication` successor MAY transition to `issued` after protected output publication succeeds.
Proven output-delivery failure while the successor remains `pending_publication` SHALL keep it non-redeemable.
Publication-state ambiguity SHALL report successor redeemability as `unknown` when Orchard cannot establish whether `mark_issued` committed.
Every predecessor SHALL remain invalid, and no failure or ambiguity SHALL regenerate or redisplay bundle material.

#### Scenario: Successor publication succeeds

- **WHEN** the selected CLI or Console adapter confirms protected publication for the exact current successor
- **THEN** Orchard transitions only that successor to `issued`
- **AND** every predecessor remains non-redeemable

#### Scenario: Successor publication fails

- **WHEN** output publication fails after recovery authority committed
- **THEN** Orchard marks the successor `output_failed` when it can confirm that durable transition
- **AND** Orchard reports `node_recovery_output_failed`
- **AND** every predecessor remains invalid
- **AND** another attempt requires a new explicit recovery request

#### Scenario: Publication result is unresolved

- **WHEN** publication or `mark_issued` may have succeeded but Orchard cannot read the durable successor state
- **THEN** Orchard returns `node_recovery_publication_unresolved`
- **AND** Orchard reports successor redeemability and publication as `unknown`
- **AND** Orchard returns nonzero and warns that the delivered bundle may be redeemable
- **AND** Orchard does not claim that client, browser, filesystem, or physical-media side effects were absent
- **AND** later reconciliation reads durable state without replaying bundle bytes, rolling back consumed identity, or restoring predecessors

#### Scenario: Late predecessor acknowledgement arrives

- **WHEN** a success acknowledgement names a predecessor after recovery advanced the current generation
- **THEN** Orchard returns `enrollment_superseded`
- **AND** Orchard does not mark the predecessor issued, change the successor, or restore prior authority

#### Scenario: Recovery audit cannot commit

- **WHEN** the required recovery operation or cluster audit event cannot persist
- **THEN** predecessor invalidation, successor creation, current-generation advancement, idempotency state, and every related mutation roll back atomically
- **AND** no bundle bytes are returned

### Requirement: Consumed-Enrollment Resume Remains A Separate Operation

Recovery SHALL reject every consumed Enrollment and every Node with consumption or certificate evidence.
The existing bounded resume path MAY return the already issued identity only when enrollment ID, durably held Node key, CSR fingerprint, and public-key fingerprint all match the consumed attempt.
Resume SHALL create no new Enrollment generation and SHALL NOT use display-name recovery.

#### Scenario: Matching resume follows the existing path

- **WHEN** a consumed Enrollment is retried within its resume window using the same Enrollment ID, local key, CSR fingerprint, and public-key fingerprint
- **THEN** Orchard returns the existing certificate result under the current resume contract
- **AND** Orchard creates no recovery operation, successor generation, Bootstrap Token, or additional Node identity

#### Scenario: Consumed enrollment is submitted for recovery

- **WHEN** an operator or client submits a consumed Enrollment or its registered Node to recovery
- **THEN** Orchard returns `node_recovery_ineligible`
- **AND** Orchard does not convert the request into replacement or resume

#### Scenario: Resume key or CSR differs

- **WHEN** a consumed Enrollment retry changes the key, CSR fingerprint, public-key fingerprint, Node binding, cluster binding, or Controller binding
- **THEN** Orchard returns the existing generic enrollment rejection
- **AND** Orchard does not create recovery state or another identity

### Requirement: Recovery Requires Authorized Preview And Explicit Confirmation

Authenticated product recovery surfaces SHALL require a current cluster-scoped `admin` principal.
The local Controller-runtime CLI MAY use its existing bootstrap authority only with Active write proof, bounded trusted operating-system principal provenance, and the same preview, confirmation, mutation-time revalidation, and audit contract.
Preview SHALL be side-effect-free.
Execution SHALL require a bounded recovery cause, non-empty sanitized reason, predecessor-invalidation acknowledgement, exact typed Node ID confirmation, and the preview's optimistic concurrency values.

#### Scenario: Administrator previews eligible recovery

- **WHEN** an authorized administrator requests recovery preview for an eligible Node
- **THEN** Orchard creates no token, Node, Enrollment, recovery operation, reconciliation transition, expiry transition, or audit event
- **AND** the preview shows the retained Node ID and name, identity disposition, current and affected generations, blockers, warnings, consequences, confirmation requirements, and recovery revision
- **AND** the preview warns that predecessor bundles remain unusable even if successor publication fails

#### Scenario: Caller lacks recovery authority

- **WHEN** a tenant credential, inference credential, Node credential, unauthenticated caller, or authenticated non-admin principal requests recovery
- **THEN** Orchard rejects the request before eligibility detail or mutation
- **AND** possession of the display name or a stale bundle grants no recovery authority

#### Scenario: Confirmation is missing or incorrect

- **WHEN** the reason, cause, predecessor-invalidation acknowledgement, or exact typed Node ID confirmation is missing or invalid
- **THEN** execution fails without mutation
- **AND** the supplied confirmation cannot bypass an eligibility or authorization blocker

#### Scenario: Recovery commits with audit provenance

- **WHEN** authorized confirmed recovery commits
- **THEN** one atomic audit link records bounded operation and request identifiers, Node ID, retained display name, predecessor and successor IDs and generations, identity disposition, cause, reason, trusted actor provenance, surface, time, and affected authority states
- **AND** publication outcome is recorded separately against the same operation
- **AND** free-form reason, request identifiers, and provenance pass value-aware secret-pattern, control-character, and length validation before any retained audit value is written
- **AND** a known secret-shaped or enrollment-bearing reason, identifier, provenance value, or retained display name is rejected where caller-controlled or represented only by an explicit redacted marker plus a non-reversible redaction digest
- **AND** the redaction digest is distinct from prohibited credential-derived or token-derived hashes
- **AND** no secret, credential hash, token hash, private key, CSR body, certificate, bundle bytes, filesystem path, or caller-supplied actor identity enters audit

### Requirement: Display-Name Creation And Recovery Are Explicitly Distinct

`orchardctl nodes enrollment create` SHALL accept at most one optional `--display-name NAME` through the same shared trimming, validation, and uniqueness contract as Console.
Omitting the option SHALL preserve generated-name behavior.
Ordinary creation with an existing display name SHALL reject without mutation and MUST NOT select recovery.
Recovery SHALL select an exact Node ID, retain its stored display name, and accept no rename.
Ordinary issuance SHALL NOT run stale-publication reconciliation as a pre-validation side effect.

#### Scenario: CLI creates a named Enrollment

- **WHEN** an operator supplies one valid unique `--display-name NAME`
- **THEN** CLI trims and passes the name through the shared bounded UTF-8 and control-character validation
- **AND** Orchard creates the provisioned Node with that exact display name
- **AND** CLI and Console enforce the same uniqueness result

#### Scenario: CLI omits display name

- **WHEN** `--display-name` is omitted
- **THEN** Orchard preserves the generated `provisioned-<node-id-prefix>` behavior
- **AND** omission does not select or search for an existing Node

#### Scenario: Name is malformed or repeated

- **WHEN** `--display-name` is repeated, empty, invalid UTF-8, contains prohibited control characters, or exceeds 128 bytes
- **THEN** CLI fails before trust reads, token generation, output publication, or database mutation

#### Scenario: Ordinary creation uses an existing name

- **WHEN** Console or CLI ordinary creation supplies a display name already reserved by any Node
- **THEN** Orchard returns the shared duplicate-name result
- **AND** Orchard creates no Node, Enrollment, audit, or unrelated reconciliation mutation
- **AND** Orchard does not recover, replace, rename, or take over the existing Node

#### Scenario: Explicit recovery retains the stored name

- **WHEN** recovery targets an eligible Node by exact Node ID
- **THEN** the preview and result show the existing stored display name
- **AND** the successor remains linked to that same Node
- **AND** recovery accepts no replacement display-name parameter

### Requirement: Recovery Secret Output Remains One-Time And Redacted

The successor Bootstrap Token and encoded bundle SHALL exist only in the original successful execution response and the selected transient publication adapter.
Orchard MUST NOT place recovery bundle material in a URL, flash message, session, cookie, log, audit payload, `data-*` attribute, reusable endpoint, duplicate response, support bundle, or structured error.
Every recovery presentation and machine-readable result SHALL use bounded non-secret identifiers and stable codes.

#### Scenario: Original execution delivers successor material

- **WHEN** recovery commits and the selected publication adapter receives the successor bundle
- **THEN** the adapter may deliver those bytes exactly once under the existing protected CLI or authenticated same-origin Console contract
- **AND** it clears transient bytes according to that adapter's existing lifecycle

#### Scenario: Duplicate or restored status is rendered

- **WHEN** a duplicate request, page reload, reconnect, status lookup, audit view, or support flow renders the recovery operation
- **THEN** Orchard exposes only secret-free durable state and guidance
- **AND** Orchard does not redisplay, resend, reconstruct, or silently renew the bundle

#### Scenario: Detailed history is not authorized

- **WHEN** a stale bundle is redeemed through the public bootstrap boundary
- **THEN** Orchard returns the existing generic rejection
- **AND** it does not reveal whether the Enrollment was superseded, revoked, expired, output-failed, replaced by a later generation, or associated with an eligible Node
