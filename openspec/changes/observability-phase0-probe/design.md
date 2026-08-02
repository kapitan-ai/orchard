## Context

The Phase 0 artifact is an acceptance probe consumed by issue #118 CP1. It must
work from a remote pilot host while allowing a stronger check when executed on
a Controller host with database access. The public endpoint already emits
typed Responses SSE terminals, and `Orchard.Requests` already exposes lookup by
public request ID and ordered lifecycle events.

## Goals / Non-Goals

**Goals:**

- Freeze configuration and result schema version 1.
- Exercise streaming `POST /v1/responses` with model and bearer credential
  resolved only from named environment variables.
- Emit one allowlisted JSON result suitable for pilot evidence.
- Optionally verify one durable terminal lifecycle transition matching the
  persisted request state.
- Give issue #118 an immutable SHA-and-digest pin contract.

**Non-Goals:**

- Metrics, tracing, log export, Collector, Prometheus, Grafana, or issue #123.
- Health endpoint or health response changes.
- Remote database access or a new terminal-inspection HTTP API.
- Capturing model output or request input as evidence.

## Decisions

### One module-only script plus a shell entrypoint

`scripts/support/observability_probe.exs` owns validation, request execution,
classification, and serialization. The shell entrypoint runs it with the
pinned repo toolchain and `--no-start`, so HTTP-only mode does not boot Orchard.
Controller-local mode starts only the configured Repo dependency needed for
the durable lookup.

### Strict versioned JSON boundaries

Configuration version 1 accepts exactly the documented fields. Endpoint kind
is `responses`, URL path is `/v1/responses`, and `stream` is `true`. Model and
credential values are read from the environment variable names in the config;
the values never enter the config or result.

Result version 1 accepts exactly `schema_version`, `probe_id`, timestamps,
`outcome`, `classification`, `public_request_id`, `terminal_count`,
`terminal_state`, `http_status`, and `latency_ms`. Every value is scalar or
null. Serialization refuses unknown fields and explicitly refuses secret or
content-bearing field names.

### Dual validation mode

`http_only` validates that an HTTP 200 SSE response contains exactly one typed
`response.completed` or `response.failed` event. This mode is portable to a
remote Linux or macOS probe host.

`controller_local` performs the same HTTP/SSE validation, then calls
`Orchard.Requests.get_request_by_public_id/1` and
`Orchard.Requests.list_request_events/1`. It requires exactly one
`state_transition` whose state is terminal and matches `request.state`.
In local mode `terminal_count` and `terminal_state` report the durable check;
in HTTP-only mode they report the typed SSE terminal observation.

### Consumer-owned immutable pin

Issue #115 owns the producer artifact and example. Issue #118 copies a
non-secret configuration and records the producer commit SHA plus SHA-256 of
the exact config bytes. Update replaces both values after review and a fresh
probe. Rollback restores the prior commit and byte-identical config, verifies
the digest, and collects a fresh result.

## Failure handling

Non-200 responses, transport failures, invalid or ambiguous streams, typed
failure terminals, and durable validation failures produce stable failed
classifications without response bodies or exception detail. Invalid
configuration exits separately and still emits only the safe result schema.

## Validation

Controller tests cover exact config/result schemas, forbidden field refusal,
stream classifications, and durable terminal validation against persisted
request fixtures. The OpenSpec change validates strictly. The full applicable
Elixir workflow runs from the umbrella root.
