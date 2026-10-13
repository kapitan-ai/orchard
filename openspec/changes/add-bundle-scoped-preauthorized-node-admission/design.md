## Context

Node Enrollment proves possession of one Node key and establishes one
certificate-bound Node identity. Node Admission is a separate governance
decision that creates policy and initial transport-authorization metadata.
This change allows the administrator to make that governance decision at
Enrollment issuance while retaining action-time validation at redemption.
The enabling mode is one durable cluster policy so Active and Standby
Controllers cannot derive different admission authority from local config.

## Authority and data flow

```diagram
┌──────────────────────┐
│ Authorized admin     │
│ preview + confirm    │
└──────────┬───────────┘
           │ leader-only issuance
           ▼
┌──────────────────────┐      non-secret ref/digest      ┌──────────────────┐
│ Durable preauth      │────────────────────────────────▶│ Enrollment Bundle│
│ exact policy + state │                                 │ bootstrap secret │
└──────────┬───────────┘                                 └─────────┬────────┘
           │ current durable authority                              │ transfer
           │                                                        ▼
           │                                             ┌──────────────────┐
           │                                             │ Node Agent       │
           │                                             │ local key + CSR  │
           │                                             └─────────┬────────┘
           │ certificate-authenticated redemption                  │
           ▼                                                        ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ Active Controller transaction                                              │
│ validate enrollment identity first; then revalidate exact preauthorization │
│                                                                            │
│ success: register + admit + decision + capacity + audit + pending grants   │
│ drift:   register + consumed_pending_review + reason + audit               │
│ failure: no partial commit                                                  │
└───────────────────────────────┬────────────────────────────────────────────┘
                                │ admitted is still not active
                                ▼
             certificates + active Peer Grant + fresh authenticated
             Runtime Endpoint observation + all scheduler/capacity gates
```

The bundle transports the existing one-time Bootstrap Token. It may also carry
a bounded preauthorization identifier and digest so the operator and Controller
can correlate intent. Those extra fields are not a separate bearer, but the
complete bundle remains sensitive: a thief who redeems the Bootstrap Token
first can establish the allocated Node key and, if every current bound predicate
passes, obtain the preauthorized admission. The issuance preview makes this
consequence explicit. The Controller ignores client-supplied policy values and
loads the exact durable record.

## Durable record and state

The record binds:

- preauthorization contract version and UUID;
- cluster, Enrollment, allocated Node, issuing Controller, and issuing admin;
- issued-at and expiry, bounded by Enrollment expiry;
- pool and routing-policy identifiers and expected revisions;
- explicit Controller Dispatch Ceiling and non-empty policy reason;
- dispatch-capacity phase and expected revision;
- required trust, inventory, compatibility, platform, and admission predicates;
- optional exact installation UUID/profile/source-manifest constraints;
- Action Preview digest, confirmation evidence, and issuance audit reference;
- current state, consumption outcome, execution provenance, bounded reason,
  and terminal audit reference.

The states are `authorized`, `consumed_admitted`,
`consumed_pending_review`, `revoked`, and `expired`. Terminal states never
return to `authorized`. A cleanup policy may archive records only after their
required audit and decision retention; it cannot erase evidence needed to
explain an admitted Node.

## Transaction and lock order

Issuance locks and reads the durable dispatch-capacity phase and admission-mode
singleton, validates the Enrollment placeholder and policy revisions, then
creates the immutable preauthorization and audit evidence. Redemption enters
the existing leader-only write gate; locks the dispatch phase and admission
mode; acquires the cluster Controller-membership transaction lock; locks the
eligible Controller rows in stable Controller-ID order; and then locks the exact
Enrollment, preauthorization, Node, policy, decision, grant, and audit parents
in a stable documented order.

Controller enrollment, retirement, and post-admission initial-grant creation
use the same membership lock. Parent locks and exact uniqueness constraints
serialize rows that do not exist yet. The eligible Controller snapshot is taken
under that lock: later enrollment uses the existing separate initial-grant
operation, while later retirement follows ordinary grant revocation rather than
retroactively changing the admission transaction.

The full success transaction persists certificate issuance state and Enrollment
consumption, both Node transitions, preauthorization consumption, admission
decision, phase-derived capacity policy, audit rows, and one
`pending_delivery` grant record per currently eligible Controller. It does not
derive or deliver plaintext grants. Any persistence failure rolls back all of
those writes.

The pending-review transaction is allowed only after ordinary identity and
Enrollment validation succeeds. For a still-`authorized` record it persists
registration, Enrollment and preauthorization consumption, the bounded reason,
and audit. For a record already `revoked` or `expired`, it leaves that terminal
state unchanged and links registration to the pending-review reason. Neither
path creates an admission decision, dispatch policy, or grant metadata because
no admission occurred. Invalid trust or unavailable write authority fails the
Enrollment rather than disguising it as pending review.

## Race, replay, and recovery decisions

Controller database time and state under row locks decide races:

- Revocation, expiry, or mode disablement observed before admission commit
  prevents auto-admission and yields pending review only when registration is
  independently valid.
- A record already `revoked` or `expired` remains terminal when separately valid
  Enrollment registers pending review. Mode disablement or policy drift consumes
  a still-`authorized` record as `consumed_pending_review`.
- A completed admission wins over a later revoke or disable request; undo uses
  the normal lifecycle and credential controls.
- Concurrent exact redemptions have one writer. A matching loser returns the
  winner's durable result; a different key, CSR, Node, cluster, or intent fails.
- A response-loss retry must present the same Enrollment, key possession, CSR
  fingerprint, and preauthorization. It creates no duplicate policy, decision,
  certificate, grant generation, or successful audit event.
- Restart begins from durable records. Process memory, PID, socket ownership,
  BEAM name, connection incarnation, or prior connection cannot reconstruct or
  consume authority.
- Controller enrollment or retirement racing redemption is ordered by the
  membership lock. Eligibility is measured at that linearization point.

No process-local leader epoch is invented. A later Active Controller may redeem
a durable preauthorization after proving current leadership and every bound
predicate; issuer Controller identity remains provenance, not a requirement to
keep the same process alive.

## Threat and failure analysis

| Threat or failure | Required outcome |
| --- | --- |
| Bundle stolen before redemption | First holder of the Bootstrap Token may establish the allocated Node key and reach preauthorized admission; preview warns explicitly and protected transfer, short expiry, one-use redemption, revocation, and exact binding limit but do not eliminate this risk |
| Wrong cluster, Node, key, or CSR | Reject under Enrollment identity rules; no pending-review trust bypass |
| Bundle policy tampered | Ignore client policy; exact durable record and digest must match |
| Pool, routing policy, compatibility, or capacity phase drift | Register only when trust is valid, consume as pending review, create no admission/policy/grants |
| Mode disabled or record revoked before lock | No automatic admission; valid Enrollment may register pending review |
| Admission commits before disable/revoke | Preserve committed admission; operator uses normal cordon/decommission/revocation controls |
| Concurrent redemptions | One commit; matching replay returns it, divergent replay fails |
| Audit, policy, decision, or grant-row failure | Roll back full admitted outcome |
| Controller crashes before commit | No outcome; exact valid retry may proceed |
| Controller crashes after commit before response | Exact retry returns durable outcome without duplicate effects |
| Node or Controller restart | Durable records plus fresh current evidence are required; no process-derived authority |
| Same-host Controller and Node | Apply identical admission, certificate, Peer Grant, and Runtime Endpoint gates; locality grants nothing |
| Remote expansion | Allocate distinct Node/key/certificate/name/install identity; never clone local authority |

## Alternatives rejected

**Global auto-admit mode** is rejected because configuration alone cannot bind
an administrator's decision to one Node and one policy.

**Bundle possession as admission authority** is rejected because theft would
collapse Enrollment and governance and because bundle fields are client input.

**Select policy at join** is rejected because no administrator previews the
actual decision and drift can silently change authority.

**Always fail the complete join on admission-only drift** is rejected because a
valid established identity can safely remain non-schedulable for manual review.

**Always admit using stale preview values** is rejected because Action Preview
never replaces mutation-time revalidation.

**Revoke a preauthorization by de-admitting an already admitted Node** is
rejected because it conflates one-use issuance control with lifecycle and
credential revocation.

**Infer authority from local installation identity** is rejected because it
would make same-host deployment a trust shortcut and break safe later
separation.
