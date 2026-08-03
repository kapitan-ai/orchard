## Why

Issue #118 CP1 needs a reproducible acceptance probe whose artifact and
non-secret configuration can be pinned before pilot evidence is collected.
Issue #115 Phase 0 therefore needs a small, versioned producer artifact rather
than an observability backend or a change to Orchard's public health contract.

## What Changes

- Add a versioned configuration contract for one streaming
  `POST /v1/responses` acceptance request.
- Add grammar-backed safe result identifiers and stable outcome classifications.
- Require a validated loopback HTTP or system-trusted HTTPS credential
  destination.
- Fail closed on malformed buffered terminal candidates and optionally reconcile
  HTTP and durable terminal outcomes through `Orchard.Requests`.
- Add a consumer-owned pin example for issue #118 that records the exact Git
  commit and non-secret configuration digest.
- Document caller-relative invocation, owned exit codes, update, and rollback.
- Add no Prometheus, Grafana, OpenTelemetry Collector, telemetry pipeline,
  product instrumentation, or public health response changes.

SPEC.md impact: none. This change packages a probe for existing `SPEC.md`
section 7.2.5 streaming Responses behavior and existing durable request
lifecycle state; it does not change product runtime behavior.

## Capabilities

### New Capabilities

- `observability-phase0-probe`: Defines the versioned Phase 0 acceptance probe,
  sanitized result, optional durable validation, and pilot pin contract.

### Modified Capabilities

None.

## Impact

- Adds scripts, controller-side probe contract tests, pilot documentation, and
  this OpenSpec change.
- Uses existing Elixir/OTP, JSON, Responses API, and request persistence
  interfaces; adds no dependency.
- Keeps credentials in environment variables and outside configuration,
  results, pins, logs, and repository content; validates their destination and
  header-safe form before request construction.
