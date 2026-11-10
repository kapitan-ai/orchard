## 1. Contract acceptance gate

- [x] 1.1 Read the current store, store/client tests, callers, and public issues #144–#146 and PR #159; map current failure paths and ambiguous signals in design.md.
- [x] 1.2 Draft the `SPEC.md` §7.5.0 amendment and subordinate error-contract deltas without production or test code changes.
- [ ] 1.3 Obtain accountable-owner acceptance of this exact contract, including the review questions in design.md. No production or test code lands until this change is accepted; acceptance does not itself authorize merge or start deferred implementation.

## 2. Later implementation after acceptance and authorization

- [ ] 2.1 Implement the two classifications for both install and load; preserve them through acquisition wrappers and `load/3` normalization, while preserving terminal custody precedence and adding no store retries.
- [ ] 2.2 Coordinate #146's bounded readiness buffering and deterministic native-helper contention/exit detection; measure realistic concurrency before proposing any acquisition-timeout change. Preserve the existing lock inode, cross-VM exclusion, ownership/type/mode checks, and bounded waits.
- [ ] 2.3 Preserve explicit propagation through delivery, bootstrap, preflight, and startup verification. Keep no retry as a valid caller policy; any proposed caller retry must separately specify finite attempts and total elapsed bound, revalidation, and idempotence without false absence, new issuance/generation, duplicate durable effects, or transport fallback.
- [ ] 2.4 Add closed sanitized cause attribution and expose the stable errors through shared diagnostics without host details or raw helper/exception data.

## 3. Later public-interface regression tests

- [ ] 3.1 Update confirmed-contention coverage and test both install and load before first publication and with an existing valid grant. Verify bounded busy results, exact grant recovery on a separately invoked attempt, owner death/release, and genuine absence remaining missing.
- [ ] 3.2 Cover helper absent/unstartable, marker submission failure, early/unexpected exit, valid fragmented/coalesced readiness, malformed/trailing output, confirmed native contention timeout versus outer readiness deadline, and resource cleanup with deterministic synchronization rather than sleeps.
- [ ] 3.3 Preserve terminal unsafe owner/type/mode/symlink, malformed data, hash tampering, conflict, cleanup/durability/rollback failure, unclassified exception, and post-operation lock-loss cases; assert neither retryable atom masks unsafe or indeterminate custody.
- [ ] 3.4 Exercise delivery, bootstrap, preflight, and startup verification through public interfaces: distinct errors survive propagation, no implicit retry/retrieval or cookie/launch action occurs on failure, and no second durable side effect or different generation appears.
- [ ] 3.5 Assert returned errors and captured diagnostics/logs/telemetry contain only the stable errors and closed sanitized causes, with no paths, PIDs, lock-file contents, helper output, grant material, raw exceptions, or other host detail. Retain idempotence and cross-VM exclusion stress coverage.

## 4. Validation and handoff

- [x] 4.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate define-peer-grant-store-contention-errors --type change --strict --no-interactive`.
- [x] 4.2 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and `git diff --check`; confirm the contract-only diff leaves production and tests untouched.
- [ ] 4.3 For later implementation, run focused regressions and contention stress, then the full AGENTS.md Elixir workflow from the umbrella root: format, warnings-as-errors compile, strict Credo, Dialyzer, host-native test helper staging, tests, and coverage. Qualify host-native lock behavior on the applicable macOS and Linux surfaces without claiming unsupported platform eligibility.
- [ ] 4.4 Obtain independent exact-head review before PR readiness; this draft is not a merge-ready implementation handoff.
- [ ] 4.5 After acceptance and eventual archive or sync, reconcile implemented behavior with `SPEC.md`, rerun strict all-spec validation, and inspect generated main specs for placeholder prose such as `Purpose TBD`.
