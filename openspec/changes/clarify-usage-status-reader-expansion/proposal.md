# Clarify usage-status reader expansion

## Why

Issue #329's reader-only expansion must preserve unclassified usage without making row-age claims or scanning retained Requests under an exclusive DDL lock. The owner has approved NULL as classification not recorded, not evidence of row age or deployment cutover.

## What changes

- Clarify `SPEC.md` §8.2's NULL semantics without backfilling or inferring usage completeness.
- Add the status CHECK without initial validation and validate it in a later migration transaction, after the expansion transaction commits.
- Keep current writers and Completed-only accounting unchanged. Require compatible readers before future #329 classified writers activate; merged #418 supplies Worker usage updates, not those writers.

## Capabilities

### Modified capabilities

- `automatic-attempt-retry`: Specify the compatible usage-evidence expansion and its deployment boundary.

## SPEC.md impact

Clarifies §8.2's approved unclassified NULL meaning and applies §13.2's expand/migrate/contract strategy. This does not relax §3.7.1's eventual terminal-evidence obligations or complete issue #329.

## Out of scope

Status writers, lower-bound accounting, public serialization, UI changes, historical backfill, shared migrations, and deployment lock/retry configuration remain outside this change.
