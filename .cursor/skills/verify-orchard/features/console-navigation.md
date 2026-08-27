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

- **Nodes.** Click link `Nodes`. Run `browser_click` on the `Nodes` link from snapshot ref. Heading becomes `Nodes`; URL path is `/console/nodes`.
- **Models.** Click link `Models`. Heading becomes `Models`; URL path is `/console/models`.
- **Settings.** Click link `Settings`. Heading becomes `Settings`; URL path is `/console/settings`.
- **Proof.** After each navigation, capture snapshot lines showing the new heading and `aria-current="page"` on the clicked nav item. Save combined snapshot to `${ARTIFACTS}/console-navigation/nav.aria.txt` and screenshot to `${ARTIFACTS}/console-navigation/nav.png`. Record visited paths in `proof.txt`.

## Gotchas

- All sidebar items are enabled in dev; none should show `aria-disabled="true"`.
- Wide pages (Models) may take a moment to exit the loading panel — wait for `Model Catalog` title or an explicit error card.
- Settings triggers connected fetches; wait past the initial shell before proof.
