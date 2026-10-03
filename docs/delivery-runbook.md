# Delivering a reviewed Orchard change

Use this runbook for a scoped contributor or agent delivery. The participation,
publication and merge authority in [CONTRIBUTING.md](../CONTRIBUTING.md) and
the artifact and review gates in [process.md](process.md) still apply. A ready
PR, successful automated review or green CI does not grant merge permission.
Only Najib merges: directly, or through an agent acting through his account with
explicit approval for the exact head. Other coordinators prepare and verify the
delivery; contributor access does not grant merge authority.

Scale evidence to risk. A trivial prose correction may use the direct-PR path
with the exact head, validation commands/results and CI link. Implementation or
contract changes use the independent review and readiness packet below.

## Scope and ownership

Start from current `main`, read `AGENTS.md`, `SPEC.md`, applicable docs and
OpenSpec materials, and state the intended behavior and `SPEC.md` impact.
Identify the accountable contributor, implementation owner, independent
reviewer and delivery coordinator. One person may implement and coordinate;
the reviewer must be independent of the implementation.

Record owned paths, dependencies, exclusions and the acceptance evidence in
the PR. Check existing collaborator ownership before editing. Use isolated
branches/worktrees when work overlaps or the primary checkout has user changes.
Serialize edits to shared files such as CI workflows across concurrent work.
Reconcile dependencies against actual current code, not a plan or a test alone.
Tests that pass without exercising the production path do not prove that path.

## Review and qualification

Finish the writer's changes, then run the applicable `AGENTS.md` workflow.
Have the independent reviewer inspect the exact head against its current base,
including contracts, actual behavior and tests. Ask for concrete counterexamples:
missing consumers, stale pins in dormant jobs, error propagation, timeout or
cancellation boundaries, and assertions that pass while production is wrong.
Optional local review tools can help; collaborators need only GitHub and the repo.

Fix recoverable findings within the approved scope. Resolve material review
conversations or disprove them against the current head; escalate scope or
contract conflicts to the accountable owner. After edits or base refreshes,
rerun affected validation and independently review the final change. Confirm
the writer has finished and no process can still change the reviewed branch.
Bind test/review evidence and the applicable required CI to that exact head.
If main moves, reconcile the new base and renew the affected evidence.

## Compact readiness packet

Keep this in the PR body or an approved update, with public-safe evidence links.
Keep raw logs, private identifiers and local session trails out of the repo.

| Field | Evidence |
|---|---|
| Ownership/scope/dependencies | Accountable contributor, owned paths, dependency order, exclusions |
| Exact head/base/tree | Full head and base SHAs, reviewed head tree, current base relationship |
| Paths/risk/behavior | Changed paths, actual behavior, `SPEC.md` impact, material risk |
| Tests | Commands, outcomes/counts, OS/shell/tool variants and coverage where applicable |
| Review | Independent final-head review, counterexamples considered, findings and disposition |
| CI | Exact PR head, applicable lane results and required aggregate link |
| Limitations | Unproven behavior, missing evidence, holds or required owner decisions |
| Writer done | All changes committed/published; no pending writer or mutable branch work |

Incomplete evidence means not ready. Readiness is a review handoff, not merge
authority. New commits invalidate the packet's exact-head claim.

## Approved sequential integration

Only after explicit merge approval, one coordinator prepares the dependency
order and Najib performs protected merges directly or through his approved
agent, one at a time. Recheck the current head/base, required
checks, review conversations and approval scope immediately before each merge.
Use normal protection and an exact-head guard; never bypass protection or
change it to make a delivery pass.

After each merge, verify the actual `main` commit, parent and resulting tree
against the reviewed integration. Wait for actual-main CI to finish green on
every applicable lane and the required aggregate before merging the next PR.
A PR check or simulated merge is not actual-main qualification. Stop on a
failure, cancellation, unexpected tree, moved head, unresolved finding or missing
evidence. Diagnose and requalify the in-scope recovery before proceeding;
report owner decisions that need renewed approval. Do not waive a failure or
quietly change retry/backoff, gates, pins or the distribution pause.
