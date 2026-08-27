## 1. Accepted capability

- [x] 1.1 Clarify that Portal User creation persists only an invited identity and issues no token or URL.
- [x] 1.2 Clarify that the first Copy invite action issues the initial token and later actions reissue through the same path.
- [x] 1.3 Record one-row deletion-based invalidation, no retained invalidation history, invited-only redemption, and the canonical POST route.

## 2. Durable documentation

- [x] 2.1 Reconcile `docs/DESIGN.md` with the Create then Copy Console sequence.
- [x] 2.2 Reconcile `docs/operator-journey.md` with first issuance, later reissue, and deliberate separate key revocation.
- [x] 2.3 Leave `SPEC.md`, ADR 0020, and the archived 2026-08-14 package unchanged, and align the glossary Portal Invite entry with Create then Copy.
- [x] 2.4 Record active-user recovery, audit vocabulary, and neutral key-attribution labels only as owner-gated non-goals.
- [x] 2.5 Keep issue #270 independent.

## 3. Validation And Review

- [x] 3.1 Run `git diff --check`.
- [x] 3.2 Run strict targeted OpenSpec validation for this change.
- [x] 3.3 Run a read-only RepoPrompt reconciliation review and resolve blocker and important findings.
- [x] 3.4 Archive this completed change with `--skip-specs` after the accepted capability is synchronized.
- [x] 3.5 Run strict all-spec OpenSpec validation and review the accepted capability for placeholder prose.
