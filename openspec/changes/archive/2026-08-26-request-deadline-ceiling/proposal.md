# Bound effective request deadlines and align deployment proxies

## Why

The Controller derives cold-path request deadlines from generation, queue-wait,
and cold-start budgets. Without a deployment-owned ceiling, routing policy can
mint an arbitrarily long public deadline, while a reverse proxy may terminate
the response first.

## What changes

- Add `ORCHARD_MAX_REQUEST_DEADLINE_MS` with a provisional 360000 ms default.
- Reject routing policies whose effective deadline exceeds the deployment
  ceiling, using residency-specific admission semantics.
- Fail closed when the configured generation timeout exceeds the ceiling.
- Cap stale over-ceiling resolved deadlines at request time with warning
  observability.
- Document compatible nginx, Caddy, and Traefik timeouts.
- Record the decision to defer a pre-first-token SSE heartbeat.

## Out of scope

- Changing queue or cold-start policy fields individually.
- Adding a new public API error field.
- Implementing an SSE heartbeat before the first token.
- Tuning the provisional ceiling before Apple Silicon measurements.
