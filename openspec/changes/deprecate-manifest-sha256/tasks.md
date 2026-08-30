## 1. Contract Reconciliation

- [x] 1.1 Reconcile `SPEC.md` §§6.4-6.7 and §11.7 with optional non-authoritative manifest `sha256`, authoritative final-tree Catalog hashing, and distinct verification checkpoints.
- [x] 1.2 Update the shared manifest schema fixture and its documentation to declare known, required, optional, and deprecated top-level keys.

## 2. Consumer Compatibility Through TDD

- [x] 2.1 Add a failing public Elixir manifest-parser test for omitted `sha256` while retaining unknown-key rejection, then minimally make the shared domain accept absence.
- [x] 2.2 Add a failing public MLX worker manifest-parser test for omitted `sha256` while retaining unknown-key rejection, then minimally make the worker accept absence.
- [x] 2.3 Keep BundleBuilder legacy `sha256` emission unchanged and add or retain focused coverage proving transitional emission.

## 3. Authoritative Digest Proof Through TDD

- [x] 3.1 Add a public Artifact Bundle characterization test proving exact `manifest.json` bytes remain inside the tree digest, preserving the existing algorithm unchanged.
- [x] 3.2 Add a public importer characterization test proving a present legacy value cannot supply or override `models.artifact_sha256` and that storage equals a fresh digest of the final post-rewrite tree.

## 4. Operator Guidance And Compatibility Gate

- [x] 4.1 Correct `docs/local-dev.md` so it distinguishes deprecated manifest metadata, detached pre-import media verification, and post-import Catalog verification.
- [x] 4.2 Document the producer-removal follow-up as requiring repo-owned accepted minimum-consumer-version evidence without inventing capability negotiation.

## 5. Validation And Review

- [x] 5.1 Run focused Elixir and native MLX worker tests during each red-green slice and record red-before-green evidence.
- [x] 5.2 Run the applicable full Elixir and native Python formatting, linting, test, typing where configured, and coverage workflows from `AGENTS.md`.
- [x] 5.3 Run strict validation for `deprecate-manifest-sha256` and strict all-change OpenSpec validation, then obtain independent RP Review or Oracle review and resolve validated findings.
- [x] 5.4 Confirm this active change is not archived or synced in this PR and preserve the required future review to remove generated placeholder prose after archive or sync.
