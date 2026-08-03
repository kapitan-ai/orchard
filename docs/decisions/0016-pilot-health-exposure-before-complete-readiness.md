# Pilot health exposure is split before complete readiness lands

## Status

Accepted.

Owner decision recorded 2026-08-03 for pilot issue #118.

## Context

`SPEC.md` §3.1 requires Controller readiness to include Postgres reachability,
current migrations, loaded model/tenant/API-key caches, and write-path leadership
when Active/Standby mode is enabled. Orchard does not yet have authoritative
loaded-state interfaces for all three caches, so the complete aggregate cannot be
implemented honestly in this pilot change.

The current unauthenticated `GET /health/ready` evaluates only the M0-era checks
for Postgres, migrations, public API HTTPS, and a constant Controller boot flag.
It also discloses build, transport, Console, runtime, licensing, check, failure,
and remediation details. Waiting for the complete §3.1 aggregate would preserve
that unnecessary unauthenticated disclosure through the pilot.

## Decision

Split health exposure now, before the complete §3.1 readiness aggregate lands.

`GET /health/live` remains unauthenticated and returns exactly
`{"status":"ok"}` with HTTP 200. `GET /health/ready` remains unauthenticated
and returns exactly `{"status":"ok"}` with HTTP 200 or
`{"status":"error"}` with HTTP 503. Public health responses contain no other
fields.

Detailed diagnostics move to authenticated Operator `GET /ops/v1/health` under
the existing cluster-scoped Operator-or-admin authorization boundary. The response
is non-cacheable with `Cache-Control: no-store` and includes the readiness contract,
ordered checks, failure detail and bounded remediation when applicable, plus the
sanitized observational build, transport, Console, runtime, and licensing fields
removed from public readiness.

The staged evaluator is explicitly identified as
`orchard.readiness.legacy_m0.v1`. `Orchard.API.Readiness.status/0` and its predicate
remain unchanged in this change. This identifier permits the pilot to disclose
which incomplete predicate it is using without claiming complete §3.1 compliance.
The later aggregate migration replaces it with a new contract identifier only when
authoritative cache-loaded and conditional leadership sources exist.

No readiness constants, configuration flags, readiness-only caches, unrelated
caches, successful database queries, or process-presence checks may stand in for
the missing §3.1 authorities. The complete aggregate remains a separately reviewed
migration. When it lands, public and Operator health consume the same aggregate.

The exposure change is one-way. No compatibility route, query parameter, content
negotiation, cache, or other shim may restore detailed unauthenticated health.
Public deployment and diagnostic details are never restored.

Credential-free `orchardctl status` accepts bounded feature loss. It may report the
local CLI or installed package version and public ready/degraded status, but it may
not infer or present remote Controller version or build identity from public
readiness. Operator diagnostics are the authenticated source for those fields.

## Consequences

- Pilot operators stop receiving detailed diagnostics without an Operator or admin
  API Client token.
- Existing unauthenticated consumers must use HTTP status and the exact status-only
  body.
- Console readiness remains an internal view and must not claim to mirror the
  public response body.
- The pilot can remove public disclosure now while accurately labeling the staged
  predicate as incomplete.
- Full §3.1 readiness, including authoritative cache hydration and conditional
  leadership, remains required later and is not claimed by this decision.

## Rejected alternatives

### Wait for the complete aggregate before removing disclosure

Rejected because it keeps sensitive deployment diagnostics public even though the
exposure boundary can be corrected independently and labeled honestly.

### Add temporary readiness shims

Rejected because shims would create false §3.1 compliance and become a second
source of readiness truth.

### Preserve rich public readiness for compatibility

Rejected because compatibility would defeat the disclosure fix. Consumers must
migrate to status-only public health or authenticated Operator health.
