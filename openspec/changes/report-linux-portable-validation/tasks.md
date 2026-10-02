## 1. Lane Reporting

- [x] 1.1 Add an opt-in reporting mode to the Linux portable lane script that preserves every command, argument, order, exclusion, fail-fast stop, and exit status.
- [x] 1.2 Add a repository-owned report helper with a fixed key vocabulary, validated values, bounded failure identities, and credential and path redaction.
- [x] 1.3 Record unknown rather than success for interrupted, cancelled, unrecognized, or incomplete runs.

## 2. Workflow

- [x] 2.1 Add non-failing report steps around the unchanged setup and test steps in the Linux portable job.
- [x] 2.2 Upload only the bounded report file with a pinned artifact action.
- [x] 2.3 Run the reporting regression proof in the changes job.

## 3. Validation

- [x] 3.1 Prove exact command order, the stop at each failing command, the unsupported-host refusal, interrupts, reporting faults, dangerous output, and report bounds with disposable stubs under bash 5 and macOS bash 3.2.
- [x] 3.2 Run the existing classifier, aggregate gate, platform routing, distribution lane, and distribution pause proofs.
- [x] 3.3 Run strict focused and repository-wide OpenSpec validation and review the change prose for placeholders.
- [ ] 3.4 Run the exact Linux portable lane and aggregate gate in hosted CI.
- [ ] 3.5 Run exact-head review and the repository required review gate.
