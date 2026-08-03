## Why

Orchard's unauthenticated readiness endpoint discloses build, transport, Console,
runtime, licensing, check, reason, and remediation details while evaluating only an
M0 subset of the readiness conditions required by `SPEC.md` §3.1. The complete
aggregate still depends on authoritative model, tenant, and API-key cache hydration
and a confirmed conditional leadership source, but pilot #118 must not retain the
public disclosure while those dependencies are built.

## What Changes

- Amend the prerequisite from one blocked atomic migration to two ordered stages.
- Stage one removes public diagnostic disclosure now: exact status-only public
  health, authenticated Operator detail, and an explicit
  `orchard.readiness.legacy_m0.v1` identifier for the unchanged staged predicate.
- Stage two later replaces the legacy predicate with one complete `SPEC.md` §3.1
  aggregate after its authoritative dependencies exist.
- Keep the no-shim rule for the complete aggregate and prohibit claims that stage
  one satisfies full §3.1 readiness.
- Keep the accepted bounded `orchardctl status` feature loss and prohibit any new
  unauthenticated version/build route or probe credential.
- Keep external probe, telemetry, dashboards, alerts, and issue #115 observability
  harness work out of this change.

SPEC.md impact: §3.1 now defines exact public health bodies, authenticated Operator
health detail, and the explicitly temporary legacy predicate.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `controller-health-prerequisites`: permits immediate exposure separation while
  preserving the authoritative dependency gate and no-shim rule for the later
  complete readiness aggregate.

## Impact

- Public health becomes status-only before full aggregate readiness is available.
- Operator diagnostics move to `GET /ops/v1/health` under existing authorization.
- The incomplete predicate remains behaviorally unchanged and is labeled rather
  than presented as full §3.1 compliance.
- Full aggregate ownership remains with the prerequisite control-plane changes.
