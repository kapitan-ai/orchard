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
- [ ] 2.3 Verify that only the complete aggregate migration remains blocked until every dependency exposes a stable tested status interface; stage-one exposure separation may proceed with the labeled legacy predicate.
- [ ] 2.4 Re-run the readiness-source investigation against the exact dependency heads before starting the stage-two aggregate migration.
- [x] 2.5 Verify that stage one covers the internal legacy Console view, exact CLI
  pairs and rich-path removal, packaging, local-development documentation,
  Endpoint fault/task-lifecycle evidence, the complete Operator auth/no-store
  matrix, and `docs/milestones/m0-foundation.md`; defer transport-gate removal and
  the disposition of `controller_boot_completed` to stage two.
- [ ] 2.6 Verify that `SPEC.md` section 10.7 configuration, wrapper, and boot validation fail closed for every invalid or unresolvable public transport mode, including a `:transport_mode` application-environment value that never passes through `ORCHARD_TRANSPORT_MODE`, and assign any demonstrated gap to a separate transport change before the transport readiness gate is removed.

## 3. Validate and Hand Off

- [ ] 3.1 Run strict OpenSpec validation after dependency identifiers are recorded.
- [ ] 3.2 Complete an exact-diff review of this package against the exact dependency heads and resolve every blocking finding.
- [ ] 3.3 Run the no-mistakes gate before publishing any update to this prerequisite package.
- [x] 3.4 Confirm the behavior-changing pull request excludes transient investigation,
  review, prompt-export, and machine-local artifacts.
- [x] 3.5 State that stage one changes exposure and `SPEC.md` without changing the
  readiness predicate, and that issue #115 remains open for its external
  acceptance harness.
- [ ] 3.6 Hand future cache, leadership-gap, complete-aggregate, and observability-harness tasks to their owning change packages rather than adding them to stage one.
- [ ] 3.7 After any later sync or archive, review generated main specs and remove incomplete placeholder prose such as `Purpose TBD`.
