# Console overview

The Console overview is the operator landing page at `/console`. After LiveView connects it shows Quickstart, System Status, readiness checks, a runtime snapshot, request counts, and a model catalog summary.

## Sub-features

- `overview-load` — page renders with Console shell and Overview heading.
- `overview-nav-active` — sidebar marks Overview as the current page.
- `overview-readiness` — readiness section renders (OK, Blocked, Unknown, or unavailable are all valid proof).

## How to get to it (user POV)

- Open `http://127.0.0.1:4000/console` in a browser (or the verification port from `control-orchard meta`).
- Click **Overview** in the sidebar when another Console page is active.

## Driving it with cursor-ide-browser

Preconditions:

- `control-orchard doctor` passes.
- No other verification run owns the same port.

- **Open overview.** Navigate to `{BASE_URL}/console`. Run `browser_navigate` with the verification base URL + `/console`. The document title or main heading includes `Overview`.
- **Confirm shell.** Run `browser_snapshot`. Snapshot includes `aria-label="Console navigation"`, link name `Overview`, and `#console-sidebar`.
- **Confirm active nav.** Snapshot shows the Overview link with `aria-current="page"`.
- **Wait for connected data.** The first paint is already a full dashboard (Quickstart hydrating, System Status with `—` metrics, Readiness rows, compact in-card loaders). Do not treat that as done. Wait until **Last updated** replaces **Waiting for first live update** / **Connecting to live controller…**, and Runtime Snapshot is no longer **Loading runtime snapshot.** (a table, **No loaded models.**, or **Runtime unavailable.** are all success).
- **Proof.** Run `browser_snapshot` → save to `${ARTIFACTS}/overview/overview.aria.txt`. Run `browser_take_screenshot` → save to `${ARTIFACTS}/overview/overview.png`. Write `${ARTIFACTS}/overview/proof.txt` with feature id `overview`, entry `GET /console`, and timestamp.

## Gotchas

- Disconnected HTTP GET already includes the Overview `h1`, sidebar, and `#overview-readiness`. Waiting only for those can snapshot pre-connect placeholders.
- Quickstart may stay on **Loading your quickstart state…** until the `OverviewQuickstart` JS hook runs; connected proof is **Last updated** plus a settled Runtime Snapshot, not the checklist alone.
- Runtime cards may show unavailable/degraded states on source-dev (for example **Degraded** with 3/4 checks when public HTTPS is off) — that is still valid proof if the heading and nav are correct.
- Do not use packaged BEAM on port 4000; verification expects source-dev from `control-orchard launch`.
