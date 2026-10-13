# Change: Add bundle-scoped preauthorized Node Admission

## Why

Orchard's secure Enrollment flow can establish one exact Node identity, but
every successful registration currently requires a later administrator
admission action. An administrator should be able to review and authorize the
complete future admission while issuing that one short-lived bundle without
turning bundle possession, certificate issuance, locality, or Controller mode
into admission authority.

The existing KAP-28 proposal is directionally correct but not sufficient for
implementation. It does not close durable outcome states, mode-disable and
revocation races, response-loss replay, admission-only drift, restart behavior,
or the existing Action Preview conflict.

## What Changes

- Keep manual Node Admission as the deny-by-default mode.
- Add an explicitly enabled mode that permits an administrator to issue one
  durable preauthorization for one exact Enrollment and allocated Node.
- Make issuance the previewed and confirmed eligibility-changing action; join
  performs no second human interaction but revalidates every predicate.
- Bind exact identity, policy, capacity, expiry, revision, issuer, preview, and
  audit evidence without putting reusable admission authority in the bundle.
- Define closed one-use outcomes, deterministic revocation/expiry/disablement
  races, exact replay, divergent replay refusal, and restart recovery.
- Commit successful registration, admission, decision, dispatch policy, audit,
  consumption, and initial pending Peer Grant metadata atomically.
- Permit only a bounded registered-pending-review fallback when Enrollment
  trust succeeds but an admission-only predicate drifts.
- Preserve Node Certificate, Peer Grant, Runtime Endpoint, activation,
  scheduling, placement, capacity, provider/model, KAP-18/KAP-26, KAP-82/KAP-84,
  and Ubuntu single-host authority boundaries.
- Reconcile older active OpenSpec wording that treated every registration as
  requiring a later manual action while preserving that behavior as the default.

## Capabilities

### New Capabilities

- `preauthorized-node-admission`: Defines issuance authority, exact binding,
  one-use outcomes, atomic redemption, pending-review fallback, replay/race
  behavior, audit, diagnostics, and non-authority boundaries.

### Modified Capabilities

- `dispatch-capacity`: Allows the exact preauthorized ceiling and reason to be
  consumed by the same atomic admission transaction without telemetry defaults.
- `runtime-endpoints`: Makes explicit that preauthorization cannot establish or
  activate a Runtime Endpoint or Peer Grant.
- `ubuntu-single-host-composition`: Binds the local profile's installation and
  source identity as compatibility predicates without deriving admission from
  colocation.

## Impact

- SPEC.md impact: §§4.1 through 4.4, 4.6.2, 7.3.1, 7.4.1, 10.5, 10.9, 11.9,
  and 11.10 define the durable record, preview timing, atomic outcomes, audit,
  CLI behavior, and same-host non-bypass rule.
- Decision impact: proposed ADR 0038 records the authority and fallback choice
  while preserving ADRs 0012, 0013, 0035, and 0037.
- OpenSpec reconciliation: active operator-first-run, Console enrollment, and
  cluster-management wording is narrowed so manual review remains the default
  rather than the only possible explicitly authorized path.
- Implementation impact: this proposal makes no code or data-model change.
  Implementation should be a separately authorized bounded issue before
  KAP-100 consumes the behavior.
- Qualification impact: deterministic contract scenarios do not satisfy KAP-84
  mixed-host evidence or qualify any Node, platform, transport, provider, model,
  release, or support profile.

## Disposition

**Contract accepted; implementation held.** The Repository Owner accepted exact
contract commit `5544533123d494d3c124e3f5c44373db74be2c96` on 2026-09-21.
Implementation requires a separately created and authorized bounded issue for
persistence and issuance/revocation, atomic redemption and replay/fallback,
operator output, and deterministic security tests. KAP-100 remains blocked
until that implementation is separately accepted. KAP-27 remains closed.
