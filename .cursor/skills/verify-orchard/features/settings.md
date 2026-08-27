# Settings page

Settings exposes Console inference defaults and an advanced debug snapshot for operators.

## Sub-features

- `settings-load` — Settings page renders with heading and form regions.
- `settings-connected` — connected mount completes (defaults or explicit error state).

## How to get to it (user POV)

- Click **Settings** in the Console sidebar.
- Navigate directly to `/console/settings`.

## Driving it with cursor-ide-browser

Preconditions:

- `control-orchard doctor` passes.

- **Open settings.** Navigate to `/console/settings` or click **Settings**. Heading `Settings`; nav item Settings has `aria-current="page"`.
- **Wait for connected data.** Page may fetch inference defaults and debug snapshot after connect — wait until form fields or an explicit error/unavailable message appears (not merely the static shell).
- **Proof.** Snapshot includes `Settings` heading and inference defaults section labels. Save `${ARTIFACTS}/settings/settings.aria.txt`, screenshot `${ARTIFACTS}/settings/settings.png`, and `proof.txt`.

## Gotchas

- Saving inference defaults mutates DB — read-only verification must not submit the form unless rollback is planned.
- Debug snapshot refresh is async; a single snapshot after a short wait is enough for proof.
