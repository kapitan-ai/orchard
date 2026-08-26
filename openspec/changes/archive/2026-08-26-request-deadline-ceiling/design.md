# Design: deployment request-deadline ceiling

## Shared calculation

`Orchard.Inference.AdmissionPolicy` remains the authority for effective
deadlines. `allow_cold_load` uses generation plus queue wait plus cold start;
the loaded-only preferences use generation alone. Routing-policy validation
calls the same calculation so save-time policy checks cannot drift from
request resolution.

## Configuration and compatibility

The ceiling is read from controller inference configuration. The accessor
raises when the ceiling is missing or non-positive, or when configured
`request_timeout_ms` exceeds it. The six-minute production default is
provisional until Apple Silicon cold-load measurements are available.

## Lowered-ceiling behavior

Request resolution caps an effective deadline that exceeds the current
ceiling. The durable canonical request and `timeout_at` therefore receive the
capped value. No new public response field is introduced; warning logging is
the existing observable seam because no durable field naturally represents a
deployment-time correction.

## Proxy and SSE behavior

The packaged proxy examples use 390-second response/read/write timeouts,
exceeding the 360000 ms default. A pre-first-token SSE heartbeat is deferred;
the deployment contract instead requires proxy timeouts to exceed the ceiling.
