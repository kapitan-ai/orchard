## Why

Pilot #118 must stop disclosing Controller diagnostics through unauthenticated
health before Orchard can truthfully implement every `SPEC.md` §3.1 readiness
condition. The exposure boundary can be fixed independently if the unchanged
incomplete predicate is identified explicitly and never presented as complete.

## What Changes

- Make public liveness and readiness exact status-only responses.
- Move detailed health to authenticated Operator `GET /ops/v1/health` with
  `Cache-Control: no-store`.
- Identify the unchanged predicate as `orchard.readiness.legacy_m0.v1` and publish
  its ordered checks only through Operator health.
- Move observational runtime, build, transport, and Console probes out
  of the public controller.
- Accept bounded credential-free `orchardctl status` feature loss and remove its
  reliance on remote version/build fields.
- Reconcile Console copy and operator/development/packaging documentation.
- Leave the complete §3.1 aggregate and issue #115 external probe out of scope.

SPEC.md impact: §3.1 defines exact public bodies, authenticated Operator detail,
and the temporary legacy predicate exception without weakening the final aggregate.

## Capabilities

### New Capabilities

- `pilot-health-exposure`: Defines the staged public/Operator exposure split and
  explicit legacy readiness contract.

### Modified Capabilities

None.

## Impact

- Unauthenticated callers lose all health detail except stable status.
- Operator/admin API Client credentials are required for diagnostics.
- Existing readiness pass/fail behavior remains unchanged.
- Public diagnostic details are removed permanently; no compatibility shim exists.
