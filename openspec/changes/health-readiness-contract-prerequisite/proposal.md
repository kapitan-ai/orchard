## Why

Orchard's unauthenticated readiness endpoint currently discloses build, transport, Console, runtime, licensing, check, reason, and remediation details while evaluating only an M0 subset of the readiness conditions required by `SPEC.md` section 3.1.
Issue #115 cannot safely implement its approved public-health split until separate control-plane owners provide authoritative model, tenant, and API-key cache hydration and the existing write-path leadership surface is confirmed to provide bounded production authority.

## What Changes

- Record the approved future contract for exact minimal unauthenticated `GET /health/live` and `GET /health/ready` responses.
- Record the approved future `GET /ops/v1/health` detail route under the existing cluster-scoped Operator-or-admin authorization boundary.
- Require one complete aggregate readiness evaluation for both public readiness and Operator health detail.
- Identify authoritative model, tenant, and API-key cache hydration as blocking dependencies owned by separate control-plane changes.
- Require an explicit adequacy assessment of the existing `Orchard.ControlPlane` write gate and status surface, with separate ownership only for demonstrated gaps.
- Forbid constants, configuration flags, readiness-only caches, unrelated caches, or successful database queries from standing in for the missing authorities.
- Define the consumer migration and validation gates that must pass when the health behavior is implemented.
- Make no production code, test, `SPEC.md`, or runtime behavior change in this prerequisite proposal.
- Do not add the external probe, terminal-event validator, OpenTelemetry Collector, product metrics, tracing, logs, dashboards, alerts, or Grafana resources in this change.

SPEC.md impact: none in this prerequisite proposal.
`SPEC.md` remains authoritative and unchanged until the blocking authorities exist and the accepted health behavior is implemented.

## Capabilities

### New Capabilities

- `controller-health-prerequisites`: Defines the approved future health boundary, its authoritative dependencies, no-shim rule, and implementation gates without changing runtime behavior.

### Modified Capabilities

None.

## Impact

- Adds a collaborator-reviewable OpenSpec contract only.
- Requires separate control-plane change ownership for genuine cache hydration and an explicit assessment of the existing leadership surface before issue #115 implements health wiring.
- Preserves existing Controller routes, readiness behavior, Console, CLI, packaging, documentation, tests, and `SPEC.md`.
- Adds no dependency, vendor SDK, telemetry backend, exported identifier, or Grafana Cloud resource.
