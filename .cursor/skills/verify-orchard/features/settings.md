# Settings page

Settings exposes Console appearance notes, inference defaults, and an advanced debug snapshot for operators.

## Sub-features

- `settings-load` — Settings page renders with heading and the Appearance, Inference Defaults, and Advanced cards.
- `settings-connected` — connected mount completes (defaults loaded or explicit error; debug snapshot leaves Loading).

## How to get to it (user POV)

- Click **Settings** in the Console sidebar.
- Navigate directly to `/console/settings`.

## Driving it with cursor-ide-browser

Preconditions:

- `control-orchard doctor` passes.

- **Open settings.** Navigate to `/console/settings` or click **Settings**. Heading `Settings`; nav item Settings has `aria-current="page"`.
- **Wait for connected data.** The Inference Defaults form (`#settings-inference-defaults-form`) is already on the disconnected shell — form fields alone are not proof. Wait until **Default model** has real options (or **No default model** plus loaded options) **or** `#settings-inference-defaults-error` / `#settings-default-models-error` appears. The Advanced **Runtime / config snapshot** disclosure starts collapsed; inner Worker state is optional after expand.
- **Proof.** Snapshot includes `Settings` heading, **Appearance**, **Inference Defaults** labels, and **Advanced**. Save `${ARTIFACTS}/settings/settings.aria.txt`, screenshot `${ARTIFACTS}/settings/settings.png`, and `proof.txt`.

## Gotchas

- Saving inference defaults mutates DB — read-only verification must not submit **Save defaults** unless rollback is planned.
- **Refresh now** on the debug snapshot is read-only but async; do not require a second refresh for proof.
- Expanding **Runtime / config snapshot** is optional; a11y snapshots often hide closed `<details>` content.
