## Why

`SPEC.md` and shipped Portal behavior already agree that creating a Portal User and issuing a Portal Invite are separate actions.
The accepted Developer Portal capability and operator-facing documentation do not state that boundary consistently, which can make Portal User creation read as immediate token issuance.
The accepted capability also needs to name deletion as the invalidation mechanism, the absence of retained invalidation history, and the canonical redemption POST route already fixed by `SPEC.md` and PR #284.

## What Changes

- Clarify that creating a Portal User persists only an identity in `invited` status and issues no token or URL.
- Clarify that the first **Copy invite** action issues the initial Portal Invite and later actions reissue it through the same path.
- State that issuance deletes any previous invite row, stores at most one hash-only row, and retains no invalidation or revocation history.
- Name `POST /portal/:organization_slug/invites/:token` as the canonical Organization-bound redemption route.
- Reconcile the Console design guidance and operator journey with the shipped Create then Copy sequence.
- Preserve the earlier archived Developer Portal package as historical context rather than rewriting its original decision record.

## Capabilities

### Modified Capabilities

- `developer-api-key-portal`: Clarifies the already-shipped boundary between Portal User creation, first invite issuance, later reissue, deletion-based invalidation, and invited-only route-bound redemption.

## Impact

- `SPEC.md` impact: none.
- Product behavior impact: none.
- Implementation impact: none.
- Persistence impact: none.
- Documentation impact: the accepted capability spec, Console design guidance, operator journey, and glossary Portal Invite entry use one Create then Copy contract.
- Historical impact: the archived 2026-08-14 Developer Portal package remains unchanged as a record of earlier intent, while current accepted truth remains in `SPEC.md`, accepted specs, and this reconciliation.

## Non-Goals

- This change does not add product code, migrations, tests, or Console behavior.
- This change does not reintroduce `invalidated_at`, a separate invite-state column, or durable invite invalidation history.
- Active-user recovery semantics remain owner-gated and are not defined here.
- Audit actor, action, and outcome vocabulary remains owner-gated and is not defined here.
- Neutral Console key-attribution labels remain owner-gated and are not defined here.
- Issue #270 remains an independent Developer Portal feedback workstream.
