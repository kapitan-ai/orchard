# Models catalog

The Models page lists the full model catalog with lifecycle actions. On a fresh dev database it may show an empty catalog or a loading then empty state.

## Sub-features

- `models-load` — Models page exits loading and shows catalog or explicit empty/error state.
- `models-shell` — Console shell with Models nav active.

## How to get to it (user POV)

- Click **Models** in the Console sidebar.
- Navigate directly to `/console/models`.

## Driving it with cursor-ide-browser

Preconditions:

- `control-orchard doctor` passes.

- **Open models.** Navigate or click **Models**. URL `/console/models`; heading `Models`.
- **Wait for catalog.** Ignore `#models-loading-card` (its title is also **Model Catalog**). Final proof requires `#models-catalog-card` or `#models-error-card`.
- **Proof.** Catalog: `h3` **Model Catalog** plus either table rows or `#models-empty-state` (`No models imported yet.`). Error: **Models unavailable**. Save `${ARTIFACTS}/models-catalog/models.aria.txt`, screenshot `${ARTIFACTS}/models-catalog/models.png`, and `proof.txt` noting empty vs populated catalog.

## Gotchas

- Loading and success both say **Model Catalog**; that string alone is not settled-catalog proof.
- Overview also has a **Model Catalog** card — require `/console/models` plus `#models-catalog-card` or `#models-error-card`.
- Lifecycle action buttons (activate/deprecate/retire/delete) mutate DB state — read-only verification should not click them unless cleanup is planned.
- Imported models from manual dev sessions appear in the shared `orchard_dev` database; empty vs non-empty depends on local DB state, not the proof harness.
