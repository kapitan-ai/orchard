---
name: orchard-console-e2e
description: How to run end-to-end Console + MLX inference smoke tests against a running source-dev Orchard stack on macOS, including headless-Chrome UI driving when GUI/computer-use input is unavailable.
---

# Orchard Console E2E smoke testing

## Reaching the app
- Source dev serves HTTP on `:4000`. The Console is at `http://localhost:4000/console`
  (`auth: :none` in dev, so no login). `/` is a 404 by design.
- `/health/ready` can return 503 while node trust/admission is uninitialized; that alone is
  not a Console bug. `/metrics` requires an API key.
- Console routes (see `apps/orchard_controller/lib/orchard/api/router.ex`, `scope "/console"`):
  `/`, `/nodes`, `/nodes/:node_id`, `/playground`, `/models`, `/model-hub`, `/settings`,
  `/requests`, `/requests/:public_id`, `/tenants`, `/tenants/:id`.
- Do not run `make dev` if a split-role topology (`bin/dev-controller` + `bin/dev-node-agent`)
  is already running, and never kill packaged Orchard BEAMs under
  `/Library/Application Support/Orchard/`.

## Model identity gotcha
API calls must use the full identity `"<model_id>@<version_sha>"`. The bare id resolves to
`@default` and 404s. `GET /v1/models` with a tenant token returns exactly the granted
identities, which is the quickest way to get the correct string.

## Playground readiness (most common source of false failures)
`Orchard.Console.Playground` refuses to stream unless the selected model reports
`inference_ready: true`, which requires a **loaded placement** (see `console/playground.ex`
`ensure_model_inference_ready/1`). Catalog `active` is NOT enough, and the Console has no
load/warm action (Models only offers Activate/Deprecate/Retire). Placements lapse back to
`none` after a few idle minutes.

Workaround before every Playground test: send one `POST /v1/chat/completions` with a tenant
token to warm the placement, then load `/console/playground`. Expected badges when warm:
`Catalog: active | Remote: present | Placement: loaded | Loaded: yes | Ready: yes` plus
"Loaded placement confirmed. Send is enabled for this model."

Note the Playground runs as the seeded `legacy` organization, so the model must be granted to
`legacy` (not just your dev tenant) for it to appear in the model select.

## Useful Console element ids
`#playground-model` (a real `<select>`; option value is the full identity),
`#playground-model-readiness`, `#playground-prompt`, `#playground-send`,
`#playground-transcript` (contains the literal text `STREAMING` while a run is in flight),
`#playground-result-rail`, `#playground-result-request-id`, `#playground-error`,
`#models-catalog`, `#tenant-api-keys-table`.

## When GUI/computer-use input is unavailable
On locked-down macOS boxes computer-use can fail with
`enigo init failed: the application does not have the permission to simulate input`
(Accessibility permission is user-side; the lead's tool fails the same way). Fall back to
headless Chrome scripting instead of giving up:

```bash
mkdir -p /Volumes/devbox/workspace/uitest && cd /Volumes/devbox/workspace/uitest
npm init -y && npm install puppeteer-core@23   # keep it OUT of the repo checkout
```

```js
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true, args: ['--no-sandbox'],
  defaultViewport: { width: 1440, height: 1000 },
});
```

- `page.screencast({ path: 'run.webm' })` gives motion evidence if `ffmpeg` is on PATH
  (`brew install ffmpeg`); mux to mp4 with
  `ffmpeg -i run.webm -c:v libx264 -pix_fmt yuv420p out.mp4`.
- To prove streaming is token-by-token, poll `#playground-transcript` innerText every ~120 ms
  and record `(elapsed_ms, text_length)` samples plus several mid-stream screenshots. Do NOT
  exit the poll loop as soon as `#playground-result-request-id` appears — the result rail can
  render before the transcript repaints, which makes the final capture look like
  "Waiting for response…". Wait until the transcript no longer contains `STREAMING` and its
  length has been stable for >1s.
- Screenshots taken headlessly cannot be eyeballed by the agent; sanity-check they are not
  blank with a pixel-statistics pass, e.g.
  `ffmpeg -v error -i shot.png -f rawvideo -pix_fmt gray - | node stats.mjs` (mean/std), and
  state clearly in the report which assertions were DOM-text-based.

## Governance surface expectations
- `/console/tenants` lists organizations; `/console/tenants/:id` shows API tokens as
  name/prefix (`orchard_kp_...`)/created/last-used/status only. A full `orchard_sk_...`
  secret should appear only in the one-time creation card.
- There is currently **no per-tenant model-access-grant surface** in the Console. Verify grants
  indirectly: `GET /v1/models` with the tenant token, and the Playground model list for `legacy`.

## Devin Secrets Needed
None for local dev. Mint a tenant token locally in the controller IEx session with
`OrchardCLI.main(["api-keys", "create", "--tenant-id", "<id>", "--name", "dev"], fn _ -> :ok end)`
(the 1-arity form halts the VM) and grant the model to that tenant and to `legacy`. The token is
a local dev credential; keep it out of screenshots and evidence where practical.
