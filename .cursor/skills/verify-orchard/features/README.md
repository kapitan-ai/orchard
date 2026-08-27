# Orchard verification map

This directory is the maintained source for verifying user-facing Orchard operator behavior. Read this index before driving the app, then open the matching feature file.

## Baseline preconditions

- PostgreSQL accepting connections on `${PGHOST:-localhost}:${PGPORT:-5432}` with dev credentials (`PGUSER`/`PGPASSWORD`, default `postgres`/`postgres`).
- Repo dependencies installed (`make setup` once).
- Run `control-orchard bootstrap` before first launch if `tmp/dev/node-trust/current` is missing (repairs orphaned DB trust without local files).
- Launch with `control-orchard launch` and confirm `control-orchard doctor` passes.
- Set a disposable run id: `export ORCHARD_VERIFY_RUN_ID="orchard-$(date +%Y%m%d%H%M%S)-$$"`.
- Put `.cursor/skills/verify-orchard/scripts` on `PATH`.
- Never drive a Console instance that was not started by the current verification run on the recorded port.

## Driving conventions

- Start every recipe from the baseline unless its preconditions say otherwise.
- Prefer sidebar link labels and page headings over CSS selectors or DOM position.
- Console dev auth is `:none` — no Basic Auth prompt locally.
- Run browser actions through **cursor-ide-browser** MCP tools.
- Run HTTP probes through `control-orchard curl` or `curl` against `ORCHARD_VERIFY_BASE_URL`.
- LiveView pages may show a brief loading panel on first connect; wait for the page `<h1>` or a stable content card before proof.
- Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the initial screen.
- UI proof includes an ARIA snapshot and a screenshot with Console sidebar visible.
- HTTP proof includes status code and response body.
- Record the feature ID and entry point in `proof.txt` beside artifacts.
- Report unreachable paths with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing user-visible behavior. It then uses exactly four H2 sections in this order:

1. `Sub-features` — short IDs with one line each.
2. `How to get to it (user POV)` — every user entry point.
3. `Driving it with cursor-ide-browser` — starts with `Preconditions:` and pairs actions with observable results.
4. `Gotchas` — traps that invalidate a run.

## Features

- [Console overview](./overview.md) — landing page readiness, quickstart shell, sidebar chrome.
- [Console navigation](./console-navigation.md) — sidebar routes to major Console pages.
- [Public health probes](./health-probes.md) — `/health/live` and `/health/ready` without auth.
- [Models catalog](./models-catalog.md) — Models page catalog or explicit empty/error state.
- [Settings page](./settings.md) — inference defaults and debug snapshot panel load.

## Optional (heavy setup)

- Playground chat and `/v1/chat/completions` require an imported model, tenant grants, and API token per `docs/local-dev.md`. Add a feature file when those steps are scripted for verification.
