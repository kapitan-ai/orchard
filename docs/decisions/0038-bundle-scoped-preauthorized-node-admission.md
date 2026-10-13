# ADR: Bind preauthorized Node Admission to one Enrollment

## Status

Accepted by the Repository Owner under KAP-28 on 2026-09-21 at exact contract
commit `5544533123d494d3c124e3f5c44373db74be2c96`.

The Repository Owner separately accepted the bounded KAP-109 source
implementation and isolated PostgreSQL validation on 2026-09-21 at exact commit
`31b7186a46decf1edd609d3bdafeb7fd76d5d690`. The unexecuted exhaustive
bound-field, race, restart, and same-host security scenario matrix is retained
as deferred hardening rather than a KAP-109 or KAP-100 blocker. This acceptance
does not authorize real credential issuance, Node enrollment or admission,
host or service mutation, KAP-100 or KAP-102 execution, qualification, or a
support claim.

## Context

`SPEC.md` §§4.2 through 4.4 currently make manual administrator admission the
only `registered -> admitted` trigger. That safe default forces an operator to
return after every otherwise successful Node Enrollment, even when the same
administrator can review and authorize the complete admission policy while
creating the short-lived per-Node bundle.

Treating bundle possession, certificate issuance, a same-host connection, or a
Controller configuration flag as admission would collapse independent identity,
trust, governance, and runtime boundaries. Deferring policy selection until
join would instead let an unattended action make a decision the administrator
never previewed. The contract therefore needs one durable, narrowly bound
authorization intent and deterministic behavior when its assumptions drift.

## Decision

Manual admission remains the default. The admission mode is one durable cluster
policy, not per-process Controller configuration that can diverge across
Active/Standby instances. In explicitly enabled mode an administrator may issue
one admission preauthorization while creating one exact Node Enrollment Bundle.
Issuance, not join, is the eligibility-changing admin action: it requires the
existing Action Preview, explicit confirmation, leader-only write gate,
mutation-time revalidation, and cluster audit.

The preauthorization is a durable Controller record bound to one cluster,
Enrollment, allocated Node, issuing Controller and administrator, bounded
expiry, exact pool and routing-policy revisions, explicit Controller Dispatch
Ceiling and reason, required trust/inventory/compatibility predicates,
dispatch-capacity phase, and preview evidence. The bundle may carry a non-secret
record identifier and digest, but those fields are not separate bearer
authority. The complete bundle remains sensitive because its Bootstrap Token
authorizes first redemption; theft before redemption can let the holder create
the allocated Node's key and reach the preauthorized admission outcome. The
issuance preview and confirmation must expose that consequence. Its states are
`authorized`, `consumed_admitted`, `consumed_pending_review`, `revoked`, and
`expired`; only `authorized` can admit on join.

Redemption first satisfies ordinary Enrollment and Node Certificate proof. It
then revalidates the complete bound admission decision under current Controller
authority. Success commits registration, admission, the admission decision,
dispatch-capacity policy, audit evidence, preauthorization consumption, and
initial `pending_delivery` Peer Grant metadata in one transaction. The issuing
administrator remains the decision principal and the redeeming Controller is
separate execution provenance. Grant delivery and activation happen later
through their existing authenticated contracts.

If Enrollment remains valid but an admission-only predicate has drifted,
redemption may commit registration plus a durable consumed-pending-review
outcome. It commits no admission, capacity policy, or grant metadata. Identity,
Bootstrap Token, CSR, certificate, cluster, Node, leadership, or persistence
failure cannot use this fallback. Concurrent redemption has one winner, exact
response-loss replay returns the same outcome, and divergent replay fails
closed.

Controller-authoritative time and locked durable state adjudicate expiry,
revocation, mode-disable, and redemption races. Disablement prevents new
issuance and later automatic admission but does not reverse an already committed
admission. A record already revoked or expired remains in that terminal state
when separately valid Enrollment registers pending review; mode disablement or
admission-only drift consumes a still-authorized record as pending review.
Changing the mode is itself previewed, confirmed, leader-only, and audited.
Restart and reconnect reconstruct no authority from process memory, PID,
socket, BEAM name, connection incarnation, or locality.

The Ubuntu single-host profile uses the same contract. Its installation UUID,
profile, and source manifest may be compatibility constraints but never replace
Node identity, admission, certificates, Peer Grants, or Runtime Endpoint
authorization. A later remote Node receives distinct identity and authority;
none is cloned from the local Node.

## Consequences

The operator can approve an exact future admission once, before transferring
the bundle, without weakening manual deny-by-default behavior for other
Enrollments. This deliberately removes the later human review that might have
caught bundle theft, so protected transfer, short expiry, one-use behavior, and
the explicit preview warning are security-critical. Admission policy drift
becomes visible pending review rather than silent policy substitution or partial
authority. Persistence and concurrency are more complex because dispatch phase,
admission mode, Controller membership, Enrollment, admission, capacity, audit,
and initial grant metadata must share one deterministic transaction and lock
order.

Preauthorization is not enrollment, authentication, connection authorization,
activation, scheduling, placement, capacity evidence, provider/model approval,
or qualification. It adds no outbound session, NAT or proxy traversal,
localhost shortcut, shared cookie, KAP-27 behavior, or support claim. ADRs 0012,
0013, 0035, and 0037 retain their existing authority boundaries; KAP-82/KAP-84,
KAP-18, and KAP-26 retain their qualification and runtime ownership gates.

The existing Linear proposal is therefore insufficient as an implementation
contract without this amendment. After owner acceptance, implementation should
be a separately authorized bounded issue covering durable persistence and
issuance/revocation, atomic redemption and replay/fallback, operator surfaces,
and deterministic security tests before KAP-100 consumes the capability.

## SPEC.md impact

Update §§4.1 through 4.4, 4.6.2, 7.3.1, 7.4.1, 10.5, 10.9, 11.9, and 11.10 to
define the authorization record, atomic outcomes, preview timing, policy and
Peer Grant interaction, audit, CLI semantics, and same-host non-bypass rule.
