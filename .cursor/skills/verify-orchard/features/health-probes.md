# Public health probes

Orchard exposes unauthenticated liveness and readiness HTTP probes used by operators and load balancers.

## Sub-features

- `health-live` — `/health/live` returns the public liveness JSON.
- `health-ready` — `/health/ready` returns readiness status (success or structured not-ready).

## How to get to it (user POV)

- HTTP GET `http://127.0.0.1:4000/health/live`
- HTTP GET `http://127.0.0.1:4000/health/ready`

## Driving it with control-orchard

Preconditions:

- `control-orchard doctor` passes (includes live probe).

- **Live probe.** Run `control-orchard curl /health/live`. Exit code 0; body exactly `{"status":"ok"}`.
- **Ready probe.** Run `control-orchard curl /health/ready` and capture HTTP status + body (e.g. `curl -sS -D - -o body.json "${BASE_URL}/health/ready"`). Save headers/body under `${ARTIFACTS}/health-probes/`.
- **Proof.** Write `proof.txt` listing both URLs, status codes, and bodies. Live must match spec; ready documents actual state without treating warm-up degradation as launch failure.

## Gotchas

- `/health/live` only asserts the HTTP stack is up; `/health/ready` checks Postgres, migrations, and controller readiness.
- Ready may fail briefly while migrations or runtime subsystems initialize — retry with backoff before failing the feature.
- These endpoints are public; do not attach API tokens in URLs or commit probe secrets.
