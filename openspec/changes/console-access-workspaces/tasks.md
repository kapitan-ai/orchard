## 1. Contract and terminology

- [x] 1.1 Reconcile SPEC.md sections 2.3 and 7.4a, glossary, and affected product/OpenSpec wording with Workspace as the display label while preserving Tenant machine contracts.
- [x] 1.2 Add the terminology decision and tactical Access/Workspace navigation rules to the appropriate decision record and docs/DESIGN.md.
- [x] 1.3 Record a route, legacy-anchor, and wording inventory to ensure existing Console and Portal links retain their behavior.

## 2. Access navigation and Workspace sections

- [x] 2.1 Add Access navigation and canonical compatible Workspace routes without changing the existing authentication boundary.
- [x] 2.2 Separate Workspace listing and creation, with loading, empty, and error states plus existing route-level authentication rejection coverage and usable return paths.
- [x] 2.3 Implement reloadable Overview, Model access, Portal users, and API credentials sections with persistent Workspace identity and inaccessible inactive sections.
- [x] 2.4 Preserve current Portal and API Client controls, distinguish client ownership from role scope, and retain Team as optional grouping metadata only.
- [x] 2.5 Add regressions for legacy URLs and client-bridged fragments, invalid section parameters, target switching, and forged cross-Workspace child-resource identifiers.
- [x] 2.6 Present the existing seeded Tenant as Default workspace, preserve customized names, and start single-Workspace onboarding without redundant scope selection.
- [x] 2.7 Test fresh-install seed visibility, stable identity, no duplicate/reset on repeated access, explicit non-default scope preservation, and missing-seed/read-error recovery.

## 3. Model access evidence and operator handoff

- [x] 3.1 Read existing Workspace grants and exact catalog identities through Models.Access, distinguishing enabled, disabled, not-granted, inactive Model, and unavailable states.
- [x] 3.2 Generate scoped grant and inspect command handoffs from server-held identities with proper shell argument quoting and no secrets.
- [x] 3.3 Add grant-state, read-failure, exact-version, cross-Workspace, and command-injection regression coverage without introducing new browser grant mutations.

## 4. Guided colleague handoff

- [x] 4.1 Implement one-Workspace model/invitation/review/delivery navigation using the existing Portal services and actual persisted states.
- [x] 4.2 Preserve non-secret draft inputs during safe recovery and clear scoped/secret state when the Workspace changes.
- [x] 4.3 Show explicit manual delivery, existing HTTPS prerequisites, expiry, reissue, disablement, and separate credential provisioning without simulating acceptance.
- [x] 4.4 Reconcile PortalActivationCurl's stale empty-model selector with the existing tenant-filtered active Model listing; generate an inert exact-model request example using placeholders in Console and preserving real secrets only in the actual Portal mint response's existing one-time display.
- [x] 4.5 Test no-grant, disabled grant and absent grant (revoked or never granted), inactive Model, deterministic selection, cross-Workspace exclusion, and runtime-unverified copy for request examples.
- [x] 4.6 Verify that request guidance never marks an unexecuted request complete or misrepresents the Console Playground's legacy Tenant as the chosen Workspace.
- [x] 4.7 Preserve the six-step sequence, current step count, dimmed future steps, default-Workspace resolved first step, and content replacement rather than appended cards.
- [x] 4.8 Test activated-Portal-User plus missing-grant recovery without reinvitation, safe Back/retry state retention, and visible scope on narrow screens.

## 5. Validation and review

- [x] 5.1 Run strict OpenSpec validation before implementation and before handoff; reconcile any SPEC conflict before proceeding.
- [x] 5.2 Run the applicable AGENTS.md Elixir workflow, including full tests and coverage, and relevant Portal/auth/model-access/CLI suites for each implementation increment.
- [x] 5.3 Verify browser navigation, light/dark themes, narrow layouts, keyboard focus, invitation failure/retry, and scope continuity with disposable fixtures.
- [x] 5.4 Run independent simulated Department Operator, authorized administrator, and Application Developer walkthroughs; distinguish findings from real participant testing.
- [x] 5.5 Present the runnable increment and actual verification boundaries for user review without merging.
- [ ] 5.6 After later archive or sync, review generated main specs and remove placeholder prose such as Purpose TBD.
