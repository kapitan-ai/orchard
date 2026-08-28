# Public health probes

Orchard exposes unauthenticated liveness and readiness HTTP probes used by operators and load balancers. Public bodies are status-only JSON.

## Sub-features

- `health-live` — `/health/live` returns the public liveness JSON.
- `health-ready` — `/health/ready` returns public readiness status (`ok` or `error`).

## How to get to it (user POV)

- HTTP GET `http://127.0.0.1:4000/health/live`
- HTTP GET `http://127.0.0.1:4000/health/ready`

## Driving it with control-orchard

Preconditions:

- `control-orchard doctor` passes (includes live probe).

- **Live probe.** Run `control-orchard curl /health/live`. Exit code 0; body exactly `{"status":"ok"}`.
- **Ready probe.** Run `curl -sS -D - -o body.json "${BASE_URL}/health/ready"` (or `control-orchard curl /health/ready` for the body). Capture HTTP status + body under `${ARTIFACTS}/health-probes/`. Expect HTTP **200** `{"status":"ok"}` or HTTP **503** `{"status":"error"}` — no extra keys.
- **Proof.** Write `proof.txt` listing both URLs, status codes, and bodies. Live must match spec. Ready documents actual state; source-dev `plain_http_localhost` commonly stays 503 even after Postgres is up.

## Gotchas

- `/health/live` only asserts the HTTP stack is up. `/health/ready` uses the staged M0 predicate (Postgres reachable, migrations current, public API HTTPS enabled, a constant boot flag) but **strips** checks from the public body.
- Source-dev defaults to plain HTTP localhost, so ready is often 503 `{"status":"error"}` for the HTTPS check — that is expected, not a launch failure.
- Authenticated operator diagnostics live at `GET /ops/v1/health` (Bearer operator/admin token). Do not fold that into this public feature.
- These endpoints are public; do not attach API tokens in URLs or commit probe secrets.
