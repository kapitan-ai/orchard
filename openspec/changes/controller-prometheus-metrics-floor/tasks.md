## 1. Contract

- [x] 1.1 Update `SPEC.md` §9.1 with the approved listener, authentication,
  protected Tenant-label, external-egress, and failure-isolation posture.
- [x] 1.2 Define exact §9.1 families, source ownership, bounded categorical
  vocabularies, logical-Request semantics, gauge expiry, and failure isolation.
- [x] 1.3 Fix immutable buckets for the five §9.1 histograms and complete the
  5,000-series pilot worksheet with explicit Tenant, model, Node, and endpoint
  ceilings and headroom.

## 2. Implementation

- [x] 2.1 Pin `telemetry_metrics_prometheus_core` 1.2.1, record Apache-2.0, and
  reuse `telemetry_metrics` plus `telemetry_poller`.
- [x] 2.2 Add authenticated `GET /metrics` on the existing Controller HTTP
  listener with no-store, auth-before-reporter ordering, sanitized `503`, and
  no separate listener.
- [x] 2.3 Add the §9.1 counter and histogram families through the Orchard-owned
  series-admission registry and the core reporter.
- [x] 2.4 Add the §9.1 gauges through `telemetry_poller`, the Orchard-owned
  replaceable gauge snapshot store, and the combined bounded renderer.
- [x] 2.5 Enforce exact descriptors, normalization vocabularies, immutable
  buckets, gauge expiry, and the 5,000 active-series ceiling.
- [x] 2.6 Carry bounded monotonic per-model worker-crash counts over the existing
  authenticated Runtime Endpoint status/heartbeat path and emit accepted active-
  Controller positive deltas exactly once.

## 3. Tests and validation

- [x] 3.1 Test `401`/`403`, no-store, reporter non-invocation before auth,
  authorized exposition, sanitized `503`, and absence of a second listener.
- [x] 3.2 Test every owner boundary, bounded vocabulary, once-per-logical-Request
  accounting across attempts, exact histogram buckets, and prohibited labels.
- [x] 3.3 Test gauge zero/stale/removal behavior, restart reset, Orchard-owned
  admission/snapshot behavior, and exact active-series accounting at the pilot
  ceilings.
- [x] 3.4 Test reporter startup, handler, poll, render, timeout, and repeated-crash
  isolation without affecting boot, inference, scheduling, or recovery.
- [x] 3.5 Run the applicable Elixir quality workflow and coverage.
- [x] 3.6 Run strict OpenSpec validation for
  `controller-prometheus-metrics-floor`.
- [x] 3.7 Test unexpected-worker-death classification, status/proto mapping, and
  active-Controller heartbeat delta, duplicate, malformed-entry, and reset behavior.
