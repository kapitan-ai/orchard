# Usage-status expansion boundaries

## Settled semantics

NULL records absence of output-usage classification. Historical rows, bridge-era rows, in-flight Requests, and older writers can all produce it. NULL cannot establish row age or cutover. Counts, lifecycle state, timestamps, and deployment versions cannot turn absent classification into exact or lower-bound evidence. This is the owner-approved clarification of `SPEC.md` §8.2, not permission for future classified terminal writers to omit §3.7.1 evidence.

## Migration transactions

The nullable/no-default addition avoids a rewrite. An immediately validated CHECK would still scan retained Requests under ACCESS EXCLUSIVE. Create it with `validate: false`; PostgreSQL enforces subsequent inserts and updates without scanning old rows. A separate migration validates historical rows under SHARE UPDATE EXCLUSIVE. Ecto's default transaction per migration provides the commit boundary needed to release the original exclusive lock.

Validation still consumes scan I/O and conflicts with some maintenance/DDL. Initial lock acquisition can still wait. This change does not introduce a configurable lock/retry policy or claim bounded production duration.

Rejected alternatives: same-transaction validation or `flush` retains the exclusive lock; removing the CHECK weakens the vocabulary; disabling DDL transactions unnecessarily permits partial expansion. No backfill is necessary because historical NULL values satisfy the CHECK. If validation fails, the committed expansion continues enforcing new writes and the validation migration can be retried.

## Reader deployment

All Controllers and background readers must accept legacy and future classified evidence before future #329 writers activate. #418 has already shipped Worker updates while deliberately retaining Completed-only durable/public accounting. This bridge does not change that selection rule. CapturePolicy remains a write boundary, and the UI/public completeness features remain separate work.

## Validation

Use a populated disposable schema to distinguish unvalidated-but-enforced expansion from subsequent validation. Inspect the actual held relation lock and perform reads/inserts/updates from another connection before the validation transaction commits. Retain both old rows and newly inserted unclassified rows without altering their token counts. Run reader/capture/projection regressions and the applicable Elixir quality/coverage workflow.
