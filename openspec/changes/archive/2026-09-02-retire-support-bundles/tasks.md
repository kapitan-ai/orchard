## 1. Decision And Proposed Contract

- [x] 1.1 Record the approved retirement decision in issue #356 while preserving the historical Linux race investigation.
- [x] 1.2 Validate `retire-support-bundles` strictly before changing production code or live contract documentation.
  Note: Strict validation passed on 2026-09-02 before production or live-contract edits.

## 2. Public CLI Removal

- [x] 2.1 Change CLI public-seam tests first so direct former `support` namespace commands must reject with exit status 1.
  Note: The pre-removal focused run failed four public-seam assertions because help and archive creation were still live.
- [x] 2.2 Add negative side-effect coverage proving a former `--output` path is not created.
- [x] 2.3 Preserve successful generic root-help behavior while removing support from the command list.
- [x] 2.4 Remove the support dispatcher, implementation module, focused implementation tests, and CLI documentation.

## 3. Governance And Shared Vocabulary

- [x] 3.1 Remove `Governance.audit_support_bundle_generated/1`, its private payload builder, and its tests.
- [x] 3.2 Remove the `support_bundle` action-domain mapping and prove unknown support-bundle actions are rejected by metrics normalization.
- [x] 3.3 Remove the support-only `support_scope` vocabulary and its shared contract tests while preserving all operational reason-code vocabularies.
- [x] 3.4 Verify historical audit rows remain readable without migration or action-domain lookup.

## 4. Metrics Contract

- [x] 4.1 Reduce the bounded audit domain inventory from twelve domains to eleven.
- [x] 4.2 Reduce the audit-events family ceiling from 36 to 33 series.
- [x] 4.3 Reconcile the accepted Controller metrics floor to 2,597, the runtime worksheet to 2,826, and headroom to 2,174.
- [x] 4.4 Update focused metrics tests with independent literal expectations for descriptor count, audit pair count, family ceiling, total worksheet, and headroom.

## 5. Live Product Contract And Documentation

- [x] 5.1 Remove support-bundle promises from `SPEC.md` while preserving general diagnostics, secret-handling requirements, and lifecycle directories.
- [x] 5.2 Reconcile `cluster-management-ux-foundation` proposal, design, spec, and tasks as described in this change design.
- [x] 5.3 Remove feature references from live README, architecture, local-development, packaging, CLI, glossary, Console, API, tray, and milestone documentation.
- [x] 5.4 Preserve exact lifecycle wording for operator-owned contents and app-owned entries under the retained `support/` namespace.

## 6. Residual And Focused Validation

- [x] 6.1 Run semantic residual searches for support-bundle product names, v2 manifest fields, `support_scope`, and the `support_bundle` audit domain.
- [x] 6.2 Run focused `orchard_cli`, shared reason-code, governance, audit-writer, and metrics tests.
  Note: The post-review combined focused run passed 18 shared tests, 91 Controller tests, and 40 CLI tests.
- [x] 6.3 Validate both `retire-support-bundles` and the modified `cluster-management-ux-foundation` changes strictly.
  Note: The two additional active changes touched by residual wording cleanup also passed strict validation.

## 7. Repository Quality Gates

- [x] 7.1 Run `mise exec -- mix format`.
- [x] 7.2 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 7.3 Run `mise exec -- mix credo --strict`.
- [x] 7.4 Run `mise exec -- mix dialyzer`.
- [x] 7.5 Run `make macos-native-test-helpers`.
- [x] 7.6 Run `mise exec -- mix test`.
  Note: After the fresh worktree created its pinned native environments and one stale test-owned temp directory was moved aside, the exact-seed app reruns and the complete umbrella rerun passed: 218 shared, 3,758 Controller, 438 Node Agent, and 650 CLI tests.
- [x] 7.7 Run `mise exec -- mix test --cover`.
  Note: A first instrumented run exposed two pre-existing Controller timing flakes, both of which passed at their exact lines under coverage. A second unmodified coverage run passed all four applications with totals of 67.02%, 84.5%, 78.94%, and 74.90%.
- [ ] 7.8 Run the portable Linux control-plane suite and record the OS, toolchain, result, and cleanup evidence.

## 8. Acceptance And Handoff

- [x] 8.1 Obtain independent RepoPrompt review of the complete diff and resolve all validated blockers.
  Note: The initial review found two contract blockers. The follow-up review verified both fixes and found no additional implementation or contract blocker beyond the planned finalization gates.
- [x] 8.2 Record explicit owner acceptance for the retirement contract.
  Note: Najib explicitly approved the reconciled RepoPrompt and ChatGPT Pro design on 2026-09-02 before implementation proceeded.
- [x] 8.3 Synchronize the accepted capability deltas, archive this change, and validate all OpenSpec materials strictly.
  Note: The archive updated four accepted capabilities, and strict validation passed all 41 active changes and accepted specifications.
- [x] 8.4 Append partial-supersession annotations to ADR 0005 and ADR 0008 without rewriting their historical decisions.
- [ ] 8.5 Open an unmerged pull request that closes issue #356 and reports exact validation evidence and residual risks.
