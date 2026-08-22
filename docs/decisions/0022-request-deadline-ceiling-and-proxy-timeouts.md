# ADR: Bound effective request deadlines and require proxy agreement

## Status

Accepted.

## Context

Public request deadlines include generation time and, for `allow_cold_load`,
the configured queue-wait and cold-start budgets. Without a deployment-owned
ceiling, a routing policy can create an arbitrarily long client-facing
deadline. Reverse proxies can also terminate an otherwise valid cold request
before the controller deadline, especially before an SSE stream emits its
first byte.

## Decision

The Controller reads `ORCHARD_MAX_REQUEST_DEADLINE_MS` as the deployment-owned
ceiling for the complete effective request deadline. Its provisional default is
360000 ms pending Apple Silicon cold-load measurements tracked by issue #255.

Routing policies are rejected when their effective deadline exceeds the
ceiling. `allow_cold_load` includes generation, queue-wait, and cold-start
budgets; `prefer_loaded` and `required_loaded` include only the generation
budget. If a saved policy exceeds a newly lowered ceiling, request resolution
caps the deadline and emits a warning containing the policy-derived and capped
values. A configured generation timeout above the ceiling is invalid and
raises a clear configuration error.

Deployment documentation configures nginx, Caddy, and Traefik response
timeouts above the ceiling. Orchard does not add a pre-first-token SSE
heartbeat in this change; heartbeat behavior is deferred until issue #255
provides real cold-load measurements or a separate decision is accepted.

## Consequences

Operators cannot save policies that promise more time than the deployment can
honor. Lowering the ceiling remains safe for already-saved policies, but emits
an operational warning when a request is capped. Proxy configuration must be
updated whenever the ceiling changes.

## SPEC.md impact

No change required. This decision bounds the existing request-deadline
precedence without changing the canonical admission fields or stage semantics
in `SPEC.md` §3.4 and §5.8.
