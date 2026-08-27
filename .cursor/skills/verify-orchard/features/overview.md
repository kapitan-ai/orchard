# Console overview

The Console overview is the operator landing page at `/console`. It shows system readiness, runtime snapshot cards, request counts, and the model catalog summary once LiveView connects.

## Sub-features

- `overview-load` — page renders with Console shell and Overview heading.
- `overview-nav-active` — sidebar marks Overview as the current page.
- `overview-readiness` — readiness section renders (pass or fail states are both valid proof).

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
- **Wait for content.** If a loading panel appears (`Loading` / quickstart hydrating), wait and snapshot again until readiness cards, quickstart, or explicit empty/runtime states render.
- **Proof.** Run `browser_snapshot` → save to `${ARTIFACTS}/overview/overview.aria.txt`. Run `browser_take_screenshot` → save to `${ARTIFACTS}/overview/overview.png`. Write `${ARTIFACTS}/overview/proof.txt` with feature id `overview`, entry `GET /console`, and timestamp.

## Gotchas

- Disconnected first render shows loading copy only; do not screenshot until connected content appears.
- Runtime cards may show unavailable/degraded states on a fresh dev boot without an imported model — that is still valid proof if the page heading and nav are correct.
- Do not use packaged BEAM on port 4000; verification expects source-dev from `control-orchard launch`.
