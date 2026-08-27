# Models catalog

The Models page lists the full model catalog with lifecycle actions. On a fresh dev database it may show an empty catalog or a loading then empty state.

## Sub-features

- `models-load` — Models page exits loading and shows catalog or explicit empty state.
- `models-shell` — Console shell with Models nav active.

## How to get to it (user POV)

- Click **Models** in the Console sidebar.
- Navigate directly to `/console/models`.

## Driving it with cursor-ide-browser

Preconditions:

- `control-orchard doctor` passes.

- **Open models.** Navigate or click **Models**. URL `/console/models`; heading `Models`.
- **Wait for catalog.** Wait until `#models-catalog-card`, `#models-loading-card`, or `#models-error-card` is present — loading alone is insufficient for final proof.
- **Proof.** Snapshot should include `Model Catalog` title or the explicit unavailable/error message. Save `${ARTIFACTS}/models-catalog/models.aria.txt`, screenshot `${ARTIFACTS}/models-catalog/models.png`, and `proof.txt` noting empty vs populated catalog.

## Gotchas

- Lifecycle action buttons (activate/deprecate/retire/delete) mutate DB state — read-only verification should not click them unless cleanup is planned.
- Imported models from manual dev sessions appear in the shared `orchard_dev` database; empty vs non-empty depends on local DB state, not the proof harness.
