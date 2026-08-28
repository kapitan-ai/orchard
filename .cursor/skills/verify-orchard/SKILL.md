---
name: verify-orchard
description: Drive Orchard source-dev locally — Console LiveView, public health probes, and optional /v1 API checks. Use when proving UI, readiness, or operator-console behavior after a change.
---

# verify-orchard

Orchard is an Elixir/OTP inference platform. The primary user-facing surface for operators is the **Console** (Phoenix LiveView at `/console`). Secondary surfaces: public health endpoints (`/health/live`, `/health/ready`), authenticated ops health (`/ops/v1/health`), and the OpenAI-compatible `/v1/*` API.

This skill launches **source-dev** (`mise exec -- bin/dev`), drives the Console with the **cursor-ide-browser** MCP tools, and captures proof artifacts under a disposable run directory.

## Launch

From the repo root:

```bash
chmod +x .cursor/skills/verify-orchard/scripts/control-orchard.sh
export ORCHARD_VERIFY_RUN_ID="orchard-$(date +%Y%m%d%H%M%S)-$$"
export PATH="$PWD/.cursor/skills/verify-orchard/scripts:$PATH"
control-orchard bootstrap   # creates missing node-trust; wipe/re-init only with ORCHARD_VERIFY_TRUST_RECOVER=1
control-orchard launch
control-orchard meta
```

**Ready when:** `GET http://127.0.0.1:${ORCHARD_VERIFY_PORT:-4000}/health/live` returns exactly `{"status":"ok"}`.

`launch` detaches the BEAM into a new session so the helper can return without SIGHUP-killing the server. `stop` still targets only the recorded PID.

Verification launch sets `ORCHARD_VERIFY_MODE=1`, which disables Phoenix code reload and asset watchers in `config/dev.exs` so health probes stay stable. It runs `mix assets.build` before boot. Launch checks the HTTP port is free before bootstrap, so an existing `make dev` is not disrupted by trust recovery.

**Defaults:**
- HTTP port `4000` (`ORCHARD_VERIFY_PORT` to override)
- Shared dev database `orchard_dev` (same as `make dev`)
- Console auth `:none` in `config/dev.exs` (no Basic Auth locally)
- gRPC node-agent port `50071`

**Isolation rules:**
- Do **not** launch if the user already has `make dev` on the same port — `control-orchard launch` refuses occupied ports.
- Do **not** run two verification launches with the same `ORCHARD_VERIFY_STATE_DIR`.
- Prefer a fresh `ORCHARD_VERIFY_RUN_ID` per proof run.
- Inference/API proofs that mutate tenants or models share the dev DB; restore or use disposable slugs when mutating.

**Teardown:**

```bash
control-orchard stop
```

Only stops the PID recorded by `launch`. Never `pkill mix` or `pkill beam`.

## Doctor

Run before every drive when anything looks off:

```bash
control-orchard doctor
```

Pass criteria:
1. PID file exists and process is alive
2. Port listener matches that PID
3. `/health/live` body is `{"status":"ok"}`
4. `/console` returns HTTP 200 and HTML containing `Orchard Console`

`/health/ready` may be HTTP 503 with exactly `{"status":"error"}` on source-dev (`plain_http_localhost` fails the public HTTPS check). Log it; do not treat it alone as launch failure.

## Drive

**Harness:** `cursor-ide-browser` MCP (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_take_screenshot`). If that MCP is unavailable mid-run, the same URLs, sidebar labels, and wait conditions can be driven with another Chromium CDP session (for example `agent-browser open|snapshot|click|screenshot`) against `ORCHARD_VERIFY_BASE_URL`.

**Conventions:**
1. Run `control-orchard doctor` first.
2. Read `.cursor/skills/verify-orchard/features/README.md`, then the feature file for the scenario.
3. Prefer stable handles: sidebar link text (`Overview`, `Nodes`, …), page `<h1>` titles, `aria-label="Console navigation"`, element IDs such as `#console-sidebar` and `#console-app`.
4. After navigation, wait for LiveView connected render (page heading visible; loading panels replaced by content or explicit empty states).
5. HTTP-only probes use `control-orchard curl /health/live` or plain `curl` against `ORCHARD_VERIFY_BASE_URL` from `control-orchard meta`.

**Console entry URL:** `{ORCHARD_VERIFY_BASE_URL}/console` (dev: `http://127.0.0.1:4000/console`).

**Browser workflow example (Overview):**

```
browser_navigate → http://127.0.0.1:4000/console
browser_snapshot → confirm heading "Overview" and nav link "Overview" has aria-current
browser_take_screenshot → save to artifacts path
```

Sidebar routes (all under `/console`):

| Label | Path |
|-------|------|
| Overview | `/console` |
| Nodes | `/console/nodes` |
| Playground | `/console/playground` |
| Models | `/console/models` |
| Model Hub | `/console/model-hub` |
| Organizations | `/console/tenants` |
| Requests | `/console/requests` |
| Settings | `/console/settings` |

## Evidence

Artifacts live under `${ORCHARD_VERIFY_STATE_DIR}/artifacts/` (created by the agent; survives `control-orchard stop`).

**Proof standards:**
- Exercise the real operator path (Console navigation, public health URLs) — not test-only plugs or direct Repo calls.
- Capture **action + resulting state** (snapshot after navigation, not only the initial screen).
- For HTTP probes, save status code and body.
- For UI proofs, save an ARIA snapshot **and** a screenshot showing the Console chrome (sidebar + page title).
- Record feature id and entry point in a one-line `proof.txt` beside artifacts.

Example layout:

```
${ORCHARD_VERIFY_STATE_DIR}/artifacts/overview/
  proof.txt
  overview.aria.txt
  overview.png
```

**API / inference proofs** (optional, heavier setup):
- Prepare a local Orchard bundle with `scripts/prepare-mlx-smoke-bundle.sh` and export `ORCHARD_MLX_SMOKE_MODEL_PATH` from `--print-path`. That helper is not a CI gate.
- Import/activate a model and grant tenant access per `docs/local-dev.md` before Playground or `/v1/chat/completions` checks.
- Never commit API tokens; pass via env (`ORCHARD_API_KEY`) only for the run.

## Cleanup

```bash
control-orchard stop
```

Removes the verification BEAM process only. Keeps `${ORCHARD_VERIFY_STATE_DIR}/artifacts/` intact.

If launch failed mid-boot, still run `control-orchard stop` to clear a partial PID file.

## Helpers

| Command | Purpose |
|---------|---------|
| `control-orchard bootstrap` | Ensure `tmp/dev/node-trust` exists; opt-in orphan recover via `ORCHARD_VERIFY_TRUST_RECOVER=1` |
| `control-orchard launch` | Detach source-dev (new session) with log + pid files |
| `control-orchard doctor` | Readiness gate before driving |
| `control-orchard stop` | Stop the launched instance |
| `control-orchard meta` | Print `BASE_URL`, pid, log, artifacts paths |
| `control-orchard curl /health/live` | HTTP GET against verification base URL |

Script path: `.cursor/skills/verify-orchard/scripts/control-orchard.sh`

## Maintenance

When routes, nav labels, health contracts, or dev startup change, update the feature map and re-run one proof. Use `/maintain-verification-skill` for the maintenance workflow.
