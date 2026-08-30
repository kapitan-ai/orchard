## Why

`SPEC.md` §9.1 requires native Prometheus metrics but does not yet define a
safe Controller exposure boundary, bounded label contract, metric ownership, or
failure isolation. Issue #123 establishes that contract before dependencies or
product instrumentation are added.

## What Changes

- Define protected Controller `GET /metrics` on the existing HTTP listener,
  using the existing operator-or-admin service-account bearer boundary.
- Define the exact §9.1 families, labels, immutable histogram buckets, bounded
  vocabularies, authoritative sources, and logical-Request accounting.
- Select `telemetry_metrics_prometheus_core` 1.2.1 (Apache-2.0) while
  deliberately retaining `telemetry_metrics` declarations and
  `telemetry_poller` collection.
- Permit canonical raw Tenant identifiers only on the protected site-local
  surface; require issue #115 to remove tenant and user dimensions before any
  later external egress.
- Bound the pilot to 5,000 active materialized series with an explicit worksheet,
  Orchard-owned admission/snapshot mechanisms, gauge expiry, and failure
  isolation.
- Add no attempt/retry metric families, collector, backend, tracing, dashboards,
  alerts, Node Agent endpoint, separate listener, or HMAC tenant alias.
- Carry bounded monotonic per-model worker-crash counts over the existing
  authenticated Runtime Endpoint status/heartbeat path for active-Controller
  positive-delta emission.

SPEC.md impact: §9.1 records the approved shared-listener, authentication,
failure-isolation, and protected raw-tenant-label posture.

## Capabilities

### New Capabilities

- `controller-prometheus-metrics`: Defines the protected, bounded Controller
  Prometheus metrics floor.

### Modified Capabilities

None.

## Impact

- Unauthenticated callers cannot scrape Controller metrics.
- Authorized site-local scrapers may observe canonical Tenant identifiers.
- Reporter failure can make an authorized scrape return `503`, but cannot make
  Controller serving or control-plane work fail.
- Existing §9.1 logical-Request, admission, quota, and client-visible metrics
  count once across any execution attempts. Future attempt metrics remain owned
  by issue #121 and are out of scope.
- Worker-crash metrics advance only from accepted authenticated active-Controller
  heartbeat observations; baselines, duplicates, and resets do not overcount.
