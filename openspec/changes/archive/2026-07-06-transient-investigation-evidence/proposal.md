## Why

Orchard treats investigation notes, smoke evidence documents, and slice plans as transient execution artifacts, but the accepted `runtime-endpoints` spec required smoke evidence to live in a standalone repo document under `docs/investigations/`.
That requirement caused transient, machine-adjacent evidence notes to be committed as if they were durable product documentation, drifting against the source-of-truth rules in `AGENTS.md` and `docs/process.md`.

## What Changes

- Amend the `Source-dev BEAM Smoke Evidence Gate` requirement so evidence is recorded durably in the accepting change package, decision record, or promotion pull request instead of a standalone repo evidence document.
- Promote the accepted 2026-06-27 two-Mac smoke evidence summary into `docs/decisions/0001-runtime-endpoints-beam-first.md` so the gate record stays durable without the standalone note.
- Update `docs/local-dev.md` smoke guidance to match.
- Record the general policy in `AGENTS.md` and the `docs/process.md` artifact lifecycle table: investigation notes are transient, durable conclusions get promoted, execution evidence lives on the PR or issue.
- Delete `docs/investigations/` (the superseded Admin API slice plan and the 2026-06-27 smoke note, whose durable content is promoted).

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `runtime-endpoints`: the smoke evidence gate keeps its evidence content, sanitization, and gating requirements, but changes where the evidence is durably recorded.
