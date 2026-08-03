## Context

The Phase 0 artifact is an acceptance probe consumed by issue #118 CP1. It
exercises the existing typed Responses terminal contract and optionally
reconciles that observation with existing request persistence.

## Goals / Non-Goals

**Goals:**

- Freeze exact configuration and result schema version 1.
- Send credentials only to validated loopback HTTP or system-trusted HTTPS
  destinations.
- Fail closed on malformed or contradictory typed terminal evidence.
- Reconcile Controller-local HTTP and durable terminal outcomes.
- Preserve caller-relative config paths and document launcher exit semantics.
- Give issue #118 an immutable SHA-and-digest pin contract.

**Non-Goals:**

- Incremental SSE delivery, progress, or never-closing-stream proof.
- Collector, Prometheus, Grafana, issue #123, or product instrumentation.
- Packaged Controller database-identity correlation or remote database access.
- Full Mix/VM/internal-crash normalization into the four owned exit codes.
- Live TLS refusal/conformance fixtures and end-to-end subprocess proof for exit
  `0`; this change tests constructed TLS policy and exits `1`/`2`/`64` at the
  launcher boundary.
- Pin preflight or cadence enforcement.

## Decisions

### One script module and shell entrypoint

`scripts/support/observability_probe.exs` owns validation, request execution,
classification, reconciliation, and serialization. The shell entrypoint first
compiles with stdout suppressed, then runs with `--no-compile --no-start` so
stdout is reserved for the result once the executable artifact starts. Relative
config paths are made absolute before the launcher enters the repository root.

### Grammar-backed content-free results

Configuration requires `probe_<lowercase UUID>` and distinct environment names.
Results require the same probe grammar and `resp_<lowercase UUID>` public IDs;
a result uses a null probe ID only when no configuration validated, so the
schema, environment, transport, and database refusals that follow a valid
configuration stay correlatable by the pinned ID. Other result strings are
closed enums or validated UTC timestamps, and timestamp validation refuses
non-string values instead of raising. Unknown and content-bearing field names
remain forbidden.

### Trusted credential destination

Plain HTTP is restricted to exact loopback hosts. HTTPS rejects userinfo,
queries, fragments, and malformed raw authorities before URI normalization,
including empty, nonnumeric, whitespace-bearing, or control-bearing explicit
ports and malformed IPv6. It disables redirects and sets explicit peer
verification, hostname verification, SNI, and host system CA certificates. A
host that cannot supply a usable CA store is a pre-request refusal like a
missing environment variable, not an unhandled raise, so transport options are
built before the observation window opens. Model values are bounded UTF-8
without ASCII controls; credentials are bounded printable non-space ASCII. Both
are validated before request construction and are never interpolated into
validation errors.

### Fail-closed buffered terminal classification

The probe intentionally reads the complete buffered response and recognizes the
Controller's narrow single-line SSE framing only after requiring exactly one
`text/event-stream` response media type; media-type parameters are allowed, but
missing, wrong, duplicated, or comma-joined values fail closed. A block becomes
a terminal candidate when either its SSE event or decoded JSON type names a
terminal. A candidate is valid only with exactly one event and data field,
matching types, a response object, a canonical ID, and a producer-legal status.
Completed accepts only `completed`; failed accepts `failed` or `incomplete`.
Any invalid candidate makes the whole observation invalid even beside a valid
candidate. HTTP statuses outside the result schema's `100..599` range classify
as `http_error` while retaining a null `http_status`, so serialization remains
safe.

This establishes semantic terminal evidence only. It does not prove incremental
stream delivery, chunk timing, or progress before connection close.

### Controller-local cross-plane mapping

Reconciliation runs only when an SSE terminal was observed. A transport, HTTP,
or stream failure keeps its own classification, because rewriting it to
`terminal_validation_failed` would report a database mismatch for an outage that
never reached the database. Those classifications already fail, so gating costs
no strictness.

The durable validator requires one terminal `state_transition` matching the
request row. Reconciliation then applies this mapping:

| HTTP terminal | HTTP status | Durable state |
|---|---|---|
| `response.completed` | `completed` | `completed` |
| `response.failed` | `failed` | `failed`, `cancelled`, `timed_out`, `interrupted` |
| `response.failed` | `incomplete` | `cancelled`, `timed_out`, `interrupted` |

A missing canonical ID, missing or duplicate transition, active row, internal
durable mismatch, or cross-plane contradiction fails closed. Active row states
are not copied into the closed result enum. No retry is added because the
buffered controller response completes after terminal persistence ordering.

### Consumer-owned immutable pin

Issue #115 owns the producer artifact and example. Issue #118 records the
producer commit and SHA-256 of exact non-secret config bytes, then owns cadence,
retained results, update, and rollback evidence.

## Failure handling

Exit `0` means a validated pass, `1` a validated failed observation, `2` a
pre-request configuration or environment refusal, and `64` usage. Unexpected
mise, Mix, VM, dependency, or internal failures may return another runtime exit
code and are not claimed as normalized by this change.

## Validation

Controller tests cover identifier grammars, invalid-config serialization,
hostile terminal candidates, response media-type enforcement, cross-plane
mappings, sanitized ordinary Repo query failures, lexical URL-authority and
resolved-value refusal, explicit TLS option construction, existing and
nonexistent caller-relative paths, invalid-config JSON stdout, launcher exits
`2`/`64`, and a subprocess failed observation with exit `1`. They do not claim
live TLS conformance, subprocess proof for exit `0`, or general VM-crash
normalization. Strict OpenSpec and the applicable Elixir workflow run from the
umbrella root.
