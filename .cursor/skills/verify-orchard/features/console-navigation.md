# Console navigation

Operators move between Console areas using the left sidebar. Each enabled item navigates to a distinct LiveView route under `/console`.

## Sub-features

- `nav-nodes` — Nodes page loads.
- `nav-models` — Models page loads.
- `nav-settings` — Settings page loads.

## How to get to it (user POV)

- From any Console page, click a sidebar label: **Nodes**, **Models**, **Settings**, etc.

## Driving it with cursor-ide-browser

Preconditions:

- `control-orchard doctor` passes.
- Browser is on any Console page (start at `/console` if needed).

- **Nodes.** Click link `Nodes`. Heading becomes `Nodes`; URL path is `/console/nodes`. Inner inventory may still hydrate; heading + `aria-current="page"` is enough for this sub-feature.
- **Models.** Click link `Models`. Heading becomes `Models`; URL path is `/console/models`. Do **not** stop at the loading panel titled **Model Catalog**. Wait until `#models-catalog-card` or `#models-error-card` (`Models unavailable`).
- **Settings.** Click link `Settings`. Heading becomes `Settings`; URL path is `/console/settings`. Wait until inference-defaults **Default model** options or `#settings-inference-defaults-error` appear — the Appearance card and empty form are already on the disconnected shell.
- **Proof.** After each navigation, capture snapshot lines showing the new heading and `aria-current="page"` on the clicked nav item. Save combined snapshot to `${ARTIFACTS}/console-navigation/nav.aria.txt` and screenshot to `${ARTIFACTS}/console-navigation/nav.png`. Record visited paths in `proof.txt`.

## Gotchas

- All eight sidebar items are enabled (Overview, Nodes, Playground, Models, Model Hub, Organizations, Requests, Settings); none should show `aria-disabled="true"`. This feature only proves Nodes, Models, and Settings.
- Direct URLs under `/console/...` are valid page proofs but do not replace the click path for this feature.
- Settings **Advanced** / **Runtime / config snapshot** starts collapsed; expanding it is optional for nav proof.
