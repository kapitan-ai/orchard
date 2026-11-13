# ADR 0044: Public release records and three release channels

## Status
Accepted on 2026-11-13 by Najib, product owner.

## Context
Orchard's repository is public; every non-draft GitHub Release is public.

## Decision
Remove the `pilot` Release Channel: the channels are `internal`, `trial`, and `release`. This amends decision 1.4 and the pilot references in [ADR 0043](0043-vendor-neutral-dmg-distribution.md), without editing that accepted record.
No GitHub release record of any channel may carry installable bytes until an accepted OpenSpec change amends the single-delivery-surface rule; bytes on a `release` record additionally require the explicit `SPEC.md` §11 public-binary decision.
Signed, notarized, or restricted-channel Candidate or Internal Build bytes must never enter workflow artifacts, caches, logs, job summaries, or any other store readable by the repository's general audience. Candidate construction may write only ephemeral workflow artifacts.
The remaining release-record and custody details are deferred to the delivery-surface selection change (task 1.11), as listed in the governance design.
ADR 0043's GitHub release-record role, Amore withdrawal and other outcomes remain intact, as do trial/release reducers, the approval lifecycle, exact-byte promotion, required artifact set, solo-owner exception, Apple trust gates and §11.0 pause.
No `SPEC.md` change is made here; the §11.3 sentence remains held in the governance design for task 2.1.
