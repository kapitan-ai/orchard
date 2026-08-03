## 1. Contract and decision

- [x] 1.1 Record ADR 0016 for exposure-before-complete-readiness, the legacy
  predicate identifier, no-shim rule, and permanent public detail removal.
- [x] 1.2 Update `SPEC.md` §3.1 with exact public bodies, authenticated Operator
  health, and the explicitly temporary predicate allowance.
- [x] 1.3 Amend `health-readiness-contract-prerequisite` to the ordered two-stage
  migration while preserving the complete-aggregate dependency gate.

## 2. Health implementation

- [x] 2.1 Add supervised, fail-closed `Orchard.API.HealthEvaluation` over unchanged
  readiness behavior with a fixed 5-second production timeout and explicit test
  seam.
- [x] 2.2 Add `Readiness.contract_version/0` and `check_order/0` without changing
  `Readiness.status/0` checks or causal order.
- [x] 2.3 Move diagnostic metadata and observational probes into
  `Orchard.API.OperatorHealth`.
- [x] 2.4 Make public live/ready controllers exact and status-only.
- [x] 2.5 Add authenticated `GET /ops/v1/health` with `Cache-Control: no-store`
  installed before authentication.

## 3. Consumers and documentation

- [x] 3.1 Update `orchardctl status` to enforce the exact HTTP/body pair table,
  use local version identity, render a state-free Console URL, point degraded
  callers to authenticated diagnostics, and remove dormant rich-public helpers.
- [x] 3.2 Correct Console Overview readiness subtitle.
- [x] 3.3 Update local-development, packaging, and M0 milestone documentation.

## 4. Tests and validation

- [x] 4.1 Add full Endpoint exact-body tests for ordinary pass/fail, raise, exit,
  throw, malformed return, timeout, and timed-out task termination.
- [x] 4.2 Add full Endpoint Operator auth, no-store, no-probe, genuine cluster
  operator, separate admin, ordinary failure, and unavailable failure tests.
- [x] 4.3 Add exact ready/degraded pairs plus representative mismatch,
  extra-field, and unsupported-status CLI coverage; remove rich-public fixtures.
- [x] 4.4 Run `mise exec -- mix format`.
- [x] 4.5 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 4.6 Run `mise exec -- mix credo --strict`.
- [x] 4.7 Run focused Controller and CLI tests.
- [x] 4.8 Run strict OpenSpec validation for `pilot-health-exposure-split`.
