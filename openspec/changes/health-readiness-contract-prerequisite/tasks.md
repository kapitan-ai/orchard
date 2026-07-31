## 1. Record Blocking Ownership

- [ ] 1.1 Record the accepted issue and OpenSpec owner for the genuine model cache, serving-path integration, and authoritative loaded-state interface.
- [ ] 1.2 Record the accepted issue and OpenSpec owner for the genuine tenant cache, serving-path integration, and authoritative loaded-state interface.
- [ ] 1.3 Record the accepted issue and OpenSpec owner for the genuine API-key cache, authentication-path integration, security, coherence, and authoritative loaded-state interface.
- [ ] 1.4 Assess the existing `Orchard.ControlPlane.authorize_write_path/1` and `read_only_status/0` surface for production provider backing, bounded-read behavior, and exact readiness semantics, including whether `deployment_mode` can be validated rather than assumed when a host is falsely configured as `single_controller` inside an Active/Standby cluster, when the normalized role is `unknown`, and when the configured mode is inconsistent with cluster membership evidence.
- [ ] 1.5 Record a separate issue and OpenSpec owner only for leadership gaps demonstrated by task 1.4.
- [ ] 1.6 Link every accepted dependency from this change package and issue #115 without adding implementation details owned by those changes.

## 2. Verify the Prerequisite Gate

- [ ] 2.1 Verify that each cache owner rejects constants, configuration flags, readiness-only caches, unrelated caches, and direct database queries presented as hydration evidence.
- [ ] 2.2 Verify that the accepted leadership source derives from the same production authority used by write authorization and does not infer authority from configured role, membership, or process presence, while permitting a validated deployment mode to decide only whether the conditional leadership condition applies.
- [ ] 2.3 Verify that issue #115 remains blocked until every dependency exposes a stable tested status interface.
- [ ] 2.4 Re-run the issue #115 RP Investigate workflow against the exact dependency heads before starting production health changes.
- [ ] 2.5 Verify that the deferred atomic migration inventory covers Console, CLI, packaging, local-development documentation, tests, and `docs/milestones/m0-foundation.md`, and that the recorded transport-gate removal and credential-free `orchardctl status` identity loss are carried into that pull request.

## 3. Validate and Hand Off

- [ ] 3.1 Run strict OpenSpec validation after dependency identifiers are recorded.
- [ ] 3.2 Run exact-diff RepoPrompt Review and Oracle follow-up, then resolve all blocking findings.
- [ ] 3.3 Run the no-mistakes gate before publishing any update to this prerequisite package.
- [ ] 3.4 Confirm the pull request changes only this OpenSpec package and excludes transient investigation, review, prompt-export, and machine-local artifacts.
- [ ] 3.5 State in the pull request that no production behavior changes, `SPEC.md` remains unchanged, and issue #115 remains open.
- [ ] 3.6 Hand future cache, leadership-gap, health implementation, consumer migration, and observability-harness tasks to their owning change packages rather than adding them here.
- [ ] 3.7 After any later sync or archive, review generated main specs and remove incomplete placeholder prose such as `Purpose TBD`.
