## 1. Contract

- [x] 1.1 Clarify `SPEC.md` §7.4a invite eligibility, generic failure, atomic disablement, and two-column key ownership boundaries.
- [x] 1.2 Reconcile the accepted Developer Portal capability spec and this change delta.

## 2. Public TDD Seams

- [x] 2.1 Reproduce disable-then-redeem through the public governance lifecycle and invalidate outstanding invites atomically.
- [x] 2.2 Prove wrong-Organization redemption is generic, mutation-free, and leaves the correct route usable.
- [x] 2.3 Prove Portal User key listing requires authenticated Portal User and Organization ownership.
- [x] 2.4 Prove disablement ends only the target sessions and preserves minted API Keys.

## 3. Implementation

- [x] 3.1 Serialize invite reissue, redemption, and disablement on the current Portal User row.
- [x] 3.2 Require route Organization and invited status for redemption through the public facade.
- [x] 3.3 Add the authenticated Tenant predicate to Portal User key listing.
- [x] 3.4 Preserve the existing generic response and secret-handling contract.

## 4. Validation And Review

- [x] 4.1 Run strict OpenSpec validation for `prevent-disabled-portal-invite-redemption`.
- [x] 4.2 Run the focused governance, Console, Portal controller, Portal LiveView, router, and endpoint suites.
- [x] 4.3 Run the complete Orchard Elixir quality and coverage workflow.
- [x] 4.4 Run residual secret and logging checks plus `git diff --check`.
- [ ] 4.5 Complete RepoPrompt Review, Oracle, No Mistakes, GitHub feedback, and CI handoff.
